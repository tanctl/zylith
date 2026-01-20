//! Snarkjs proof generation wrapper.
//! Requires the `snarkjs` CLI to be available on PATH.

use std::path::{Path, PathBuf};
#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;
use std::time::{SystemTime, UNIX_EPOCH};

use serde::Deserialize;
use tokio::process::Command;

use crate::error::ProverError;

fn write_private_file(path: &Path, data: &[u8]) -> Result<(), ProverError> {
    use std::io::Write;
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(path)?;
    file.write_all(data)?;
    Ok(())
}

#[derive(Debug, Clone, Deserialize)]
pub struct SnarkjsProof {
    pub pi_a: Vec<String>,
    pub pi_b: Vec<Vec<String>>,
    pub pi_c: Vec<String>,
    pub protocol: String,
    pub curve: String,
}

#[derive(Debug)]
pub struct SnarkjsOutput {
    pub proof: SnarkjsProof,
    pub public_inputs: Vec<String>,
    pub workdir: PathBuf,
    pub proof_path: PathBuf,
    pub public_inputs_path: PathBuf,
}

impl Drop for SnarkjsOutput {
    fn drop(&mut self) {
        if self.workdir.as_os_str().is_empty() {
            return;
        }
        let _ = std::fs::remove_dir_all(&self.workdir);
    }
}

pub async fn generate_proof_snarkjs(
    circuit_name: &str,
    witness_input: &serde_json::Value,
    wasm_path: &Path,
    zkey_path: &Path,
) -> Result<SnarkjsOutput, ProverError> {
    if !wasm_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing wasm at {}",
            wasm_path.display()
        )));
    }
    if !zkey_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing zkey at {}",
            zkey_path.display()
        )));
    }

    let workdir = create_temp_dir(circuit_name)?;
    let workdir_out = workdir.clone();
    let result = async {
        let input_path = workdir.join("input.json");
        let witness_path = workdir.join("witness.wtns");
        let proof_path = workdir.join("proof.json");
        let public_path = workdir.join("public.json");

        write_private_file(&input_path, &serde_json::to_vec_pretty(witness_input)?)?;

        run_snarkjs(
            [
                "wtns",
                "calculate",
                &wasm_path.display().to_string(),
                &input_path.display().to_string(),
                &witness_path.display().to_string(),
            ],
            &workdir,
        )
        .await?;

        run_snarkjs(
            [
                "groth16",
                "prove",
                &zkey_path.display().to_string(),
                &witness_path.display().to_string(),
                &proof_path.display().to_string(),
                &public_path.display().to_string(),
            ],
            &workdir,
        )
        .await?;

        let proof_bytes = std::fs::read(&proof_path)?;
        let proof: SnarkjsProof = serde_json::from_slice(&proof_bytes)?;
        let public_bytes = std::fs::read(&public_path)?;
        let public_inputs: Vec<String> = serde_json::from_slice(&public_bytes)?;
        Ok(SnarkjsOutput {
            proof,
            public_inputs,
            workdir: workdir_out,
            proof_path,
            public_inputs_path: public_path,
        })
    }
    .await;
    if result.is_err() {
        let _ = std::fs::remove_dir_all(&workdir);
    }
    result
}

async fn run_snarkjs<I, S>(args: I, workdir: &Path) -> Result<(), ProverError>
where
    I: IntoIterator<Item = S>,
    S: AsRef<str>,
{
    let mut command = Command::new("snarkjs");
    if let Ok(options) = std::env::var("ZYLITH_NODE_OPTIONS") {
        command.env("NODE_OPTIONS", options);
    } else if std::env::var("NODE_OPTIONS").is_err() {
        command.env("NODE_OPTIONS", "--max-old-space-size=8192");
    }
    for arg in args {
        command.arg(arg.as_ref());
    }
    command.current_dir(workdir);
    let output = command.output().await.map_err(|err| {
        ProverError::Snarkjs(format!("failed to run snarkjs: {err}"))
    })?;
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let status = match (output.status.code(), output.status.signal()) {
            (Some(code), _) => format!("exit code {code}"),
            (None, Some(signal)) => format!("terminated by signal {signal}"),
            (None, None) => "terminated".to_string(),
        };
        return Err(ProverError::Snarkjs(format!(
            "snarkjs failed ({status}): {stdout} {stderr}"
        )));
    }
    Ok(())
}

fn create_temp_dir(circuit_name: &str) -> Result<PathBuf, ProverError> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map_err(|err| ProverError::Io(err.to_string()))?;
    let dir = std::env::temp_dir().join(format!(
        "zylith_snarkjs_{circuit_name}_{}_{}",
        now.as_millis(),
        std::process::id()
    ));
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    }
    Ok(dir)
}
