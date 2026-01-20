// helper module for swap_private logic
use crate::core::ZylithPool::ZylithPool::{ContractState, PrivateSwap};
use starknet::{get_block_timestamp, ContractAddress};
use starknet::event::EventEmitter;
use core::array::{ArrayTrait, SpanTrait};
use core::traits::TryInto;
use crate::privacy::ShieldedNotes::MerkleProof;
use crate::clmm::math::ticks::{min_tick, max_tick, sqrt_ratio_to_tick};
use crate::clmm::types::i129::i129;
use crate::constants::generated as generated_constants;

// this implementation currently supports up to 16 initialized-tick crossings per swap proof. swaps exceeding this must be chunked or use future recursive proofs.
const MAX_SWAP_STEPS: usize = generated_constants::MAX_SWAP_STEPS;
const MAX_INPUT_NOTES: usize = generated_constants::MAX_INPUT_NOTES;
const VK_SWAP: felt252 = 'SWAP';
const VK_SWAP_EXACT_OUT: felt252 = 'SWAP_EXACT_OUT';

#[starknet::interface]
pub trait IShieldedNotes<TContractState> {
    fn is_nullifier_used(self: @TContractState, nullifier: felt252) -> bool;
    fn verify_membership(
        self: @TContractState, token: ContractAddress, proof: MerkleProof
    ) -> bool;
    fn append_commitment(
        ref self: TContractState,
        commitment: felt252,
        token: ContractAddress,
        proof: MerkleProof,
    ) -> u64;
    fn mark_nullifier_used(ref self: TContractState, nullifier: felt252);
    fn mark_nullifiers_used(ref self: TContractState, nullifiers: Span<felt252>);
    fn flush_pending_roots(ref self: TContractState);
}

#[starknet::interface]
pub trait IPoolAdapterState<TContractState> {
    fn get_sqrt_price(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);
    fn apply_swap_state(ref self: TContractState, public_inputs: Span<u256>);
}

#[starknet::interface]
pub trait IZylithVerifier<TContractState> {
    fn verify_private_swap(self: @TContractState, calldata: Span<felt252>) -> Option<Span<u256>>;
    fn verify_private_swap_exact_out(
        self: @TContractState, calldata: Span<felt252>
    ) -> Option<Span<u256>>;
}

pub fn swap_private_impl(
    ref state: ContractState,
    calldata: Span<felt252>,
    proofs: Span<MerkleProof>,
    output_proofs: Span<MerkleProof>,
) {
    swap_private_with_verifier(ref state, calldata, proofs, output_proofs, false);
}

pub fn swap_private_exact_out_impl(
    ref state: ContractState,
    calldata: Span<felt252>,
    proofs: Span<MerkleProof>,
    output_proofs: Span<MerkleProof>,
) {
    swap_private_with_verifier(ref state, calldata, proofs, output_proofs, true);
}

