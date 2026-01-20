use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde_json::Value;
use tokio::sync::Mutex;
use zylith_prover::{generate_garaga_calldata, generate_proof_snarkjs, ProverError};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn artifacts_root() -> PathBuf {
    std::env::var("ZYLITH_ARTIFACTS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root().join("artifacts"))
}

fn vectors_root() -> PathBuf {
    std::env::var("ZYLITH_VECTORS_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|_| repo_root().join("circuits/test/vectors"))
}

fn load_vector_input(circuit: &str, name: &str) -> Result<Value, ProverError> {
    let path = vectors_root().join(circuit).join(format!("{name}.json"));
    let data = std::fs::read_to_string(&path)
        .map_err(|err| ProverError::Io(format!("failed to read {path:?}: {err}")))?;
    let value: Value =
        serde_json::from_str(&data).map_err(|err| ProverError::Io(err.to_string()))?;
    let input = value
        .get("input")
        .cloned()
        .ok_or_else(|| ProverError::InvalidInput("vector missing input".to_string()))?;
    Ok(input)
}

async fn with_prover_lock<F, Fut>(f: F) -> Result<(), ProverError>
where
    F: FnOnce() -> Fut,
    Fut: std::future::Future<Output = Result<(), ProverError>>,
{
    static LOCK: OnceLock<Mutex<()>> = OnceLock::new();
    let guard = LOCK.get_or_init(|| Mutex::new(())).lock().await;
    let result = f().await;
    drop(guard);
    result
}

async fn run_vector(circuit: &str, name: &str) -> Result<(), ProverError> {
    let input = load_vector_input(circuit, name)?;
    let circuit_dir = artifacts_root().join(circuit);
    let wasm_path = circuit_dir.join(format!("{circuit}.wasm"));
    let zkey_path = circuit_dir.join(format!("{circuit}_final.zkey"));
    let vk_path = circuit_dir.join("verification_key.json");

    let output = generate_proof_snarkjs(circuit, &input, &wasm_path, &zkey_path).await?;
    let calldata =
        generate_garaga_calldata(&vk_path, &output.proof_path, &output.public_inputs_path).await?;
    if calldata.is_empty() {
        return Err(ProverError::Garaga("garaga calldata empty".to_string()));
    }
    Ok(())
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn prove_private_swap_vector() -> Result<(), ProverError> {
    with_prover_lock(|| run_vector("private_swap", "single_step_swap")).await
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn prove_private_swap_exact_out_vector() -> Result<(), ProverError> {
    with_prover_lock(|| run_vector("private_swap_exact_out", "single_step_swap_exact_out")).await
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn prove_private_liquidity_vector() -> Result<(), ProverError> {
    with_prover_lock(|| run_vector("private_liquidity", "add_liquidity_in_range")).await
}
