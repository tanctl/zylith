//! Garaga-based proof generation pipeline for Starknet.

mod error;
mod garaga_converter;
mod snarkjs;
mod starknet_types;
mod witness;

use std::path::Path;

pub use crate::error::ProverError;
pub use crate::garaga_converter::{
    bn254_to_felt252, bytes32_to_u128_limbs, generate_garaga_calldata,
    serialize_public_inputs_for_garaga, split_u256_to_u128,
};
pub use crate::snarkjs::{generate_proof_snarkjs, SnarkjsOutput, SnarkjsProof};
pub use crate::starknet_types::ProofCalldata;
pub use crate::witness::{
    generate_deposit_witness_inputs, generate_lp_add_witness_inputs, generate_lp_remove_witness_inputs,
    generate_swap_witness_inputs, generate_withdraw_witness_inputs, DepositWitnessInputs,
    LpWitnessInputs, SwapWitnessInputs, WithdrawWitnessInputs, WitnessValue,
};

pub async fn prove_swap(
    witness_inputs: SwapWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_swap_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_swap_with_vk(
    witness_inputs: SwapWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_swap_witness_inputs(witness_inputs)?;

    let wasm = circuit_dir.join("private_swap.wasm");
    let zkey = circuit_dir.join("private_swap_final.zkey");
    let snarkjs_output =
        generate_proof_snarkjs("private_swap", &witness_json, &wasm, &zkey).await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_swap_exact_out(
    witness_inputs: SwapWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_swap_exact_out_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_swap_exact_out_with_vk(
    witness_inputs: SwapWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_swap_witness_inputs(witness_inputs)?;

    let wasm = circuit_dir.join("private_swap_exact_out.wasm");
    let zkey = circuit_dir.join("private_swap_exact_out_final.zkey");
    let snarkjs_output =
        generate_proof_snarkjs("private_swap_exact_out", &witness_json, &wasm, &zkey).await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_lp_add(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_lp_add_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_lp_add_with_vk(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_lp_add_witness_inputs(witness_inputs)?;
    let wasm = circuit_dir.join("private_liquidity.wasm");
    let zkey = circuit_dir.join("private_liquidity_final.zkey");
    let snarkjs_output = generate_proof_snarkjs(
        "private_liquidity",
        &witness_json,
        &wasm,
        &zkey,
    )
    .await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_lp_remove(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_lp_remove_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_lp_remove_with_vk(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_lp_remove_witness_inputs(witness_inputs)?;
    let wasm = circuit_dir.join("private_liquidity.wasm");
    let zkey = circuit_dir.join("private_liquidity_final.zkey");
    let snarkjs_output = generate_proof_snarkjs(
        "private_liquidity",
        &witness_json,
        &wasm,
        &zkey,
    )
    .await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_lp_claim(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_lp_claim_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_lp_claim_with_vk(
    witness_inputs: LpWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_lp_remove_witness_inputs(witness_inputs)?;
    let wasm = circuit_dir.join("private_liquidity.wasm");
    let zkey = circuit_dir.join("private_liquidity_final.zkey");
    let snarkjs_output = generate_proof_snarkjs(
        "private_liquidity",
        &witness_json,
        &wasm,
        &zkey,
    )
    .await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_deposit(
    witness_inputs: DepositWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_deposit_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_deposit_with_vk(
    witness_inputs: DepositWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_deposit_witness_inputs(witness_inputs)?;

    let wasm = circuit_dir.join("private_deposit.wasm");
    let zkey = circuit_dir.join("private_deposit_final.zkey");
    let snarkjs_output =
        generate_proof_snarkjs("private_deposit", &witness_json, &wasm, &zkey).await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}

pub async fn prove_withdraw(
    witness_inputs: WithdrawWitnessInputs,
    circuit_dir: &Path,
) -> Result<ProofCalldata, ProverError> {
    let vk_path = circuit_dir.join("verification_key.json");
    prove_withdraw_with_vk(witness_inputs, circuit_dir, &vk_path).await
}

pub async fn prove_withdraw_with_vk(
    witness_inputs: WithdrawWitnessInputs,
    circuit_dir: &Path,
    vk_path: &Path,
) -> Result<ProofCalldata, ProverError> {
    let witness_json = generate_withdraw_witness_inputs(witness_inputs)?;

    let wasm = circuit_dir.join("private_withdraw.wasm");
    let zkey = circuit_dir.join("private_withdraw_final.zkey");
    let snarkjs_output =
        generate_proof_snarkjs("private_withdraw", &witness_json, &wasm, &zkey).await?;
    let calldata = generate_garaga_calldata(
        vk_path,
        &snarkjs_output.proof_path,
        &snarkjs_output.public_inputs_path,
    )
    .await?;
    Ok(ProofCalldata::new(calldata))
}
