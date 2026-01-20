use std::sync::OnceLock;
use rand::rngs::OsRng;
use rand::RngCore;
use chacha20poly1305::aead::{Aead, KeyInit, Payload};
use chacha20poly1305::{XChaCha20Poly1305, XNonce};
use starknet::core::types::{Felt, U256};
use zeroize::{Zeroize, ZeroizeOnDrop, Zeroizing};

use crate::error::ClientError;
use crate::generated_constants;
use crate::utils::{bn254_to_felt, poseidon_hash_bn254, Address};

const DOMAIN_TAG: u64 = 0x5a594c495448; // "ZYLITH"
const NOTE_TYPE_TOKEN: u8 = 1;
const NOTE_TYPE_POSITION: u8 = 2;
const POSITION_TOKEN_ID: u8 = 2;
const MAX_NOTE_GEN_ATTEMPTS: usize = 8192;
static ZERO_LEAF_HASH: OnceLock<Felt> = OnceLock::new();

#[derive(Debug, Clone, Zeroize, ZeroizeOnDrop)]
pub struct Note {
    pub secret: [u8; 32],
    pub nullifier: [u8; 32],
    pub amount: u128,
    #[zeroize(skip)]
    pub token: Address,
}

#[derive(Debug, Clone, Zeroize, ZeroizeOnDrop)]
pub struct PositionNote {
    pub secret: [u8; 32],
    pub nullifier: [u8; 32],
    #[zeroize(skip)]
    pub tick_lower: i32,
    #[zeroize(skip)]
    pub tick_upper: i32,
    #[zeroize(skip)]
    pub liquidity: u128,
    #[zeroize(skip)]
    pub fee_growth_inside_0: U256,
    #[zeroize(skip)]
    pub fee_growth_inside_1: U256,
}

#[derive(Debug, Clone)]
pub struct EncryptedNote {
    pub nonce: [u8; 24],
    pub tag: [u8; 16],
    pub ciphertext: Zeroizing<Vec<u8>>,
}

pub fn generate_note(amount: u128, token: Address) -> Result<Note, ClientError> {
    for _ in 0..MAX_NOTE_GEN_ATTEMPTS {
        let note = random_note(amount, token);
        if compute_commitment(&note, 0).is_ok() && compute_commitment(&note, 1).is_ok() {
            return Ok(note);
        }
    }
    Err(ClientError::Crypto(
        "note generation failed after max attempts".to_string(),
    ))
}

pub fn generate_position_note(
    tick_lower: i32,
    tick_upper: i32,
    liquidity: u128,
    fee_growth_inside_0: U256,
    fee_growth_inside_1: U256,
) -> Result<PositionNote, ClientError> {
    for _ in 0..MAX_NOTE_GEN_ATTEMPTS {
        let note = random_position_note(
            tick_lower,
            tick_upper,
            liquidity,
            fee_growth_inside_0,
            fee_growth_inside_1,
        );
        if compute_position_commitment(&note).is_ok() {
            return Ok(note);
        }
    }
    Err(ClientError::Crypto(
        "position note generation failed after max attempts".to_string(),
    ))
}

pub fn generate_note_with_token_id(
    amount: u128,
    token: Address,
    token_id: u8,
) -> Result<Note, ClientError> {
    if token_id > 1 {
        return Err(ClientError::InvalidInput("token id must be 0 or 1".to_string()));
    }
    for _ in 0..MAX_NOTE_GEN_ATTEMPTS {
        let note = random_note(amount, token);
        if compute_commitment(&note, token_id).is_ok() {
            return Ok(note);
        }
    }
    Err(ClientError::Crypto(
        "note generation failed after max attempts".to_string(),
    ))
}

fn random_note(amount: u128, token: Address) -> Note {
    let mut secret = [0u8; 32];
    let mut nullifier = [0u8; 32];
    OsRng.fill_bytes(&mut secret);
    OsRng.fill_bytes(&mut nullifier);
    Note {
        secret,
        nullifier,
        amount,
        token,
    }
}

fn random_position_note(
    tick_lower: i32,
    tick_upper: i32,
    liquidity: u128,
    fee_growth_inside_0: U256,
    fee_growth_inside_1: U256,
) -> PositionNote {
    let mut secret = [0u8; 32];
    let mut nullifier = [0u8; 32];
    OsRng.fill_bytes(&mut secret);
    OsRng.fill_bytes(&mut nullifier);
    PositionNote {
        secret,
        nullifier,
        tick_lower,
        tick_upper,
        liquidity,
        fee_growth_inside_0,
        fee_growth_inside_1,
    }
}

