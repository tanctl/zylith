//! Zylith client SDK.

mod client;
mod deposit;
mod error;
mod generated_constants;
mod liquidity;
mod notes;
mod proofs;
mod swap;
mod utils;
mod withdraw;

pub use client::{PoolConfig, PoolState, RetryConfig, ZylithClient, ZylithConfig};
pub use deposit::{DepositClient, DepositRequest, DepositResult};
pub use error::ClientError;
pub use generated_constants::MAX_INPUT_NOTES;
pub use liquidity::{LiquidityClaimRequest, LiquidityClient, LiquidityRequest};
pub use notes::{
    compute_commitment, compute_position_commitment, decrypt_note, encrypt_note, generate_note,
    generate_note_with_token_id, generate_nullifier_hash, generate_position_note,
    generate_position_nullifier_hash, EncryptedNote, Note, PositionNote,
};
pub use proofs::{
    quote_liquidity_amounts, LiquidityAddProveRequest, LiquidityClaimProveRequest,
    LiquidityProveResult, LiquidityRemoveProveRequest, SwapProveRequest, SwapProveResult,
};
pub use swap::{
    MerklePath, SignedAmount, SwapClient, SwapQuoteRequest, SwapRequest, SwapResult,
    SwapStepQuote, SwapStepsQuote,
};
pub use utils::{
    felt252_to_u256, parse_event, parse_felt, poseidon_hash, u256_to_felt252, Address,
};
pub use withdraw::{WithdrawClient, WithdrawRequest};
