//! Garaga calldata generation helpers.
//! Requires the `garaga` CLI to be available on PATH.

use std::path::Path;

use num_bigint::BigUint;
use tokio::process::Command;

use crate::error::ProverError;

const STARK_FIELD_MODULUS_HEX: &str =
    "800000000000011000000000000000000000000000000000000000000000001";
const EXPECTED_GARAGA_VERSION: &str = "0.18.2";
const EXPECTED_GARAGA_SHA256: &str =
    "d9506be4e9f120a4ff6db3140c090ac6371ff502563241295df5153ef07d8345";

pub async fn generate_garaga_calldata(
    vk_path: &Path,
    proof_path: &Path,
    public_inputs_path: &Path,
) -> Result<Vec<String>, ProverError> {
    ensure_garaga_pinned().await?;
    if !vk_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing verification key at {}",
            vk_path.display()
        )));
    }
    if !proof_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing proof at {}",
            proof_path.display()
        )));
    }
    if !public_inputs_path.exists() {
        return Err(ProverError::InvalidInput(format!(
            "missing public inputs at {}",
            public_inputs_path.display()
        )));
    }

    let output = Command::new("garaga")
        .arg("calldata")
        .arg("--vk")
        .arg(vk_path)
        .arg("--proof")
        .arg(proof_path)
        .arg("--public-inputs")
        .arg(public_inputs_path)
        .arg("--system")
        .arg("groth16")
        .arg("--format")
        .arg("array")
        .output()
        .await
        .map_err(|err| ProverError::Garaga(format!("failed to run garaga: {err}")))?;

    if !output.status.success() {
        let stdout = String::from_utf8_lossy(&output.stdout);
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(ProverError::Garaga(format!(
            "garaga failed: {stdout} {stderr}"
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    let tokens: Vec<String> = stdout
        .split_whitespace()
        .map(normalize_token)
        .filter(|token| !token.is_empty())
        .collect();
    let start = tokens
        .iter()
        .position(|token| is_felt_token(token))
        .ok_or_else(|| ProverError::Garaga("garaga calldata empty".to_string()))?;
    let calldata: Vec<String> = tokens[start..].to_vec();
    if calldata.is_empty() {
        return Err(ProverError::Garaga("garaga calldata empty".to_string()));
    }
    Ok(calldata)
}

pub fn serialize_public_inputs_for_garaga(
    inputs: Vec<String>,
) -> Result<Vec<String>, ProverError> {
    inputs
        .into_iter()
        .map(|value| bn254_to_felt252(&value))
        .collect()
}

pub fn split_u256_to_u128(value: starknet::core::types::U256) -> (u128, u128) {
    (value.low(), value.high())
}

pub fn bn254_to_felt252(bn254_dec: &str) -> Result<String, ProverError> {
    let value = BigUint::parse_bytes(bn254_dec.as_bytes(), 10)
        .ok_or_else(|| ProverError::Conversion("invalid bn254 decimal".to_string()))?;
    let modulus = stark_field_modulus()?;
    if value >= modulus {
        return Err(ProverError::Conversion(
            "value exceeds Stark field".to_string(),
        ));
    }
    Ok(format!("0x{}", value.to_str_radix(16)))
}

pub fn bytes32_to_u128_limbs(value: [u8; 32]) -> (u128, u128) {
    let mut low_bytes = [0u8; 16];
    let mut high_bytes = [0u8; 16];
    high_bytes.copy_from_slice(&value[..16]);
    low_bytes.copy_from_slice(&value[16..]);
    (u128::from_be_bytes(low_bytes), u128::from_be_bytes(high_bytes))
}

fn stark_field_modulus() -> Result<BigUint, ProverError> {
    let modulus = BigUint::parse_bytes(STARK_FIELD_MODULUS_HEX.as_bytes(), 16)
        .ok_or_else(|| ProverError::Conversion("invalid Stark modulus".to_string()))?;
    Ok(modulus)
}

fn is_felt_token(token: &str) -> bool {
    token.starts_with("0x") || token.chars().all(|c| c.is_ascii_digit())
}

fn normalize_token(token: &str) -> String {
    token
        .trim_matches(|c| c == '[' || c == ']' || c == ',')
        .to_string()
}

async fn ensure_garaga_pinned() -> Result<(), ProverError> {
    let version_output = Command::new("garaga")
        .arg("--version")
        .output()
        .await
        .map_err(|err| ProverError::Garaga(format!("failed to run garaga: {err}")))?;
    if !version_output.status.success() {
        let stdout = String::from_utf8_lossy(&version_output.stdout);
        let stderr = String::from_utf8_lossy(&version_output.stderr);
        return Err(ProverError::Garaga(format!(
            "garaga --version failed: {stdout} {stderr}"
        )));
    }
    let version_stdout = String::from_utf8_lossy(&version_output.stdout);
    let version = parse_garaga_version(&version_stdout).ok_or_else(|| {
        ProverError::Garaga("garaga --version output unrecognized".to_string())
    })?;
    if version != EXPECTED_GARAGA_VERSION {
        return Err(ProverError::Garaga(format!(
            "garaga version mismatch: expected {} got {}",
            EXPECTED_GARAGA_VERSION, version
        )));
    }

    let path_output = Command::new("which")
        .arg("garaga")
        .output()
        .await
        .map_err(|err| ProverError::Garaga(format!("failed to locate garaga: {err}")))?;
    if !path_output.status.success() {
        return Err(ProverError::Garaga(
            "garaga not found on PATH".to_string(),
        ));
    }
    let path_stdout = String::from_utf8_lossy(&path_output.stdout);
    let garaga_path = path_stdout
        .lines()
        .next()
        .map(str::trim)
        .filter(|line| !line.is_empty())
        .ok_or_else(|| ProverError::Garaga("garaga path missing".to_string()))?;

    let sha_output = Command::new("sha256sum")
        .arg(garaga_path)
        .output()
        .await
        .map_err(|err| ProverError::Garaga(format!("sha256sum failed: {err}")))?;
    if !sha_output.status.success() {
        let stdout = String::from_utf8_lossy(&sha_output.stdout);
        let stderr = String::from_utf8_lossy(&sha_output.stderr);
        return Err(ProverError::Garaga(format!(
            "sha256sum failed: {stdout} {stderr}"
        )));
    }
    let sha_stdout = String::from_utf8_lossy(&sha_output.stdout);
    let sha = sha_stdout
        .split_whitespace()
        .next()
        .ok_or_else(|| ProverError::Garaga("sha256sum output empty".to_string()))?;
    if sha != EXPECTED_GARAGA_SHA256 {
        return Err(ProverError::Garaga(format!(
            "garaga checksum mismatch: expected {} got {}",
            EXPECTED_GARAGA_SHA256, sha
        )));
    }
    Ok(())
}

fn parse_garaga_version(output: &str) -> Option<String> {
    let trimmed = output.trim();
    let token = trimmed.split_whitespace().last()?;
    if token.chars().all(|c| c.is_ascii_digit() || c == '.') {
        Some(token.to_string())
    } else {
        None
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use starknet::core::types::U256;

    #[test]
    fn bn254_to_felt_accepts_small_value() {
        let felt = bn254_to_felt252("1").expect("convert");
        assert_eq!(felt, "0x1");
    }

    #[test]
    fn bn254_to_felt_rejects_modulus() {
        let modulus = BigUint::parse_bytes(STARK_FIELD_MODULUS_HEX.as_bytes(), 16)
            .expect("modulus");
        let value = modulus.to_str_radix(10);
        let err = bn254_to_felt252(&value).expect_err("reject modulus");
        match err {
            ProverError::Conversion(msg) => assert!(msg.contains("exceeds")),
            other => panic!("unexpected error: {other:?}"),
        }
    }

    #[test]
    fn bytes32_to_u128_limbs_splits_big_endian() {
        let mut bytes = [0u8; 32];
        bytes[..16].copy_from_slice(&[0x11; 16]);
        bytes[16..].copy_from_slice(&[0x22; 16]);
        let (low, high) = bytes32_to_u128_limbs(bytes);
        assert_eq!(high, u128::from_be_bytes([0x11; 16]));
        assert_eq!(low, u128::from_be_bytes([0x22; 16]));
    }

    #[test]
    fn split_u256_to_u128_matches_low_high() {
        let value = U256::from_words(0x1234_u128, 0x5678_u128);
        let (low, high) = split_u256_to_u128(value);
        assert_eq!(low, 0x1234_u128);
        assert_eq!(high, 0x5678_u128);
    }

    #[test]
    fn serialize_public_inputs_converts_bn254() {
        let inputs = vec!["1".to_string(), "2".to_string()];
        let out = serialize_public_inputs_for_garaga(inputs).expect("convert");
        assert_eq!(out, vec!["0x1", "0x2"]);
    }
}
