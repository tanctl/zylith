// Main Zylith pool interface matching core entrypoints
use starknet::ContractAddress;
use crate::core::ZylithPool::{PoolConfig, PoolState, SwapQuote, SwapStepsQuote};
use crate::clmm::interfaces::core::SwapParameters;
use crate::privacy::ShieldedNotes::MerkleProof;

#[starknet::interface]
pub trait IZylithPool<TContractState> {
    fn initialize(
        ref self: TContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        fee: u128,
        tick_spacing: i32,
        initial_tick: i32,
    );
    fn swap_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    );
    fn swap_private_exact_out(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    );
    fn quote_swap(self: @TContractState, params: SwapParameters) -> SwapQuote;
    fn quote_swap_steps(self: @TContractState, params: SwapParameters) -> SwapStepsQuote;
    fn add_liquidity_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs_token0: Span<MerkleProof>,
        proofs_token1: Span<MerkleProof>,
        proof_position: Span<MerkleProof>,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn remove_liquidity_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn claim_liquidity_fees_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn get_pool_state(self: @TContractState) -> PoolState;
    fn get_pool_config(self: @TContractState) -> PoolConfig;
    fn get_sqrt_price(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);
    fn get_sqrt_ratio_at_tick(self: @TContractState, tick: i32) -> u256;
    fn get_fee_growth_inside(self: @TContractState, tick_lower: i32, tick_upper: i32) -> (u256, u256);
    fn withdraw_protocol_fees(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
    );
    fn get_protocol_fee_totals(self: @TContractState) -> (u128, u128);
}
