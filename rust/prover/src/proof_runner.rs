//! Proof generation wrapper for Circom artifacts.
//! Uses the native Circom witness generator and `rapidsnark` for Groth16 proving.

#[cfg(unix)]
use std::os::unix::process::ExitStatusExt;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::OnceLock;

use serde::{Deserialize, Serialize};
use tokio::process::Command;

use crate::error::ProverError;

static PROVER_WORK_ROOT: OnceLock<PathBuf> = OnceLock::new();
static PROVER_WORK_COUNTER: AtomicU64 = AtomicU64::new(0);

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

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Groth16Proof {
    pub pi_a: Vec<String>,
    pub pi_b: Vec<Vec<String>>,
    pub pi_c: Vec<String>,
    #[serde(default)]
    pub protocol: String,
    #[serde(default)]
    pub curve: String,
}

#[derive(Debug)]
pub struct ProofOutput {
    pub workdir: PathBuf,
    cleanup_paths: Vec<PathBuf>,
    pub proof_path: PathBuf,
    pub public_inputs_path: PathBuf,
}

impl Drop for ProofOutput {
    fn drop(&mut self) {
        cleanup_paths(&self.cleanup_paths);
    }
}

pub async fn generate_proof(
    circuit_name: &str,
    witness_input: &serde_json::Value,
    wasm_path: &Path,
    zkey_path: &Path,
) -> Result<ProofOutput, ProverError> {
    let native_witness_path = native_witness_bin_path(wasm_path)?;
    let native_witness_dat_path = native_witness_dat_path(wasm_path)?;
    if !native_witness_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing native witness generator at {}",
            native_witness_path.display()
        )));
    }
    if !native_witness_dat_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing native witness data at {}",
            native_witness_dat_path.display()
        )));
    }
    if !zkey_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing zkey at {}",
            zkey_path.display()
        )));
    }

    let work_files = create_work_files(circuit_name)?;
    let workdir = work_files.workdir.clone();
    let result = async {
        write_private_file(&work_files.input_path, &serde_json::to_vec(witness_input)?)?;

        run_native_witness(
            &native_witness_path,
            &work_files.input_path,
            &work_files.witness_path,
            &workdir,
        )
        .await?;

        run_rapidsnark(
            zkey_path,
            &work_files.witness_path,
            &work_files.proof_path,
            &work_files.public_inputs_path,
            &workdir,
        )
        .await?;

        let proof_bytes = std::fs::read(&work_files.proof_path)?;
        let mut proof: Groth16Proof = serde_json::from_slice(&proof_bytes)?;
        let mut rewrite_proof = false;
        if proof.protocol.is_empty() {
            proof.protocol = "groth16".to_string();
            rewrite_proof = true;
        }
        if proof.curve.is_empty() {
            proof.curve = "bn128".to_string();
            rewrite_proof = true;
        }
        if rewrite_proof {
            write_private_file(&work_files.proof_path, &serde_json::to_vec(&proof)?)?;
        }
        Ok(ProofOutput {
            workdir: work_files.workdir.clone(),
            cleanup_paths: work_files.cleanup_paths.clone(),
            proof_path: work_files.proof_path.clone(),
            public_inputs_path: work_files.public_inputs_path.clone(),
        })
    }
    .await;
    if result.is_err() {
        cleanup_paths(&work_files.cleanup_paths);
    }
    result
}

async fn run_rapidsnark(
    zkey_path: &Path,
    witness_path: &Path,
    proof_path: &Path,
    public_path: &Path,
    workdir: &Path,
) -> Result<(), ProverError> {
    let program =
        std::env::var("ZYLITH_RAPIDSNARK_BIN").unwrap_or_else(|_| "rapidsnark".to_string());
    let output = Command::new(&program)
        .arg(zkey_path)
        .arg(witness_path)
        .arg(proof_path)
        .arg(public_path)
        .current_dir(workdir)
        .output()
        .await
        .map_err(|err| ProverError::Rapidsnark(format!("failed to run {program}: {err}")))?;
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let status = match (output.status.code(), output.status.signal()) {
            (Some(code), _) => format!("exit code {code}"),
            (None, Some(signal)) => format!("terminated by signal {signal}"),
            (None, None) => "terminated".to_string(),
        };
        return Err(ProverError::Rapidsnark(format!(
            "{program} failed ({status}): {stdout} {stderr}"
        )));
    }
    Ok(())
}

