use std::collections::HashMap;
use std::sync::{Mutex, OnceLock};

use num_bigint::BigUint;
use num_traits::{ToPrimitive, Zero};
use starknet::core::types::{Event, Felt, TransactionReceipt, U256};

use crate::error::ClientError;

pub type Address = Felt;

const BN254_MODULUS_DEC: &str =
    "21888242871839275222246405745257275088548364400416034343698204186575808495617";
const STARK_FIELD_MODULUS_HEX: &str =
    "800000000000011000000000000000000000000000000000000000000000001";
const POSEIDON_CONSTANTS: &str = include_str!("../../../circuits/constants/poseidon_constants.circom");

const N_ROUNDS_P: [usize; 16] = [
    56, 57, 56, 60, 60, 63, 64, 63, 60, 66, 60, 65, 70, 60, 64, 68,
];

#[derive(Debug, Clone)]
struct PoseidonParams {
    n_rounds_f: usize,
    n_rounds_p: usize,
    c: Vec<BigUint>,
    s: Vec<BigUint>,
    m: Vec<Vec<BigUint>>,
    p: Vec<Vec<BigUint>>,
}

#[derive(Default)]
struct PoseidonCache {
    params: HashMap<usize, PoseidonParams>,
}

static POSEIDON_CACHE: OnceLock<Mutex<PoseidonCache>> = OnceLock::new();

pub fn poseidon_hash(inputs: &[Felt]) -> Result<Felt, ClientError> {
    let mut values = Vec::with_capacity(inputs.len());
    for input in inputs {
        values.push(felt_to_biguint(input));
    }
    let hashed = poseidon_hash_bn254(&values)?;
    bn254_to_felt(&hashed)
}

pub fn felt252_to_u256(felt: Felt) -> U256 {
    U256::from(felt)
}

pub fn u256_to_felt252(value: U256) -> (Felt, Felt) {
    (Felt::from(value.low()), Felt::from(value.high()))
}

pub fn felt_to_u128(value: &Felt) -> Result<u128, ClientError> {
    let bytes = value.to_bytes_be();
    if bytes[..16].iter().any(|b| *b != 0) {
        return Err(ClientError::InvalidInput("felt exceeds u128".to_string()));
    }
    let mut buf = [0u8; 16];
    buf.copy_from_slice(&bytes[16..32]);
    Ok(u128::from_be_bytes(buf))
}

pub fn felt_to_i32(value: &Felt) -> Result<i32, ClientError> {
    let modulus = stark_field_modulus()?;
    let as_big = felt_to_biguint(value);
    let max = BigUint::from(i32::MAX as u32);
    if as_big <= max {
        return as_big
            .to_i32()
            .ok_or_else(|| ClientError::InvalidInput("felt out of i32 range".to_string()));
    }

    let min_abs = BigUint::from(1u32) << 31;
    let lower_bound = &modulus - &min_abs;
    if as_big < lower_bound {
        return Err(ClientError::InvalidInput("felt out of i32 range".to_string()));
    }

    let mag = &modulus - &as_big;
    let mag_u32 = mag
        .to_u32()
        .ok_or_else(|| ClientError::InvalidInput("felt out of i32 range".to_string()))?;
    if mag_u32 == 0 || mag_u32 > (1u32 << 31) {
        return Err(ClientError::InvalidInput("felt out of i32 range".to_string()));
    }
    if mag_u32 == (1u32 << 31) {
        return Ok(i32::MIN);
    }
    Ok(-(mag_u32 as i32))
}

pub trait StarknetEvent: Sized {
    fn selector() -> Felt;
    fn from_event(keys: &[Felt], data: &[Felt]) -> Option<Self>;
}

pub fn parse_event<T: StarknetEvent>(receipt: &TransactionReceipt) -> Option<T> {
    for event in receipt_events(receipt) {
        let keys = &event.keys;
        if keys.first().copied() == Some(T::selector()) {
            return T::from_event(keys, &event.data);
        }
    }
    None
}

pub fn parse_felt(value: &str) -> Result<Felt, ClientError> {
    if value.starts_with("0x") {
        Felt::from_hex(value).map_err(|_| ClientError::InvalidInput("invalid felt".to_string()))
    } else {
        Felt::from_dec_str(value).map_err(|_| ClientError::InvalidInput("invalid felt".to_string()))
    }
}

fn receipt_events(receipt: &TransactionReceipt) -> &[Event] {
    match receipt {
        TransactionReceipt::Invoke(inner) => &inner.events,
        TransactionReceipt::L1Handler(inner) => &inner.events,
        TransactionReceipt::Declare(inner) => &inner.events,
        TransactionReceipt::Deploy(inner) => &inner.events,
        TransactionReceipt::DeployAccount(inner) => &inner.events,
    }
}

