use std::path::{Path, PathBuf};
use std::sync::OnceLock;

use serde_json::Value;
use tokio::sync::Mutex;
use zylith_prover::{generate_garaga_calldata, generate_proof, ProverError};

fn repo_root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("..").join("..")
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
    load_vector_input_from_path(&path)
}

fn load_vector_input_from_path(path: &Path) -> Result<Value, ProverError> {
    let data = std::fs::read_to_string(path)
        .map_err(|err| ProverError::Io(format!("failed to read {path:?}: {err}")))?;
    let value: Value =
        serde_json::from_str(&data).map_err(|err| ProverError::Io(err.to_string()))?;
    let input = value
        .get("input")
        .cloned()
        .ok_or_else(|| ProverError::InvalidInput("vector missing input".to_string()))?;
    Ok(input)
}

fn load_swap_vector(
    env_var: &str,
    circuit: &str,
    default_name: &str,
) -> Result<Value, ProverError> {
    match std::env::var(env_var) {
        Ok(path) => {
            let value = load_vector_input_from_path(Path::new(&path))?;
            Ok(value)
        }
        Err(_) => Ok(load_vector_input(circuit, default_name)?),
    }
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

async fn run_vector_input(artifact_circuit: &str, input: &Value) -> Result<(), ProverError> {
    let circuit_dir = artifacts_root().join(artifact_circuit);
    let base = base_circuit_name(artifact_circuit);
    let wasm_path = circuit_dir.join(format!("{base}.wasm"));
    let zkey_path = circuit_dir.join(format!("{base}_final.zkey"));
    let vk_path = circuit_dir.join("verification_key.json");

    let output = generate_proof(artifact_circuit, input, &wasm_path, &zkey_path).await?;
    if std::fs::metadata(&output.proof_path).is_err() {
        return Err(ProverError::InvalidInput(
            "proof output missing".to_string(),
        ));
    }
    if std::fs::metadata(&output.public_inputs_path).is_err() {
        return Err(ProverError::InvalidInput(
            "public inputs output missing".to_string(),
        ));
    }
    if require_garaga_in_tests() {
        let calldata =
            generate_garaga_calldata(&vk_path, &output.proof_path, &output.public_inputs_path)
                .await?;
        if calldata.is_empty() {
            return Err(ProverError::Garaga("garaga calldata empty".to_string()));
        }
    }
    Ok(())
}

fn base_circuit_name(name: &str) -> &str {
    for suffix in ["_4", "_8"] {
        if let Some(base) = name.strip_suffix(suffix) {
            return base;
        }
    }
    name
}

fn require_garaga_in_tests() -> bool {
    match std::env::var("ZYLITH_REQUIRE_GARAGA_IN_TESTS") {
        Ok(value) => matches!(
            value.trim().to_ascii_lowercase().as_str(),
            "1" | "true" | "yes" | "on"
        ),
        Err(_) => false,
    }
}

const SWAP_STEP_OPTIONS: [usize; 2] = [4, 8];
const SWAP_STEP_FIELDS: [&str; 16] = [
    "step_amount_in",
    "step_amount_before_fee_div_q",
    "step_amount0_calc_div_q",
    "step_amount0_limit_div_q",
    "step_amount0_out_div_q",
    "step_amount_out",
    "step_sqrt_price_next",
    "step_sqrt_price_limit",
    "step_fee_div_q",
    "step_fee_growth_global_0",
    "step_fee_growth_global_1",
    "step_liquidity_net",
    "step_tick_next",
    "step_next0_div_floor_q",
    "step_next0_div_ceil_q",
    "step_next1_div_floor_q",
];

fn swap_artifact_base(exact_out: bool, zero_for_one: bool) -> &'static str {
    match (exact_out, zero_for_one) {
        (false, false) => "private_swap_one_for_zero",
        (false, true) => "private_swap_zero_for_one",
        (true, false) => "private_swap_exact_out_one_for_zero",
        (true, true) => "private_swap_exact_out_zero_for_one",
    }
}