async fn run_native_witness(
    witness_bin: &Path,
    input_path: &Path,
    witness_path: &Path,
    workdir: &Path,
) -> Result<(), ProverError> {
    let output = Command::new(witness_bin)
        .arg(input_path)
        .arg(witness_path)
        .current_dir(workdir)
        .output()
        .await
        .map_err(|err| {
            ProverError::Io(format!(
                "failed to run native witness generator {}: {err}",
                witness_bin.display()
            ))
        })?;
    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        let status = match (output.status.code(), output.status.signal()) {
            (Some(code), _) => format!("exit code {code}"),
            (None, Some(signal)) => format!("terminated by signal {signal}"),
            (None, None) => "terminated".to_string(),
        };
        return Err(ProverError::Io(format!(
            "native witness generator failed ({status}): {stdout} {stderr}"
        )));
    }
    Ok(())
}

fn native_witness_bin_path(wasm_path: &Path) -> Result<PathBuf, ProverError> {
    let circuit_dir = wasm_path.parent().ok_or_else(|| {
        ProverError::InvalidInput(format!(
            "cannot resolve circuit directory for {}",
            wasm_path.display()
        ))
    })?;
    let stem = wasm_path
        .file_stem()
        .and_then(|value| value.to_str())
        .ok_or_else(|| {
            ProverError::InvalidInput(format!(
                "cannot resolve circuit stem for {}",
                wasm_path.display()
            ))
        })?;
    Ok(circuit_dir.join(stem))
}

fn native_witness_dat_path(wasm_path: &Path) -> Result<PathBuf, ProverError> {
    Ok(native_witness_bin_path(wasm_path)?.with_extension("dat"))
}

#[derive(Debug, Clone)]
struct WorkFiles {
    workdir: PathBuf,
    cleanup_paths: Vec<PathBuf>,
    input_path: PathBuf,
    witness_path: PathBuf,
    proof_path: PathBuf,
    public_inputs_path: PathBuf,
}

fn prover_work_root() -> Result<PathBuf, ProverError> {
    if let Some(path) = PROVER_WORK_ROOT.get() {
        return Ok(path.clone());
    }
    let base_dir = std::env::var("ZYLITH_PROVER_TMPDIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| std::env::temp_dir());
    let dir = base_dir.join(format!("zylith_prover_{}", std::process::id()));
    std::fs::create_dir_all(&dir)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o700))?;
    }
    let _ = PROVER_WORK_ROOT.set(dir.clone());
    Ok(dir)
}

fn create_work_files(circuit_name: &str) -> Result<WorkFiles, ProverError> {
    let workdir = prover_work_root()?;
    let request_id = PROVER_WORK_COUNTER.fetch_add(1, Ordering::Relaxed);
    let prefix = format!("{circuit_name}_{}_{}", std::process::id(), request_id);
    let input_path = workdir.join(format!("{prefix}_input.json"));
    let witness_path = workdir.join(format!("{prefix}_witness.wtns"));
    let proof_path = workdir.join(format!("{prefix}_proof.json"));
    let public_inputs_path = workdir.join(format!("{prefix}_public.json"));
    let cleanup_paths = vec![
        input_path.clone(),
        witness_path.clone(),
        proof_path.clone(),
        public_inputs_path.clone(),
    ];
    Ok(WorkFiles {
        workdir,
        cleanup_paths,
        input_path,
        witness_path,
        proof_path,
        public_inputs_path,
    })
}

fn cleanup_paths(paths: &[PathBuf]) {
    for path in paths {
        let _ = std::fs::remove_file(path);
    }
}