pub(crate) fn poseidon_hash_bn254(inputs: &[BigUint]) -> Result<BigUint, ClientError> {
    let t = inputs.len() + 1;
    let params = poseidon_params(t)?;
    let modulus = bn254_modulus()?;

    let mut state = vec![BigUint::zero(); t];
    for (idx, value) in inputs.iter().enumerate() {
        state[idx + 1] = value % &modulus;
    }

    add_round_constants(&mut state, &params.c, 0, &modulus);

    let half_full = params.n_rounds_f / 2;
    for round in 0..(half_full - 1) {
        apply_sigma(&mut state, &modulus);
        add_round_constants(&mut state, &params.c, (round + 1) * t, &modulus);
        state = mix(&state, &params.m, &modulus);
    }

    apply_sigma(&mut state, &modulus);
    add_round_constants(&mut state, &params.c, half_full * t, &modulus);
    state = mix(&state, &params.p, &modulus);

    let partial_offset = (half_full + 1) * t;
    for round in 0..params.n_rounds_p {
        let mut in_state = state.clone();
        let sigma = sigma(&in_state[0], &modulus);
        in_state[0] = mod_add(&sigma, &params.c[partial_offset + round], &modulus);

        let s_offset = (t * 2 - 1) * round;
        let mut next_state = vec![BigUint::zero(); t];
        let mut lc = BigUint::zero();
        for i in 0..t {
            let term = mod_mul(&params.s[s_offset + i], &in_state[i], &modulus);
            lc = mod_add(&lc, &term, &modulus);
        }
        next_state[0] = lc;
        for i in 1..t {
            let term = mod_mul(&in_state[0], &params.s[s_offset + t + i - 1], &modulus);
            next_state[i] = mod_add(&in_state[i], &term, &modulus);
        }
        state = next_state;
    }

    let second_offset = (half_full + 1) * t + params.n_rounds_p;
    for round in 0..(half_full - 1) {
        apply_sigma(&mut state, &modulus);
        add_round_constants(&mut state, &params.c, second_offset + round * t, &modulus);
        state = mix(&state, &params.m, &modulus);
    }

    apply_sigma(&mut state, &modulus);
    let mut output = BigUint::zero();
    for j in 0..t {
        let term = mod_mul(&params.m[j][0], &state[j], &modulus);
        output = mod_add(&output, &term, &modulus);
    }

    Ok(output)
}

pub(crate) fn bn254_to_felt(value: &BigUint) -> Result<Felt, ClientError> {
    let modulus = stark_field_modulus()?;
    if value >= &modulus {
        return Err(ClientError::Crypto("value exceeds Stark field".to_string()));
    }
    let bytes = biguint_to_bytes(value)?;
    Ok(Felt::from_bytes_be(&bytes))
}

fn poseidon_params(t: usize) -> Result<PoseidonParams, ClientError> {
    let cache = POSEIDON_CACHE.get_or_init(|| Mutex::new(PoseidonCache::default()));
    let mut cache = cache
        .lock()
        .map_err(|_| ClientError::Crypto("poseidon cache lock failed".to_string()))?;
    if let Some(params) = cache.params.get(&t) {
        return Ok(params.clone());
    }
    let parsed = parse_poseidon_params(t)?;
    cache.params.insert(t, parsed.clone());
    Ok(parsed)
}

fn parse_poseidon_params(t: usize) -> Result<PoseidonParams, ClientError> {
    if t < 2 || t > 17 {
        return Err(ClientError::InvalidInput("unsupported poseidon width".to_string()));
    }
    let n_rounds_f = 8;
    let n_rounds_p = N_ROUNDS_P[t - 2];

    let c_block = extract_constants_block("POSEIDON_C", t)?;
    let s_block = extract_constants_block("POSEIDON_S", t)?;
    let m_block = extract_constants_block("POSEIDON_M", t)?;
    let p_block = extract_constants_block("POSEIDON_P", t)?;

    let c_vals = parse_hex_numbers(&c_block)?;
    let s_vals = parse_hex_numbers(&s_block)?;
    let m_vals = parse_hex_numbers(&m_block)?;
    let p_vals = parse_hex_numbers(&p_block)?;

    let expected_c = t * n_rounds_f + n_rounds_p;
    if c_vals.len() != expected_c {
        return Err(ClientError::Crypto(format!(
            "poseidon C length mismatch expected {expected_c} got {}",
            c_vals.len()
        )));
    }

    let expected_s = n_rounds_p * (t * 2 - 1);
    if s_vals.len() != expected_s {
        return Err(ClientError::Crypto(format!(
            "poseidon S length mismatch expected {expected_s} got {}",
            s_vals.len()
        )));
    }

    let expected_matrix = t * t;
    if m_vals.len() != expected_matrix || p_vals.len() != expected_matrix {
        return Err(ClientError::Crypto("poseidon matrix length mismatch".to_string()));
    }

    let m = reshape_matrix(m_vals, t)?;
    let p = reshape_matrix(p_vals, t)?;

    Ok(PoseidonParams {
        n_rounds_f,
        n_rounds_p,
        c: c_vals,
        s: s_vals,
        m,
        p,
    })
}