fn swap_private_with_verifier(
    ref state: ContractState,
    calldata: Span<felt252>,
    proofs: Span<MerkleProof>,
    output_proofs: Span<MerkleProof>,
    exact_out: bool,
) {
    let adapter = IPoolAdapterStateDispatcher { contract_address: state.pool_adapter.read() };
    let notes = IShieldedNotesDispatcher { contract_address: state.shielded_notes.read() };
    let verifier = IZylithVerifierDispatcher { contract_address: state.verifier.read() };
    let config: crate::core::ZylithPool::PoolConfig = state.pool_config.read();

    notes.flush_pending_roots();

    // 1, verify proof and obtain outputs
    let verified = if exact_out {
        verifier.verify_private_swap_exact_out(calldata)
    } else {
        verifier.verify_private_swap(calldata)
    };
    let outputs = verified.expect('PROOF_INVALID');
    let tag: felt252 = assert_high_zero(*outputs.at(0)).try_into().expect('TAG_RANGE');
    if exact_out {
        assert(tag == VK_SWAP_EXACT_OUT, 'TAG_MISMATCH');
    } else {
        assert(tag == VK_SWAP, 'TAG_MISMATCH');
    }

    // 2, nullifier not used
    let merkle_root: felt252 = (*outputs.at(1)).try_into().expect('ROOT_RANGE');
    let nullifier: felt252 = (*outputs.at(2)).try_into().expect('NULLIFIER_RANGE');

    // 3, pool state matches proof start
    let sqrt_price_current = adapter.get_sqrt_price();
    let tick_current = adapter.get_tick();
    let liquidity_current = adapter.get_liquidity();
    let sqrt_price_start: u256 = *outputs.at(3);
    let sqrt_price_end: u256 = *outputs.at(4);
    let liquidity_before_u256: u256 = assert_high_zero(*outputs.at(5));
    let liquidity_before: u128 = liquidity_before_u256.low;
    let fee_u256: u256 = assert_high_zero(*outputs.at(6));
    let fee: u128 = fee_u256.low;
    let fee_growth_global_0_before: u256 = *outputs.at(7);
    let fee_growth_global_1_before: u256 = *outputs.at(8);
    let output_commitment: felt252 = (*outputs.at(9)).try_into().expect('OUTPUT_RANGE');
    let change_commitment: felt252 = (*outputs.at(10)).try_into().expect('CHANGE_RANGE');
    let is_limited_felt: felt252 =
        assert_high_zero(*outputs.at(11)).try_into().expect('LIMIT_RANGE');
    assert((is_limited_felt == 0) | (is_limited_felt == 1), 'LIMIT_BOOL');
    let is_limited = is_limited_felt == 1;
    let zero_for_one_felt: felt252 =
        assert_high_zero(*outputs.at(12)).try_into().expect('ZFO_RANGE');
    assert((zero_for_one_felt == 0) | (zero_for_one_felt == 1), 'ZFO_BOOL');
    let zero_for_one: bool = zero_for_one_felt == 1;
    let mut limited_hit = false;
    let mut step_next_index: usize = 13;
    let mut step_limit_index: usize = 13 + MAX_SWAP_STEPS;
    let mut step_idx: usize = 0;
    while step_idx < MAX_SWAP_STEPS {
        let step_next: u256 = *outputs.at(step_next_index);
        let step_limit_tick: u256 = *outputs.at(step_limit_index);
        let step_limit = if zero_for_one {
            if sqrt_price_end > step_limit_tick { sqrt_price_end } else { step_limit_tick }
        } else {
            if sqrt_price_end < step_limit_tick { sqrt_price_end } else { step_limit_tick }
        };
        if step_next == step_limit {
            limited_hit = true;
        }
        step_next_index += 1;
        step_limit_index += 1;
        step_idx += 1;
    }
    assert(limited_hit == is_limited, 'LIMIT_FLAG_MISMATCH');
    let commitment_in_index: usize = 13 + (MAX_SWAP_STEPS * 6);
    let token_id_index: usize = commitment_in_index + 1;
    let commitment_in: felt252 =
        (*outputs.at(commitment_in_index)).try_into().expect('COMMITMENT_IN_RANGE');
    let token_id_in: felt252 =
        assert_high_zero(*outputs.at(token_id_index)).try_into().expect('TOKEN_ID_RANGE');
    let note_count_index: usize = token_id_index + 1;
    let nullifier_extra_start: usize = note_count_index + 1;
    let commitment_extra_start: usize = nullifier_extra_start + (MAX_INPUT_NOTES - 1);
    let note_count_u256: u256 = assert_high_zero(*outputs.at(note_count_index));
    let note_count_u128: u128 = note_count_u256.low;
    let note_count: usize = note_count_u128.try_into().expect('NOTE_COUNT_RANGE');
    assert(note_count > 0, 'NOTE_COUNT_ZERO');
    assert(note_count <= MAX_INPUT_NOTES, 'NOTE_COUNT_MAX');
    assert(proofs.len() == note_count, 'PROOF_COUNT_MISMATCH');
    assert((token_id_in == 0) | (token_id_in == 1), 'TOKEN_ID_BOOL');

    assert(sqrt_price_current == sqrt_price_start, 'PRICE_MISMATCH');
    assert(liquidity_before == liquidity_current, 'LIQ_BEFORE_MISMATCH');

    let (fee_growth_global_0_current, fee_growth_global_1_current) = adapter.get_fee_growth_global();
    assert(fee_growth_global_0_current == fee_growth_global_0_before, 'FEE0_BEFORE_MISMATCH');
    assert(fee_growth_global_1_current == fee_growth_global_1_before, 'FEE1_BEFORE_MISMATCH');
    assert(config.fee == fee, 'FEE_MISMATCH');

    // 5, invariants on verifier outputs vs config/current (prices/ticks only)
    assert(sqrt_price_end >= config.min_sqrt_ratio, 'PRICE_BELOW_MIN');
    assert(sqrt_price_end <= config.max_sqrt_ratio, 'PRICE_ABOVE_MAX');
    let tick_current_i128: i128 = tick_current.try_into().expect('TICK_RANGE');
    let tick_current_i129: i129 = tick_current_i128.into();
    // tick is pinned to the proof via sqrt_price_start and on-chain tick rounding rules
    if sqrt_price_start == config.min_sqrt_ratio {
        let min_tick_minus_one = min_tick() - i129 { mag: 1, sign: false };
        let expected_tick = sqrt_ratio_to_tick(sqrt_price_start);
        assert(
            (tick_current_i129 == expected_tick) | (tick_current_i129 == min_tick_minus_one),
            'TICK_START_MISMATCH',
        );
    } else if sqrt_price_start == config.max_sqrt_ratio {
        assert(tick_current_i129 == max_tick(), 'TICK_START_MISMATCH');
    } else {
        let expected_tick = sqrt_ratio_to_tick(sqrt_price_start);
        let expected_minus_one = expected_tick - i129 { mag: 1, sign: false };
        // allow a one-tick drift in core rounding
        assert(
            (tick_current_i129 == expected_tick) | (tick_current_i129 == expected_minus_one),
            'TICK_START_MISMATCH',
        );
    }
    let step_fee_growth_0_start = 13 + (MAX_SWAP_STEPS * 4);
    let step_fee_growth_1_start = step_fee_growth_0_start + MAX_SWAP_STEPS;
    let fee_growth_global_0_after: u256 =
        *outputs.at(step_fee_growth_0_start + (MAX_SWAP_STEPS - 1));
    let fee_growth_global_1_after: u256 =
        *outputs.at(step_fee_growth_1_start + (MAX_SWAP_STEPS - 1));
    assert(fee_growth_global_0_after >= fee_growth_global_0_before, 'FEE0_AFTER_LT');
    assert(fee_growth_global_1_after >= fee_growth_global_1_before, 'FEE1_AFTER_LT');

    if sqrt_price_end != sqrt_price_start {
        let observed_direction = sqrt_price_end < sqrt_price_start;
        assert(zero_for_one == observed_direction, 'DIRECTION_MISMATCH');
    }
    let input_token = if zero_for_one { config.token0 } else { config.token1 };
    let expected_token_id: felt252 = if zero_for_one { 0 } else { 1 };
    assert(token_id_in == expected_token_id, 'TOKEN_ID_MISMATCH');
    let mut nullifiers: Array<felt252> = array![];
    let mut note_idx: usize = 0;
    while note_idx < note_count {
        let (note_nullifier, note_commitment) = if note_idx == 0 {
            (nullifier, commitment_in)
        } else {
            let offset = note_idx - 1;
            let extra_nullifier: felt252 =
                (*outputs.at(nullifier_extra_start + offset))
                    .try_into()
                    .expect('NULLIFIER_RANGE');
            let extra_commitment: felt252 =
                (*outputs.at(commitment_extra_start + offset))
                    .try_into()
                    .expect('COMMITMENT_RANGE');
            (extra_nullifier, extra_commitment)
        };
        assert(note_nullifier != 0, 'NULLIFIER_ZERO');
        assert(!notes.is_nullifier_used(note_nullifier), 'NULLIFIER_USED');
        let proof = *proofs.at(note_idx);
        assert(proof.root == merkle_root, 'ROOT_MISMATCH');
        assert(proof.commitment == note_commitment, 'COMMITMENT_MISMATCH');
        assert(notes.verify_membership(input_token, proof), 'INVALID_MEMBERSHIP');
        let mut seen_idx: usize = 0;
        while seen_idx < nullifiers.len() {
            assert(*nullifiers.at(seen_idx) != note_nullifier, 'NULLIFIER_DUP');
            seen_idx += 1;
        }
        nullifiers.append(note_nullifier);
        note_idx += 1;
    }

    // 5a, apply aggregate pool deltas only; per-note amounts are enforced in-circuit
    adapter.apply_swap_state(outputs);

    // 5b, mark nullifier used (bound to verifier output)
    notes.mark_nullifiers_used(nullifiers.span());

    // 5c, insert output commitments (amounts and change invariants are enforced in-circuit)
    let token_out = if zero_for_one { config.token1 } else { config.token0 };
    let has_output = output_commitment != 0;
    let has_change = change_commitment != 0;
    // change_commitment == 0 only when input notes are fully consumed, otherwise its non-zero
    // output_proofs order: output note (token_out) first, then change note (input_token) if present
    let expected_output_proofs: usize =
        (if has_output { 1 } else { 0 }) + (if has_change { 1 } else { 0 });
    assert(output_proofs.len() == expected_output_proofs, 'OUTPUT_PROOF_LEN');
    let mut proof_idx: usize = 0;
    if has_output {
        notes.append_commitment(output_commitment, token_out, *output_proofs.at(proof_idx));
        proof_idx += 1;
    }
    if has_change {
        notes.append_commitment(change_commitment, input_token, *output_proofs.at(proof_idx));
    }

    // 5d, emit event
    let tick_after = adapter.get_tick();
    state.emit(
        PrivateSwap {
            sqrt_price_after: sqrt_price_end,
            tick_after,
            timestamp: get_block_timestamp(),
        },
    );
}

fn assert_high_zero(input: u256) -> u256 {
    assert(input.high == 0, 'UNEXPECTED_U256_HIGH');
    input
}