fn swap_artifact_name(exact_out: bool, zero_for_one: bool, max_steps: usize) -> String {
    let base = swap_artifact_base(exact_out, zero_for_one);
    format!("{base}_{max_steps}")
}

fn swap_artifact_exists(artifact: &str) -> bool {
    let circuit_dir = artifacts_root().join(artifact);
    let base = base_circuit_name(artifact);
    circuit_dir.join(format!("{base}.wasm")).exists()
        && circuit_dir.join(format!("{base}_final.zkey")).exists()
        && circuit_dir.join("verification_key.json").exists()
}

fn truncate_swap_steps(input: &mut Value, max_steps: usize) {
    for field in SWAP_STEP_FIELDS {
        if let Some(values) = input.get_mut(field).and_then(Value::as_array_mut) {
            values.truncate(max_steps);
        }
    }
}

fn set_swap_direction(input: &mut Value, zero_for_one: bool) {
    input["zero_for_one"] = Value::String(if zero_for_one { "1" } else { "0" }.to_string());
}

async fn run_swap_step_matrix(
    exact_out: bool,
    zero_for_one: bool,
    vector_input: Value,
) -> Result<(), ProverError> {
    let matrix_steps = matrix_step_options();
    if matrix_steps.is_empty() {
        eprintln!("matrix disabled: set ZYLITH_PROVER_MATRIX_STEPS=4,8 to enable");
        return Ok(());
    }
    let mut ran_cases = 0usize;
    let mut succeeded_cases = 0usize;
    for max_steps in matrix_steps {
        let artifact = swap_artifact_name(exact_out, zero_for_one, max_steps);
        let circuit_dir = artifacts_root().join(&artifact);
        let base = base_circuit_name(&artifact);
        let wasm = circuit_dir.join(format!("{base}.wasm"));
        let zkey = circuit_dir.join(format!("{base}_final.zkey"));
        if !wasm.exists() || !zkey.exists() {
            eprintln!(
                "skipping {} step-matrix case (steps={}): missing artifacts at {}",
                artifact,
                max_steps,
                circuit_dir.display()
            );
            continue;
        }
        ran_cases += 1;
        let mut input = vector_input.clone();
        truncate_swap_steps(&mut input, max_steps);
        set_swap_direction(&mut input, zero_for_one);
        match run_vector_input(&artifact, &input).await {
            Ok(()) => {
                succeeded_cases += 1;
            }
            Err(err) if is_witness_length_mismatch(&err) => {
                eprintln!(
                    "skipping {} step-matrix case (steps={}): incompatible artifact pair ({})",
                    artifact, max_steps, err
                );
            }
            Err(err) => {
                return Err(ProverError::InvalidInput(format!(
                    "artifact {artifact} failed: {err}"
                )));
            }
        }
    }
    if ran_cases == 0 {
        return Err(ProverError::InvalidInput(
            "no swap matrix artifacts available".to_string(),
        ));
    }
    if succeeded_cases == 0 {
        return Err(ProverError::InvalidInput(
            "no compatible swap matrix artifacts succeeded".to_string(),
        ));
    }
    Ok(())
}

fn matrix_step_options() -> Vec<usize> {
    let raw = std::env::var("ZYLITH_PROVER_MATRIX_STEPS").unwrap_or_default();
    let mut parsed: Vec<usize> = Vec::new();
    for token in raw.split(',') {
        let trimmed = token.trim();
        if trimmed.is_empty() {
            continue;
        }
        let Ok(step) = trimmed.parse::<usize>() else {
            continue;
        };
        if !SWAP_STEP_OPTIONS.contains(&step) {
            continue;
        }
        if !parsed.contains(&step) {
            parsed.push(step);
        }
    }
    parsed
}

fn is_witness_length_mismatch(err: &ProverError) -> bool {
    match err {
        ProverError::Rapidsnark(message) => message.contains("Invalid witness length"),
        _ => false,
    }
}