fn extract_constants_block(func: &str, t: usize) -> Result<String, ClientError> {
    let func_marker = format!("function {func}(t)");
    let func_start = POSEIDON_CONSTANTS
        .find(&func_marker)
        .ok_or_else(|| ClientError::Crypto("poseidon constants missing".to_string()))?;
    let func_body = &POSEIDON_CONSTANTS[func_start..];
    let cond_marker = format!("t=={t}");
    let cond_start = func_body
        .find(&cond_marker)
        .ok_or_else(|| ClientError::Crypto("poseidon constants missing".to_string()))?;
    let after_cond = &func_body[cond_start..];
    let return_pos = after_cond
        .find("return")
        .ok_or_else(|| ClientError::Crypto("poseidon constants missing".to_string()))?;
    let after_return = &after_cond[return_pos..];
    let array_start = after_return
        .find('[')
        .ok_or_else(|| ClientError::Crypto("poseidon constants missing".to_string()))?;
    let array_slice = &after_return[array_start..];

    let mut depth = 0usize;
    for (idx, ch) in array_slice.char_indices() {
        if ch == '[' {
            depth += 1;
        } else if ch == ']' {
            depth = depth.saturating_sub(1);
            if depth == 0 {
                return Ok(array_slice[..=idx].to_string());
            }
        }
    }
    Err(ClientError::Crypto("poseidon constants malformed".to_string()))
}

fn parse_hex_numbers(block: &str) -> Result<Vec<BigUint>, ClientError> {
    let mut values = Vec::new();
    let bytes = block.as_bytes();
    let mut idx = 0usize;
    while idx + 1 < bytes.len() {
        if bytes[idx] == b'0' && bytes[idx + 1] == b'x' {
            idx += 2;
            let start = idx;
            while idx < bytes.len() && is_hex(bytes[idx]) {
                idx += 1;
            }
            let hex = &block[start..idx];
            let value = BigUint::parse_bytes(hex.as_bytes(), 16)
                .ok_or_else(|| ClientError::Crypto("invalid poseidon constant".to_string()))?;
            values.push(value);
        } else {
            idx += 1;
        }
    }
    Ok(values)
}

fn reshape_matrix(values: Vec<BigUint>, t: usize) -> Result<Vec<Vec<BigUint>>, ClientError> {
    let mut matrix = Vec::with_capacity(t);
    let mut iter = values.into_iter();
    for _ in 0..t {
        let mut row = Vec::with_capacity(t);
        for _ in 0..t {
            row.push(
                iter.next()
                    .ok_or_else(|| ClientError::Crypto("poseidon matrix malformed".to_string()))?,
            );
        }
        matrix.push(row);
    }
    Ok(matrix)
}

fn is_hex(byte: u8) -> bool {
    matches!(byte, b'0'..=b'9' | b'a'..=b'f' | b'A'..=b'F')
}

fn add_round_constants(state: &mut [BigUint], c: &[BigUint], offset: usize, modulus: &BigUint) {
    for (idx, value) in state.iter_mut().enumerate() {
        let constant = &c[offset + idx];
        *value = mod_add(value, constant, modulus);
    }
}

fn apply_sigma(state: &mut [BigUint], modulus: &BigUint) {
    for value in state.iter_mut() {
        *value = sigma(value, modulus);
    }
}

fn mix(state: &[BigUint], matrix: &[Vec<BigUint>], modulus: &BigUint) -> Vec<BigUint> {
    let t = state.len();
    let mut output = vec![BigUint::zero(); t];
    for i in 0..t {
        let mut acc = BigUint::zero();
        for j in 0..t {
            let term = mod_mul(&matrix[j][i], &state[j], modulus);
            acc = mod_add(&acc, &term, modulus);
        }
        output[i] = acc;
    }
    output
}

fn sigma(value: &BigUint, modulus: &BigUint) -> BigUint {
    let x2 = mod_mul(value, value, modulus);
    let x4 = mod_mul(&x2, &x2, modulus);
    mod_mul(&x4, value, modulus)
}

fn mod_add(a: &BigUint, b: &BigUint, modulus: &BigUint) -> BigUint {
    let mut sum = a + b;
    if &sum >= modulus {
        sum -= modulus;
    }
    sum
}

fn mod_mul(a: &BigUint, b: &BigUint, modulus: &BigUint) -> BigUint {
    (a * b) % modulus
}

fn bn254_modulus() -> Result<BigUint, ClientError> {
    BigUint::parse_bytes(BN254_MODULUS_DEC.as_bytes(), 10)
        .ok_or_else(|| ClientError::Crypto("invalid bn254 modulus".to_string()))
}

fn stark_field_modulus() -> Result<BigUint, ClientError> {
    BigUint::parse_bytes(STARK_FIELD_MODULUS_HEX.as_bytes(), 16)
        .ok_or_else(|| ClientError::Crypto("invalid Stark modulus".to_string()))
}

fn felt_to_biguint(felt: &Felt) -> BigUint {
    BigUint::from_bytes_be(&felt.to_bytes_be())
}

fn biguint_to_bytes(value: &BigUint) -> Result<[u8; 32], ClientError> {
    let bytes = value.to_bytes_be();
    if bytes.len() > 32 {
        return Err(ClientError::Crypto("value too large".to_string()));
    }
    let mut out = [0u8; 32];
    out[32 - bytes.len()..].copy_from_slice(&bytes);
    Ok(out)
}
