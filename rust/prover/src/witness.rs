//! Witness input formatting for Circom circuits.

use std::collections::HashMap;

use num_bigint::BigUint;
use serde_json::Value;
use starknet::core::types::U256;

use crate::error::ProverError;

#[derive(Debug, Clone)]
pub enum WitnessValue {
    Scalar(String),
    U128(u128),
    I32(i32),
    Bool(bool),
    Bytes32([u8; 32]),
    U256(U256),
    VecU128(Vec<u128>),
    VecI32(Vec<i32>),
    VecBool(Vec<bool>),
    VecBytes32(Vec<[u8; 32]>),
    VecU256(Vec<U256>),
    MatrixU128(Vec<Vec<u128>>),
    MatrixU256(Vec<Vec<U256>>),
    TensorU128(Vec<Vec<Vec<u128>>>),
    TensorU256(Vec<Vec<Vec<U256>>>),
    Raw(Value),
}

#[derive(Debug, Clone, Default)]
pub struct LpWitnessInputs {
    pub values: HashMap<String, WitnessValue>,
}

#[derive(Debug, Clone, Default)]
pub struct SwapWitnessInputs {
    pub values: HashMap<String, WitnessValue>,
}

#[derive(Debug, Clone, Default)]
pub struct DepositWitnessInputs {
    pub values: HashMap<String, WitnessValue>,
}

#[derive(Debug, Clone, Default)]
pub struct WithdrawWitnessInputs {
    pub values: HashMap<String, WitnessValue>,
}

pub fn generate_swap_witness_inputs(inputs: SwapWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_values(inputs.values)
}

/// builds a witness json from caller-supplied fields matching the liquidity circuit inputs.
pub fn generate_lp_add_witness_inputs(inputs: LpWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_map(inputs)
}

/// builds a witness json from caller-supplied fields matching the liquidity circuit inputs.
pub fn generate_lp_remove_witness_inputs(inputs: LpWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_map(inputs)
}

/// builds a witness json from caller-supplied fields matching the deposit circuit inputs.
pub fn generate_deposit_witness_inputs(inputs: DepositWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_values(inputs.values)
}

/// builds a witness json from caller-supplied fields matching the withdraw circuit inputs.
pub fn generate_withdraw_witness_inputs(inputs: WithdrawWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_values(inputs.values)
}

fn build_witness_from_map(inputs: LpWitnessInputs) -> Result<Value, ProverError> {
    build_witness_from_values(inputs.values)
}

fn build_witness_from_values(
    values: HashMap<String, WitnessValue>,
) -> Result<Value, ProverError> {
    let mut map = serde_json::Map::new();
    for (key, value) in values {
        map.insert(key, witness_value_to_json(value)?);
    }
    Ok(Value::Object(map))
}

fn witness_value_to_json(value: WitnessValue) -> Result<Value, ProverError> {
    match value {
        WitnessValue::Scalar(value) => Ok(Value::String(value)),
        WitnessValue::U128(value) => Ok(Value::String(value.to_string())),
        WitnessValue::I32(value) => Ok(Value::String(encode_i32_twos_complement(value).to_string())),
        WitnessValue::Bool(value) => Ok(Value::String(bool_to_string(value))),
        WitnessValue::Bytes32(value) => Ok(Value::String(bytes_to_decimal(value))),
        WitnessValue::U256(value) => Ok(Value::Array(
            u256_to_limbs(value)
                .into_iter()
                .map(Value::String)
                .collect(),
        )),
        WitnessValue::VecU128(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|v| Value::String(v.to_string()))
                .collect(),
        )),
        WitnessValue::VecI32(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|v| Value::String(encode_i32_twos_complement(v).to_string()))
                .collect(),
        )),
        WitnessValue::VecBool(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|v| Value::String(bool_to_string(v)))
                .collect(),
        )),
        WitnessValue::VecBytes32(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|v| Value::String(bytes_to_decimal(v)))
                .collect(),
        )),
        WitnessValue::VecU256(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|v| {
                    Value::Array(u256_to_limbs(v).into_iter().map(Value::String).collect())
                })
                .collect(),
        )),
        WitnessValue::MatrixU128(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|row| {
                    Value::Array(row.into_iter().map(|v| Value::String(v.to_string())).collect())
                })
                .collect(),
        )),
        WitnessValue::MatrixU256(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|row| {
                    Value::Array(
                        row.into_iter()
                            .map(|v| {
                                Value::Array(
                                    u256_to_limbs(v)
                                        .into_iter()
                                        .map(Value::String)
                                        .collect(),
                                )
                            })
                            .collect(),
                    )
                })
                .collect(),
        )),
        WitnessValue::TensorU128(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|matrix| {
                    Value::Array(
                        matrix
                            .into_iter()
                            .map(|row| {
                                Value::Array(
                                    row.into_iter()
                                        .map(|v| Value::String(v.to_string()))
                                        .collect(),
                                )
                            })
                            .collect(),
                    )
                })
                .collect(),
        )),
        WitnessValue::TensorU256(values) => Ok(Value::Array(
            values
                .into_iter()
                .map(|matrix| {
                    Value::Array(
                        matrix
                            .into_iter()
                            .map(|row| {
                                Value::Array(
                                    row.into_iter()
                                        .map(|v| {
                                            Value::Array(
                                                u256_to_limbs(v)
                                                    .into_iter()
                                                    .map(Value::String)
                                                    .collect(),
                                            )
                                        })
                                        .collect(),
                                )
                            })
                            .collect(),
                    )
                })
                .collect(),
        )),
        WitnessValue::Raw(value) => Ok(value),
    }
}

fn bytes_to_decimal(bytes: [u8; 32]) -> String {
    let value = BigUint::from_bytes_be(&bytes);
    value.to_str_radix(10)
}

fn bool_to_string(value: bool) -> String {
    if value { "1".to_string() } else { "0".to_string() }
}

fn u128_to_limbs(value: u128) -> [String; 2] {
    let low = value as u64;
    let high = (value >> 64) as u64;
    [low.to_string(), high.to_string()]
}

fn encode_i32_twos_complement(value: i32) -> u128 {
    if value >= 0 {
        value as u128
    } else {
        let mag = (-(value as i128)) as u128;
        u128::MAX - (mag - 1)
    }
}

fn u256_to_limbs(value: U256) -> [String; 4] {
    let low = value.low();
    let high = value.high();
    let low_limbs = u128_to_limbs(low);
    let high_limbs = u128_to_limbs(high);
    [
        low_limbs[0].clone(),
        low_limbs[1].clone(),
        high_limbs[0].clone(),
        high_limbs[1].clone(),
    ]
}