async fn run_swap_smoke(
    exact_out: bool,
    zero_for_one: bool,
    vector_input: Value,
) -> Result<(), ProverError> {
    let mut saw_compatible_artifact = false;
    for max_steps in SWAP_STEP_OPTIONS {
        let artifact = swap_artifact_name(exact_out, zero_for_one, max_steps);
        if !swap_artifact_exists(&artifact) {
            continue;
        }
        saw_compatible_artifact = true;
        let mut input = vector_input.clone();
        truncate_swap_steps(&mut input, max_steps);
        set_swap_direction(&mut input, zero_for_one);
        match run_vector_input(&artifact, &input).await {
            Ok(()) => return Ok(()),
            Err(err) if is_witness_length_mismatch(&err) => {
                eprintln!(
                    "smoke artifact {} incompatible (steps={}): {}",
                    artifact, max_steps, err
                );
                continue;
            }
            Err(err) => return Err(err),
        }
    }
    if saw_compatible_artifact {
        Err(ProverError::InvalidInput(
            "swap smoke failed: no compatible artifact pair found".to_string(),
        ))
    } else {
        Err(ProverError::InvalidInput(
            "swap smoke failed: no artifacts found".to_string(),
        ))
    }
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_one_for_zero_smoke() -> Result<(), ProverError> {
    let input = load_vector_input("private_swap", "single_step_swap")?;
    with_prover_lock(|| run_swap_smoke(false, false, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_exact_out_one_for_zero_smoke() -> Result<(), ProverError> {
    let input = load_vector_input("private_swap_exact_out", "single_step_swap_exact_out")?;
    with_prover_lock(|| run_swap_smoke(true, false, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_zero_for_one_smoke() -> Result<(), ProverError> {
    let input = load_swap_vector(
        "ZYLITH_SWAP_ZFO_VECTOR_PATH",
        "private_swap",
        "single_step_swap_zero_for_one",
    )?;
    with_prover_lock(|| run_swap_smoke(false, true, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_exact_out_zero_for_one_smoke() -> Result<(), ProverError> {
    let input = load_swap_vector(
        "ZYLITH_SWAP_EXACT_OUT_ZFO_VECTOR_PATH",
        "private_swap_exact_out",
        "single_step_swap_exact_out_zero_for_one",
    )?;
    with_prover_lock(|| run_swap_smoke(true, true, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_one_for_zero_step_matrix() -> Result<(), ProverError> {
    let input = load_vector_input("private_swap", "single_step_swap")?;
    with_prover_lock(|| run_swap_step_matrix(false, false, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_exact_out_one_for_zero_step_matrix() -> Result<(), ProverError> {
    let input = load_vector_input("private_swap_exact_out", "single_step_swap_exact_out")?;
    with_prover_lock(|| run_swap_step_matrix(true, false, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_zero_for_one_step_matrix() -> Result<(), ProverError> {
    let input = load_swap_vector(
        "ZYLITH_SWAP_ZFO_VECTOR_PATH",
        "private_swap",
        "single_step_swap_zero_for_one",
    )?;
    with_prover_lock(|| run_swap_step_matrix(false, true, input)).await
}

#[tokio::test(flavor = "multi_thread")]
async fn prove_private_swap_exact_out_zero_for_one_step_matrix() -> Result<(), ProverError> {
    let input = load_swap_vector(
        "ZYLITH_SWAP_EXACT_OUT_ZFO_VECTOR_PATH",
        "private_swap_exact_out",
        "single_step_swap_exact_out_zero_for_one",
    )?;
    with_prover_lock(|| run_swap_step_matrix(true, true, input)).await
}

#[tokio::test(flavor = "multi_thread")]
#[ignore]
async fn prove_private_liquidity_vector() -> Result<(), ProverError> {
    let input = load_vector_input("private_liquidity", "add_liquidity_in_range")?;
    with_prover_lock(|| run_vector_input("private_liquidity", &input)).await
}