pub fn compute_commitment(note: &Note, token_id: u8) -> Result<Felt, ClientError> {
    if token_id > 1 {
        return Err(ClientError::InvalidInput("token id must be 0 or 1".to_string()));
    }
    let nullifier = generate_nullifier_hash(note, token_id)?;
    if nullifier == Felt::ZERO {
        return Err(ClientError::Crypto("nullifier is zero".to_string()));
    }
    let inputs = vec![
        biguint_from_u64(DOMAIN_TAG),
        biguint_from_u8(NOTE_TYPE_TOKEN),
        biguint_from_u8(token_id),
        biguint_from_u128(note.amount),
        biguint_from_bytes(&note.secret),
        biguint_from_felt(&nullifier),
    ];
    let commitment = poseidon_hash_bn254(&inputs)?;
    let commitment_felt = bn254_to_felt(&commitment)?;
    if commitment_felt == Felt::ZERO {
        return Err(ClientError::Crypto("commitment is zero".to_string()));
    }
    let zero_hash = zero_leaf_hash()?;
    if commitment_felt == zero_hash {
        return Err(ClientError::Crypto("commitment equals zero leaf hash".to_string()));
    }
    Ok(commitment_felt)
}

pub fn compute_position_commitment(note: &PositionNote) -> Result<Felt, ClientError> {
    let nullifier = generate_position_nullifier_hash(note)?;
    if nullifier == Felt::ZERO {
        return Err(ClientError::Crypto("nullifier is zero".to_string()));
    }
    let tick_lower = encode_i32_twos_complement(note.tick_lower);
    let tick_upper = encode_i32_twos_complement(note.tick_upper);
    let fee0_low = note.fee_growth_inside_0.low();
    let fee0_high = note.fee_growth_inside_0.high();
    let fee1_low = note.fee_growth_inside_1.low();
    let fee1_high = note.fee_growth_inside_1.high();
    let inputs = vec![
        biguint_from_u64(DOMAIN_TAG),
        biguint_from_u8(NOTE_TYPE_POSITION),
        biguint_from_u8(POSITION_TOKEN_ID),
        biguint_from_u128(tick_lower),
        biguint_from_u128(tick_upper),
        biguint_from_u128(note.liquidity),
        biguint_from_u128(fee0_low),
        biguint_from_u128(fee0_high),
        biguint_from_u128(fee1_low),
        biguint_from_u128(fee1_high),
        biguint_from_bytes(&note.secret),
        biguint_from_felt(&nullifier),
    ];
    let commitment = poseidon_hash_bn254(&inputs)?;
    let commitment_felt = bn254_to_felt(&commitment)?;
    if commitment_felt == Felt::ZERO {
        return Err(ClientError::Crypto("commitment is zero".to_string()));
    }
    let zero_hash = zero_leaf_hash()?;
    if commitment_felt == zero_hash {
        return Err(ClientError::Crypto("commitment equals zero leaf hash".to_string()));
    }
    Ok(commitment_felt)
}

pub fn generate_nullifier_hash(note: &Note, token_id: u8) -> Result<Felt, ClientError> {
    if token_id > 1 {
        return Err(ClientError::InvalidInput("token id must be 0 or 1".to_string()));
    }
    let inputs = vec![
        biguint_from_u64(DOMAIN_TAG),
        biguint_from_u8(NOTE_TYPE_TOKEN),
        biguint_from_u8(token_id),
        biguint_from_bytes(&note.secret),
        biguint_from_bytes(&note.nullifier),
    ];
    let nullifier = poseidon_hash_bn254(&inputs)?;
    bn254_to_felt(&nullifier)
}

pub fn generate_position_nullifier_hash(note: &PositionNote) -> Result<Felt, ClientError> {
    let inputs = vec![
        biguint_from_u64(DOMAIN_TAG),
        biguint_from_u8(NOTE_TYPE_POSITION),
        biguint_from_u8(POSITION_TOKEN_ID),
        biguint_from_bytes(&note.secret),
        biguint_from_bytes(&note.nullifier),
    ];
    let nullifier = poseidon_hash_bn254(&inputs)?;
    bn254_to_felt(&nullifier)
}

// Uses a symmetric 32-byte key, the same key must be supplied for decryption.
pub fn encrypt_note(note: &Note, shared_key: &[u8; 32]) -> Result<EncryptedNote, ClientError> {
    let plaintext = Zeroizing::new(serialize_note(note)?);
    let cipher = XChaCha20Poly1305::new_from_slice(shared_key)
        .map_err(|_| ClientError::Crypto("invalid shared key".to_string()))?;
    let mut nonce = [0u8; 24];
    OsRng.fill_bytes(&mut nonce);
    let mut ciphertext = cipher
        .encrypt(
            XNonce::from_slice(&nonce),
            Payload {
                msg: &plaintext,
                aad: b"zylith-note-v1",
            },
        )
        .map_err(|_| ClientError::Crypto("note encryption failed".to_string()))?;
    if ciphertext.len() < 16 {
        return Err(ClientError::Crypto("ciphertext too short".to_string()));
    }
    let tag_offset = ciphertext.len() - 16;
    let tag: [u8; 16] = ciphertext[tag_offset..]
        .try_into()
        .map_err(|_| ClientError::Crypto("invalid tag length".to_string()))?;
    ciphertext.truncate(tag_offset);
    Ok(EncryptedNote {
        nonce,
        tag,
        ciphertext: Zeroizing::new(ciphertext),
    })
}

pub fn decrypt_note(encrypted: &EncryptedNote, shared_key: &[u8; 32]) -> Result<Note, ClientError> {
    let cipher = XChaCha20Poly1305::new_from_slice(shared_key)
        .map_err(|_| ClientError::Crypto("invalid shared key".to_string()))?;
    let mut combined = encrypted.ciphertext.clone();
    combined.extend_from_slice(&encrypted.tag);
    let plaintext = cipher
        .decrypt(
            XNonce::from_slice(&encrypted.nonce),
            Payload {
                msg: &combined,
                aad: b"zylith-note-v1",
            },
        )
        .map_err(|_| ClientError::Crypto("note decryption failed".to_string()))?;
    let plaintext = Zeroizing::new(plaintext);
    deserialize_note(&plaintext)
}

fn serialize_note(note: &Note) -> Result<Vec<u8>, ClientError> {
    let mut out = Vec::with_capacity(112);
    out.extend_from_slice(&note.secret);
    out.extend_from_slice(&note.nullifier);
    out.extend_from_slice(&note.amount.to_be_bytes());
    out.extend_from_slice(&note.token.to_bytes_be());
    Ok(out)
}

fn deserialize_note(bytes: &[u8]) -> Result<Note, ClientError> {
    if bytes.len() != 112 {
        return Err(ClientError::InvalidInput("invalid note length".to_string()));
    }
    let mut secret = [0u8; 32];
    let mut nullifier = [0u8; 32];
    let mut token_bytes = [0u8; 32];
    secret.copy_from_slice(&bytes[0..32]);
    nullifier.copy_from_slice(&bytes[32..64]);
    let amount = u128::from_be_bytes(bytes[64..80].try_into().map_err(|_| {
        ClientError::InvalidInput("invalid amount bytes".to_string())
    })?);
    token_bytes.copy_from_slice(&bytes[80..112]);
    let token = Felt::from_bytes_be(&token_bytes);
    Ok(Note {
        secret,
        nullifier,
        amount,
        token,
    })
}

fn encode_i32_twos_complement(value: i32) -> u128 {
    if value >= 0 {
        value as u128
    } else {
        let mag = (-(value as i128)) as u128;
        u128::MAX.wrapping_sub(mag).wrapping_add(1)
    }
}

#[cfg(test)]
mod tests {
    use super::{compute_position_commitment, generate_position_nullifier_hash, PositionNote};
    use starknet::core::types::{Felt, U256};

    #[test]
    fn position_commitment_is_nonzero() {
        let note = PositionNote {
            secret: [
                211, 15, 22, 72, 163, 53, 19, 66, 226, 161, 218, 116, 203, 148, 103, 66, 114,
                160, 233, 13, 172, 24, 153, 56, 161, 32, 120, 100, 195, 50, 111, 117,
            ],
            nullifier: [
                182, 162, 203, 162, 95, 64, 226, 9, 170, 27, 196, 217, 168, 30, 179, 104, 108,
                174, 175, 64, 113, 33, 30, 118, 225, 154, 65, 28, 130, 167, 74, 83,
            ],
            tick_lower: 1,
            tick_upper: 2,
            liquidity: 1,
            fee_growth_inside_0: U256::from_words(0, 0),
            fee_growth_inside_1: U256::from_words(0, 0),
        };
        let commitment = compute_position_commitment(&note).expect("commitment");
        let nullifier = generate_position_nullifier_hash(&note).expect("nullifier");
        assert!(commitment != Felt::ZERO);
        assert!(nullifier != Felt::ZERO);
    }
}

fn biguint_from_u8(value: u8) -> num_bigint::BigUint {
    num_bigint::BigUint::from(value)
}

fn biguint_from_u64(value: u64) -> num_bigint::BigUint {
    num_bigint::BigUint::from(value)
}

fn biguint_from_u128(value: u128) -> num_bigint::BigUint {
    num_bigint::BigUint::from(value)
}

fn biguint_from_bytes(bytes: &[u8; 32]) -> num_bigint::BigUint {
    num_bigint::BigUint::from_bytes_be(bytes)
}

fn biguint_from_felt(value: &Felt) -> num_bigint::BigUint {
    num_bigint::BigUint::from_bytes_be(&value.to_bytes_be())
}

fn zero_leaf_hash() -> Result<Felt, ClientError> {
    let value = ZERO_LEAF_HASH.get_or_init(|| {
        Felt::from_hex(generated_constants::ZERO_LEAF_HASH_HEX)
            .expect("ZERO_LEAF_HASH invalid")
    });
    Ok(*value)
}
