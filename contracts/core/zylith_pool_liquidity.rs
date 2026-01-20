// helper module for private liquidity add/remove flows
use crate::core::ZylithPool::PoolConfig;
use crate::core::ZylithPool::ZylithPool::{
    ContractState, PrivateLiquidityAdded, PrivateLiquidityRemoved, PrivateLiquidityFeesClaimed,
};
use core::num::traits::Zero;
use starknet::{get_block_timestamp, ContractAddress};
use starknet::event::EventEmitter;
use core::array::{ArrayTrait, SpanTrait};
use core::option::{Option, OptionTrait};
use core::traits::TryInto;
use crate::privacy::ShieldedNotes::MerkleProof;
use crate::clmm::math::ticks::constants::MAX_TICK_MAGNITUDE;
use crate::clmm::math::ticks::tick_to_sqrt_ratio;
use crate::clmm::math::fee::compute_fee;
use crate::clmm::math::liquidity::liquidity_delta_to_amount_delta;
use crate::clmm::types::bounds::Bounds;
use crate::clmm::types::keys::PoolKey;
use crate::clmm::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use crate::privacy::ZylithVerifier::IZylithVerifierDispatcherTrait;
use crate::constants::generated as generated_constants;

const MAX_INPUT_NOTES: usize = generated_constants::MAX_INPUT_NOTES;
const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;
const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;
const VK_LIQ_ADD: felt252 = 'LIQ_ADD';
const VK_LIQ_REMOVE: felt252 = 'LIQ_REMOVE';
const VK_LIQ_CLAIM: felt252 = 'LIQ_CLAIM';

#[starknet::interface]
pub trait IShieldedNotes<TContractState> {
    fn is_nullifier_used(self: @TContractState, nullifier: felt252) -> bool;
    fn verify_membership(
        self: @TContractState, token: ContractAddress, proof: MerkleProof
    ) -> bool;
    fn verify_position_membership(self: @TContractState, proof: MerkleProof) -> bool;
    fn is_known_root(self: @TContractState, token: ContractAddress, root: felt252) -> bool;
    fn is_known_position_root(self: @TContractState, root: felt252) -> bool;
    fn append_commitment(
        ref self: TContractState,
        commitment: felt252,
        token: ContractAddress,
        proof: MerkleProof,
    ) -> u64;
    fn append_position_commitment(
        ref self: TContractState, commitment: felt252, proof: MerkleProof
    ) -> u64;
    fn mark_nullifier_used(ref self: TContractState, nullifier: felt252);
    fn mark_nullifiers_used(ref self: TContractState, nullifiers: Span<felt252>);
    fn accrue_protocol_fees(
        ref self: TContractState, token: ContractAddress, amount: u128
    );
    fn flush_pending_roots(ref self: TContractState);
}

#[starknet::interface]
pub trait IPoolAdapterLiquidity<TContractState> {
    fn get_sqrt_price(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);
    fn apply_liquidity_state(
        ref self: TContractState,
        tick_lower: i32,
        tick_upper: i32,
        liquidity_delta: u256,
        fee_growth_global_0: u256,
        fee_growth_global_1: u256,
        fee: u128,
        tick_spacing: u128,
        protocol_fee_0: u128,
        protocol_fee_1: u128,
        token0: ContractAddress,
        token1: ContractAddress,
    );
    fn get_liquidity(self: @TContractState) -> u128;
}

pub fn liquidity_add_impl(
    ref state: ContractState,
    calldata: Span<felt252>,
    proofs_token0: Span<MerkleProof>,
    proofs_token1: Span<MerkleProof>,
    proof_position: Span<MerkleProof>,
    insert_proof_position: Span<MerkleProof>,
    output_proof_token0: Span<MerkleProof>,
    output_proof_token1: Span<MerkleProof>,
) {
    // proofs derive state transitions, roots and nullifier freshness remain on-chain
    let notes = IShieldedNotesDispatcher { contract_address: state.shielded_notes.read() };
    let verifier = crate::privacy::ZylithVerifier::IZylithVerifierDispatcher {
        contract_address: state.verifier.read(),
    };
    let adapter = IPoolAdapterLiquidityDispatcher { contract_address: state.pool_adapter.read() };
    let config: PoolConfig = state.pool_config.read();
    let tick_spacing: u128 = config.tick_spacing;
    let core = ICoreDispatcher { contract_address: state.core_address.read() };

    notes.flush_pending_roots();

    // 1, verify proof (must succeed)
    let verified = verifier.verify_private_liquidity_add(calldata);
    let outputs = verified.expect('PROOF_INVALID');
    let tag: felt252 = assert_high_zero(*outputs.at(0)).try_into().expect('TAG_RANGE');
    assert(tag == VK_LIQ_ADD, 'TAG_MISMATCH');

    // 2, decode outputs
    let merkle_root_token0: felt252 = (*outputs.at(1)).try_into().expect('ROOT0_RANGE');
    let merkle_root_token1: felt252 = (*outputs.at(2)).try_into().expect('ROOT1_RANGE');
    let merkle_root_position: felt252 = (*outputs.at(3)).try_into().expect('ROOT_POSITION_RANGE');
    let nullifier_position: felt252 = (*outputs.at(4)).try_into().expect('NULLIFIER_RANGE');
    let sqrt_price_start: u256 = *outputs.at(5);
    let tick_start: i32 = decode_i32_signed(*outputs.at(6)).expect('TICK_START_RANGE');
    let tick_lower: i32 = decode_i32_signed(*outputs.at(7)).expect('TICK_LOWER_RANGE');
    let tick_upper: i32 = decode_i32_signed(*outputs.at(8)).expect('TICK_UPPER_RANGE');
    // tick ranges are public because aggregate tick liquidity must be updated on-chain
    let sqrt_ratio_lower: u256 = *outputs.at(9);
    let sqrt_ratio_upper: u256 = *outputs.at(10);
    let liquidity_before_u256: u256 = assert_high_zero(*outputs.at(11));
    let liquidity_before: u128 = liquidity_before_u256.low;
    let liquidity_delta: u256 = *outputs.at(12);
    let fee_u256: u256 = assert_high_zero(*outputs.at(13));
    let fee: u128 = fee_u256.low;
    let fee_growth_global_0_before: u256 = *outputs.at(14);
    let fee_growth_global_1_before: u256 = *outputs.at(15);
    let fee_growth_global_0: u256 = *outputs.at(16);
    let fee_growth_global_1: u256 = *outputs.at(17);
    let prev_position_commitment: felt252 =
        (*outputs.at(18)).try_into().expect('POS_PREV_RANGE');
    let new_position_commitment: felt252 =
        (*outputs.at(19)).try_into().expect('POS_NEW_RANGE');
    let liquidity_commitment: felt252 =
        (*outputs.at(20)).try_into().expect('LIQ_COMMITMENT_RANGE');
    let fee_growth_inside_0_before: u256 = *outputs.at(21);
    let fee_growth_inside_1_before: u256 = *outputs.at(22);
    let fee_growth_inside_0_after: u256 = *outputs.at(23);
    let fee_growth_inside_1_after: u256 = *outputs.at(24);
    let input_commitment_token0: felt252 = (*outputs.at(25)).try_into().expect('IN0_RANGE');
    let input_commitment_token1: felt252 = (*outputs.at(26)).try_into().expect('IN1_RANGE');
    let nullifier_token0: felt252 = (*outputs.at(27)).try_into().expect('NULL0_RANGE');
    let nullifier_token1: felt252 = (*outputs.at(28)).try_into().expect('NULL1_RANGE');
    let output_commitment_token0: felt252 = (*outputs.at(29)).try_into().expect('OUT0_RANGE');
    let output_commitment_token1: felt252 = (*outputs.at(30)).try_into().expect('OUT1_RANGE');
    let protocol_fee_0_u256: u256 = assert_high_zero(*outputs.at(31));
    let protocol_fee_1_u256: u256 = assert_high_zero(*outputs.at(32));

    let note_count0_u256: u256 = assert_high_zero(*outputs.at(33));
    let note_count1_u256: u256 = assert_high_zero(*outputs.at(34));
    let note_count0: usize = note_count0_u256.low.try_into().expect('NOTE_COUNT0_RANGE');
    let note_count1: usize = note_count1_u256.low.try_into().expect('NOTE_COUNT1_RANGE');
    let protocol_fee_0: u128 = protocol_fee_0_u256.low;
    let protocol_fee_1: u128 = protocol_fee_1_u256.low;

    let nullifier_token0_extra_start: usize = 35;
    let nullifier_token1_extra_start: usize = nullifier_token0_extra_start + (MAX_INPUT_NOTES - 1);
    let commitment_token0_extra_start: usize =
        nullifier_token1_extra_start + (MAX_INPUT_NOTES - 1);
    let commitment_token1_extra_start: usize =
        commitment_token0_extra_start + (MAX_INPUT_NOTES - 1);

    assert(config.fee == fee, 'FEE_MISMATCH');
    assert(notes.is_known_root(config.token0, merkle_root_token0), 'ROOT0_UNKNOWN');
    assert(notes.is_known_root(config.token1, merkle_root_token1), 'ROOT1_UNKNOWN');
    assert(notes.is_known_position_root(merkle_root_position), 'POSITION_ROOT_UNKNOWN');

    let has_prev_position = prev_position_commitment != 0;
    if has_prev_position {
        assert(nullifier_position != 0, 'POSITION_NULLIFIER_ZERO');
        assert(!notes.is_nullifier_used(nullifier_position), 'POSITION_NULLIFIER_USED');
        assert(proof_position.len() == 1, 'POSITION_PROOF_LEN');
        let pos_proof = *proof_position.at(0);
        assert(pos_proof.root == merkle_root_position, 'POSITION_ROOT_MISMATCH');
        assert(pos_proof.commitment == prev_position_commitment, 'POSITION_COMMITMENT_MISMATCH');
        assert(notes.verify_position_membership(pos_proof), 'INVALID_POSITION_MEMBERSHIP');
        // position ownership is private, tick bounds are public inputs bound by the proof
    } else {
        assert(nullifier_position == 0, 'POSITION_NULLIFIER_NONZERO');
        assert(proof_position.len() == 0, 'POSITION_PROOF_LEN');
    }

    assert(liquidity_commitment == new_position_commitment, 'LIQ_COMMITMENT_MISMATCH');
    assert(new_position_commitment != 0, 'POSITION_NEW_ZERO');

    // pool pre-state must match proof
    let sqrt_price_current = adapter.get_sqrt_price();
    let tick_current = adapter.get_tick();
    assert(sqrt_price_current == sqrt_price_start, 'PRICE_MISMATCH');
    assert(tick_current == tick_start, 'TICK_START_MISMATCH');
    assert(adapter.get_liquidity() == liquidity_before, 'LIQ_BEFORE_MISMATCH');

    // invariant checks
    let tick_lower_i128: i128 = tick_lower.into();
    let tick_upper_i128: i128 = tick_upper.into();
    let tick_lower_mag: u128 = if tick_lower_i128 < 0 {
        (-tick_lower_i128).try_into().expect('TICK_RANGE')
    } else {
        tick_lower_i128.try_into().expect('TICK_RANGE')
    };
    let tick_upper_mag: u128 = if tick_upper_i128 < 0 {
        (-tick_upper_i128).try_into().expect('TICK_RANGE')
    } else {
        tick_upper_i128.try_into().expect('TICK_RANGE')
    };
    assert(tick_aligned(tick_lower, tick_spacing), 'TICK_LOWER_ALIGNMENT');
    assert(tick_aligned(tick_upper, tick_spacing), 'TICK_UPPER_ALIGNMENT');
    assert(tick_lower < tick_upper, 'INVALID_TICKS');
    assert(tick_lower_mag <= MAX_TICK_MAGNITUDE, 'TICK_LOWER_RANGE');
    assert(tick_upper_mag <= MAX_TICK_MAGNITUDE, 'TICK_UPPER_RANGE');
    let sqrt_ratio_lower_expected = tick_to_sqrt_ratio(tick_lower_i128.into());
    let sqrt_ratio_upper_expected = tick_to_sqrt_ratio(tick_upper_i128.into());
    assert(sqrt_ratio_lower == sqrt_ratio_lower_expected, 'SQRT_LOWER_MISMATCH');
    assert(sqrt_ratio_upper == sqrt_ratio_upper_expected, 'SQRT_UPPER_MISMATCH');
    let (liq_sign, liq_mag) = signed_u256_to_sign_mag(liquidity_delta);
    assert(!liq_sign, 'LIQ_DELTA_SIGN');
    assert(liq_mag.is_non_zero(), 'LIQ_DELTA_ZERO');

    let (fee_growth_global_0_current, fee_growth_global_1_current) = adapter.get_fee_growth_global();
    assert(fee_growth_global_0_current == fee_growth_global_0_before, 'FEE0_BEFORE_MISMATCH');
    assert(fee_growth_global_1_current == fee_growth_global_1_before, 'FEE1_BEFORE_MISMATCH');
    assert(fee_growth_global_0 == fee_growth_global_0_before, 'FEE0_CHANGED');
    assert(fee_growth_global_1 == fee_growth_global_1_before, 'FEE1_CHANGED');

    let fees_inside_current = core.get_pool_fees_per_liquidity_inside(
        pool_key_from_config(config),
        bounds_from_ticks(tick_lower, tick_upper),
    );
    let fee_inside_0_current: u256 = fees_inside_current.value0;
    let fee_inside_1_current: u256 = fees_inside_current.value1;
    assert(fee_growth_inside_0_after == fee_inside_0_current, 'FEE_INSIDE0_CURRENT');
    assert(fee_growth_inside_1_after == fee_inside_1_current, 'FEE_INSIDE1_CURRENT');
    if !has_prev_position {
        assert(
            fee_growth_inside_0_before == fee_growth_inside_0_after,
            'FEE_INSIDE0_BEFORE_MISMATCH',
        );
        assert(
            fee_growth_inside_1_before == fee_growth_inside_1_after,
            'FEE_INSIDE1_BEFORE_MISMATCH',
        );
    }

    assert(note_count0 <= MAX_INPUT_NOTES, 'NOTE_COUNT0_MAX');
    assert(note_count1 <= MAX_INPUT_NOTES, 'NOTE_COUNT1_MAX');
    assert((note_count0 != 0) | (note_count1 != 0), 'NOTE_COUNT_ZERO');
    assert(proofs_token0.len() == note_count0, 'PROOF0_LEN');
    assert(proofs_token1.len() == note_count1, 'PROOF1_LEN');
    assert(protocol_fee_0 == 0, 'PROTOCOL_FEE0_NONZERO');
    assert(protocol_fee_1 == 0, 'PROTOCOL_FEE1_NONZERO');

    let mut nullifiers: Array<felt252> = array![];
    if has_prev_position {
        nullifiers.append(nullifier_position);
    }

    if note_count0 == 0 {
        assert(input_commitment_token0 == 0, 'TOKEN0_INPUT_NONZERO');
        assert(nullifier_token0 == 0, 'TOKEN0_NULLIFIER_NONZERO');
    } else {
        assert(input_commitment_token0 != 0, 'TOKEN0_INPUT_ZERO');
        assert(nullifier_token0 != 0, 'TOKEN0_NULLIFIER_ZERO');
    }
    if note_count1 == 0 {
        assert(input_commitment_token1 == 0, 'TOKEN1_INPUT_NONZERO');
        assert(nullifier_token1 == 0, 'TOKEN1_NULLIFIER_NONZERO');
    } else {
        assert(input_commitment_token1 != 0, 'TOKEN1_INPUT_ZERO');
        assert(nullifier_token1 != 0, 'TOKEN1_NULLIFIER_ZERO');
    }

    let mut idx0: usize = 0;
    while idx0 < note_count0 {
        let (commitment, nullifier) = if idx0 == 0 {
            (input_commitment_token0, nullifier_token0)
        } else {
            let offset = idx0 - 1;
            let extra_nullifier: felt252 =
                (*outputs.at(nullifier_token0_extra_start + offset))
                    .try_into()
                    .expect('NULL0_RANGE');
            let extra_commitment: felt252 =
                (*outputs.at(commitment_token0_extra_start + offset))
                    .try_into()
                    .expect('IN0_RANGE');
            (extra_commitment, extra_nullifier)
        };
        let proof = *proofs_token0.at(idx0);
        assert(proof.root == merkle_root_token0, 'ROOT0_MISMATCH');
        assert(proof.commitment == commitment, 'COMMITMENT0_MISMATCH');
        assert(notes.verify_membership(config.token0, proof), 'INVALID_MEMBERSHIP0');
        assert(nullifier != 0, 'NULLIFIER0_ZERO');
        assert(!notes.is_nullifier_used(nullifier), 'NULLIFIER0_USED');
        let mut seen_idx: usize = 0;
        while seen_idx < nullifiers.len() {
            assert(*nullifiers.at(seen_idx) != nullifier, 'NULLIFIER_DUP');
            seen_idx += 1;
        }
        nullifiers.append(nullifier);
        idx0 += 1;
    }

    let mut idx1: usize = 0;
    while idx1 < note_count1 {
        let (commitment, nullifier) = if idx1 == 0 {
            (input_commitment_token1, nullifier_token1)
        } else {
            let offset = idx1 - 1;
            let extra_nullifier: felt252 =
                (*outputs.at(nullifier_token1_extra_start + offset))
                    .try_into()
                    .expect('NULL1_RANGE');
            let extra_commitment: felt252 =
                (*outputs.at(commitment_token1_extra_start + offset))
                    .try_into()
                    .expect('IN1_RANGE');
            (extra_commitment, extra_nullifier)
        };
        let proof = *proofs_token1.at(idx1);
        assert(proof.root == merkle_root_token1, 'ROOT1_MISMATCH');
        assert(proof.commitment == commitment, 'COMMITMENT1_MISMATCH');
        assert(notes.verify_membership(config.token1, proof), 'INVALID_MEMBERSHIP1');
        assert(nullifier != 0, 'NULLIFIER1_ZERO');
        assert(!notes.is_nullifier_used(nullifier), 'NULLIFIER1_USED');
        let mut seen_idx: usize = 0;
        while seen_idx < nullifiers.len() {
            assert(*nullifiers.at(seen_idx) != nullifier, 'NULLIFIER_DUP');
            seen_idx += 1;
        }
        nullifiers.append(nullifier);
        idx1 += 1;
    }

    notes.mark_nullifiers_used(nullifiers.span());

    // apply aggregate liquidity/fee deltas only, per-position amounts stay private
    adapter.apply_liquidity_state(
        tick_lower,
        tick_upper,
        liquidity_delta,
        fee_growth_global_0,
        fee_growth_global_1,
        fee,
        tick_spacing,
        0,
        0,
        config.token0,
        config.token1,
    );

    if new_position_commitment != 0 {
        assert(insert_proof_position.len() == 1, 'POSITION_INSERT_PROOF_LEN');
        notes.append_position_commitment(new_position_commitment, *insert_proof_position.at(0));
    } else {
        assert(insert_proof_position.len() == 0, 'POSITION_INSERT_PROOF_LEN');
    }
    if output_commitment_token0 != 0 {
        assert(output_proof_token0.len() == 1, 'OUT0_PROOF_LEN');
        notes.append_commitment(output_commitment_token0, config.token0, *output_proof_token0.at(0));
    } else {
        assert(output_proof_token0.len() == 0, 'OUT0_PROOF_LEN');
    }
    if output_commitment_token1 != 0 {
        assert(output_proof_token1.len() == 1, 'OUT1_PROOF_LEN');
        notes.append_commitment(output_commitment_token1, config.token1, *output_proof_token1.at(0));
    } else {
        assert(output_proof_token1.len() == 0, 'OUT1_PROOF_LEN');
    }

    // emit event
    state
        .emit(
            PrivateLiquidityAdded {
                timestamp: get_block_timestamp(),
            },
        );
}

pub fn liquidity_remove_impl(
    ref state: ContractState,
    calldata: Span<felt252>,
    proof_position: MerkleProof,
    insert_proof_position: Span<MerkleProof>,
    output_proof_token0: Span<MerkleProof>,
    output_proof_token1: Span<MerkleProof>,
) {
    let notes = IShieldedNotesDispatcher { contract_address: state.shielded_notes.read() };
    let verifier = crate::privacy::ZylithVerifier::IZylithVerifierDispatcher {
        contract_address: state.verifier.read(),
    };
    let adapter = IPoolAdapterLiquidityDispatcher { contract_address: state.pool_adapter.read() };
    let config: PoolConfig = state.pool_config.read();
    let tick_spacing: u128 = config.tick_spacing;
    let core = ICoreDispatcher { contract_address: state.core_address.read() };

    notes.flush_pending_roots();

    // 1, verify proof (must succeed) and load position
    let verified = verifier.verify_private_liquidity_remove(calldata);
    let outputs = verified.expect('PROOF_INVALID');
    let tag: felt252 = assert_high_zero(*outputs.at(0)).try_into().expect('TAG_RANGE');
    assert(tag == VK_LIQ_REMOVE, 'TAG_MISMATCH');

    let merkle_root_token0: felt252 = (*outputs.at(1)).try_into().expect('ROOT0_RANGE');
    let merkle_root_token1: felt252 = (*outputs.at(2)).try_into().expect('ROOT1_RANGE');
    let merkle_root_position: felt252 = (*outputs.at(3)).try_into().expect('ROOT_POSITION_RANGE');
    let nullifier_position: felt252 = (*outputs.at(4)).try_into().expect('NULLIFIER_RANGE');
    let sqrt_price_start: u256 = *outputs.at(5);
    let tick_start: i32 = decode_i32_signed(*outputs.at(6)).expect('TICK_START_RANGE');
    let tick_lower: i32 = decode_i32_signed(*outputs.at(7)).expect('TICK_LOWER_RANGE');
    let tick_upper: i32 = decode_i32_signed(*outputs.at(8)).expect('TICK_UPPER_RANGE');
    // tick ranges are public because aggregate tick liquidity must be updated on-chain.
    let sqrt_ratio_lower: u256 = *outputs.at(9);
    let sqrt_ratio_upper: u256 = *outputs.at(10);
    let liquidity_before_u256: u256 = assert_high_zero(*outputs.at(11));
    let liquidity_before: u128 = liquidity_before_u256.low;
    let liquidity_delta: u256 = *outputs.at(12);
    let fee_u256: u256 = assert_high_zero(*outputs.at(13));
    let fee: u128 = fee_u256.low;
    let fee_growth_global_0_before: u256 = *outputs.at(14);
    let fee_growth_global_1_before: u256 = *outputs.at(15);
    let fee_growth_global_0: u256 = *outputs.at(16);
    let fee_growth_global_1: u256 = *outputs.at(17);
    let prev_position_commitment: felt252 =
        (*outputs.at(18)).try_into().expect('POS_PREV_RANGE');
    let new_position_commitment: felt252 =
        (*outputs.at(19)).try_into().expect('POS_NEW_RANGE');
    let liquidity_commitment: felt252 =
        (*outputs.at(20)).try_into().expect('LIQ_COMMITMENT_RANGE');
    let _fee_growth_inside_0_before: u256 = *outputs.at(21);
    let _fee_growth_inside_1_before: u256 = *outputs.at(22);
    let fee_growth_inside_0_after: u256 = *outputs.at(23);
    let fee_growth_inside_1_after: u256 = *outputs.at(24);
    let input_commitment_token0: felt252 = (*outputs.at(25)).try_into().expect('IN0_RANGE');
    let input_commitment_token1: felt252 = (*outputs.at(26)).try_into().expect('IN1_RANGE');
    let nullifier_token0: felt252 = (*outputs.at(27)).try_into().expect('NULL0_RANGE');
    let nullifier_token1: felt252 = (*outputs.at(28)).try_into().expect('NULL1_RANGE');
    let output_commitment_token0: felt252 = (*outputs.at(29)).try_into().expect('OUT0_RANGE');
    let output_commitment_token1: felt252 = (*outputs.at(30)).try_into().expect('OUT1_RANGE');
    let protocol_fee_0_u256: u256 = assert_high_zero(*outputs.at(31));
    let protocol_fee_1_u256: u256 = assert_high_zero(*outputs.at(32));
    let note_count0_u256: u256 = assert_high_zero(*outputs.at(33));
    let note_count1_u256: u256 = assert_high_zero(*outputs.at(34));
    let note_count0: usize = note_count0_u256.low.try_into().expect('NOTE_COUNT0_RANGE');
    let note_count1: usize = note_count1_u256.low.try_into().expect('NOTE_COUNT1_RANGE');
    let protocol_fee_0_from_proof: u128 = protocol_fee_0_u256.low;
    let protocol_fee_1_from_proof: u128 = protocol_fee_1_u256.low;

    assert(config.fee == fee, 'FEE_MISMATCH');
    assert(note_count0 == 0, 'NOTE_COUNT0_NONZERO');
    assert(note_count1 == 0, 'NOTE_COUNT1_NONZERO');
    assert(input_commitment_token0 == 0, 'TOKEN0_INPUT_NONZERO');
    assert(input_commitment_token1 == 0, 'TOKEN1_INPUT_NONZERO');
    assert(nullifier_token0 == 0, 'TOKEN0_NULLIFIER_NONZERO');
    assert(nullifier_token1 == 0, 'TOKEN1_NULLIFIER_NONZERO');
    assert(nullifier_position != 0, 'NULLIFIER_ZERO');
    assert(!notes.is_nullifier_used(nullifier_position), 'NULLIFIER_USED');
    assert(notes.is_known_root(config.token0, merkle_root_token0), 'ROOT0_UNKNOWN');
    assert(notes.is_known_root(config.token1, merkle_root_token1), 'ROOT1_UNKNOWN');
    assert(notes.is_known_position_root(merkle_root_position), 'POSITION_ROOT_UNKNOWN');

    // membership path must match verifier output root
    assert(proof_position.root == merkle_root_position, 'ROOT_MISMATCH');
    assert(proof_position.commitment == prev_position_commitment, 'COMMITMENT_MISMATCH');
    assert(notes.verify_position_membership(proof_position), 'INVALID_MEMBERSHIP');
    // position snapshots remain private, proof enforces fee claims against public growth
    assert(liquidity_commitment == prev_position_commitment, 'LIQ_COMMITMENT_MISMATCH');

    // pool pre-state must match proof
    let sqrt_price_current = adapter.get_sqrt_price();
    let tick_current = adapter.get_tick();
    assert(sqrt_price_current == sqrt_price_start, 'PRICE_MISMATCH');
    assert(tick_current == tick_start, 'TICK_START_MISMATCH');
    assert(adapter.get_liquidity() == liquidity_before, 'LIQ_BEFORE_MISMATCH');

    // invariant checks
    let tick_lower_mag: u128 = if tick_lower < 0 {
        (-tick_lower).try_into().expect('TICK_RANGE')
    } else {
        tick_lower.try_into().expect('TICK_RANGE')
    };
    let tick_upper_mag: u128 = if tick_upper < 0 {
        (-tick_upper).try_into().expect('TICK_RANGE')
    } else {
        tick_upper.try_into().expect('TICK_RANGE')
    };
    assert(tick_aligned(tick_lower, tick_spacing), 'TICK_LOWER_ALIGNMENT');
    assert(tick_aligned(tick_upper, tick_spacing), 'TICK_UPPER_ALIGNMENT');
    assert(tick_lower < tick_upper, 'INVALID_TICKS');
    assert(tick_lower_mag <= MAX_TICK_MAGNITUDE, 'TICK_LOWER_RANGE');
    assert(tick_upper_mag <= MAX_TICK_MAGNITUDE, 'TICK_UPPER_RANGE');
    let (liq_sign, liq_mag) = signed_u256_to_sign_mag(liquidity_delta);
    assert(liq_sign, 'LIQ_DELTA_NOT_NEG');
    assert(liq_mag.is_non_zero(), 'LIQ_DELTA_ZERO');
    let current_liq = adapter.get_liquidity();
    if (tick_current >= tick_lower) & (tick_current < tick_upper) {
        assert(current_liq >= liq_mag, 'LIQ_UNDERFLOW');
    }

    let (fee_growth_global_0_current, fee_growth_global_1_current) = adapter.get_fee_growth_global();
    assert(fee_growth_global_0_current == fee_growth_global_0_before, 'FEE0_BEFORE_MISMATCH');
    assert(fee_growth_global_1_current == fee_growth_global_1_before, 'FEE1_BEFORE_MISMATCH');
    assert(fee_growth_global_0 == fee_growth_global_0_before, 'FEE0_CHANGED');
    assert(fee_growth_global_1 == fee_growth_global_1_before, 'FEE1_CHANGED');

    let fees_inside_current = core.get_pool_fees_per_liquidity_inside(
        pool_key_from_config(config),
        bounds_from_ticks(tick_lower, tick_upper),
    );
    let fee_inside_0_current: u256 = fees_inside_current.value0;
    let fee_inside_1_current: u256 = fees_inside_current.value1;
    assert(fee_growth_inside_0_after == fee_inside_0_current, 'FEE_INSIDE0_CURRENT');
    assert(fee_growth_inside_1_after == fee_inside_1_current, 'FEE_INSIDE1_CURRENT');

    let tick_lower_i128: i128 = tick_lower.try_into().expect('TICK_RANGE');
    let tick_upper_i128: i128 = tick_upper.try_into().expect('TICK_RANGE');
    let sqrt_ratio_lower_expected = tick_to_sqrt_ratio(tick_lower_i128.into());
    let sqrt_ratio_upper_expected = tick_to_sqrt_ratio(tick_upper_i128.into());
    assert(sqrt_ratio_lower == sqrt_ratio_lower_expected, 'SQRT_LOWER_MISMATCH');
    assert(sqrt_ratio_upper == sqrt_ratio_upper_expected, 'SQRT_UPPER_MISMATCH');
    let delta = liquidity_delta_to_amount_delta(
        sqrt_price_current,
        liquidity_delta,
        sqrt_ratio_lower_expected,
        sqrt_ratio_upper_expected,
    );
    let protocol_fee_0: u128 = compute_fee(delta.amount0.mag, fee);
    let protocol_fee_1: u128 = compute_fee(delta.amount1.mag, fee);
    assert(protocol_fee_0 == protocol_fee_0_from_proof, 'PROTOCOL_FEE0_MISMATCH');
    assert(protocol_fee_1 == protocol_fee_1_from_proof, 'PROTOCOL_FEE1_MISMATCH');

    // token custody stays in ShieldedNotes, accrue protocol fees without moving tokens
    if protocol_fee_0 != 0 {
        notes.accrue_protocol_fees(config.token0, protocol_fee_0);
    }
    if protocol_fee_1 != 0 {
        notes.accrue_protocol_fees(config.token1, protocol_fee_1);
    }

    let mut nullifiers: Array<felt252> = array![];
    nullifiers.append(nullifier_position);
    notes.mark_nullifiers_used(nullifiers.span());

    // apply aggregate liquidity/fee deltas only, per-position amounts stay private
    adapter.apply_liquidity_state(
        tick_lower,
        tick_upper,
        liquidity_delta,
        fee_growth_global_0,
        fee_growth_global_1,
        fee,
        tick_spacing,
        protocol_fee_0,
        protocol_fee_1,
        config.token0,
        config.token1,
    );

    if new_position_commitment != 0 {
        assert(insert_proof_position.len() == 1, 'POSITION_INSERT_PROOF_LEN');
        notes.append_position_commitment(new_position_commitment, *insert_proof_position.at(0));
    } else {
        assert(insert_proof_position.len() == 0, 'POSITION_INSERT_PROOF_LEN');
    }
    if output_commitment_token0 != 0 {
        assert(output_proof_token0.len() == 1, 'OUT0_PROOF_LEN');
        notes.append_commitment(output_commitment_token0, config.token0, *output_proof_token0.at(0));
    } else {
        assert(output_proof_token0.len() == 0, 'OUT0_PROOF_LEN');
    }
    if output_commitment_token1 != 0 {
        assert(output_proof_token1.len() == 1, 'OUT1_PROOF_LEN');
        notes.append_commitment(output_commitment_token1, config.token1, *output_proof_token1.at(0));
    } else {
        assert(output_proof_token1.len() == 0, 'OUT1_PROOF_LEN');
    }

    // emit event
    state
        .emit(
            PrivateLiquidityRemoved {
                timestamp: get_block_timestamp(),
            },
        );
}

pub fn liquidity_claim_impl(
    ref state: ContractState,
    calldata: Span<felt252>,
    proof_position: MerkleProof,
    insert_proof_position: Span<MerkleProof>,
    output_proof_token0: Span<MerkleProof>,
    output_proof_token1: Span<MerkleProof>,
) {
    let notes = IShieldedNotesDispatcher { contract_address: state.shielded_notes.read() };
    let verifier = crate::privacy::ZylithVerifier::IZylithVerifierDispatcher {
        contract_address: state.verifier.read(),
    };
    let adapter = IPoolAdapterLiquidityDispatcher { contract_address: state.pool_adapter.read() };
    let config: PoolConfig = state.pool_config.read();
    let tick_spacing: u128 = config.tick_spacing;
    let core = ICoreDispatcher { contract_address: state.core_address.read() };

    notes.flush_pending_roots();

    // 1, verify proof (must succeed) and load position
    let verified = verifier.verify_private_liquidity_claim(calldata);
    let outputs = verified.expect('PROOF_INVALID');
    let tag: felt252 = assert_high_zero(*outputs.at(0)).try_into().expect('TAG_RANGE');
    assert(tag == VK_LIQ_CLAIM, 'TAG_MISMATCH');

    let merkle_root_token0: felt252 = (*outputs.at(1)).try_into().expect('ROOT0_RANGE');
    let merkle_root_token1: felt252 = (*outputs.at(2)).try_into().expect('ROOT1_RANGE');
    let merkle_root_position: felt252 = (*outputs.at(3)).try_into().expect('ROOT_POSITION_RANGE');
    let nullifier_position: felt252 = (*outputs.at(4)).try_into().expect('NULLIFIER_RANGE');
    let sqrt_price_start: u256 = *outputs.at(5);
    let tick_start: i32 = decode_i32_signed(*outputs.at(6)).expect('TICK_START_RANGE');
    let tick_lower: i32 = decode_i32_signed(*outputs.at(7)).expect('TICK_LOWER_RANGE');
    let tick_upper: i32 = decode_i32_signed(*outputs.at(8)).expect('TICK_UPPER_RANGE');
    // Tick ranges are public because aggregate tick liquidity must be updated on-chain.
    let sqrt_ratio_lower: u256 = *outputs.at(9);
    let sqrt_ratio_upper: u256 = *outputs.at(10);
    let liquidity_before_u256: u256 = assert_high_zero(*outputs.at(11));
    let liquidity_before: u128 = liquidity_before_u256.low;
    let liquidity_delta: u256 = *outputs.at(12);
    let fee_u256: u256 = assert_high_zero(*outputs.at(13));
    let fee: u128 = fee_u256.low;
    let fee_growth_global_0_before: u256 = *outputs.at(14);
    let fee_growth_global_1_before: u256 = *outputs.at(15);
    let fee_growth_global_0: u256 = *outputs.at(16);
    let fee_growth_global_1: u256 = *outputs.at(17);
    let prev_position_commitment: felt252 =
        (*outputs.at(18)).try_into().expect('POS_PREV_RANGE');
    let new_position_commitment: felt252 =
        (*outputs.at(19)).try_into().expect('POS_NEW_RANGE');
    let liquidity_commitment: felt252 =
        (*outputs.at(20)).try_into().expect('LIQ_COMMITMENT_RANGE');
    let _fee_growth_inside_0_before: u256 = *outputs.at(21);
    let _fee_growth_inside_1_before: u256 = *outputs.at(22);
    let fee_growth_inside_0_after: u256 = *outputs.at(23);
    let fee_growth_inside_1_after: u256 = *outputs.at(24);
    let input_commitment_token0: felt252 = (*outputs.at(25)).try_into().expect('IN0_RANGE');
    let input_commitment_token1: felt252 = (*outputs.at(26)).try_into().expect('IN1_RANGE');
    let nullifier_token0: felt252 = (*outputs.at(27)).try_into().expect('NULL0_RANGE');
    let nullifier_token1: felt252 = (*outputs.at(28)).try_into().expect('NULL1_RANGE');
    let output_commitment_token0: felt252 = (*outputs.at(29)).try_into().expect('OUT0_RANGE');
    let output_commitment_token1: felt252 = (*outputs.at(30)).try_into().expect('OUT1_RANGE');
    let protocol_fee_0_u256: u256 = assert_high_zero(*outputs.at(31));
    let protocol_fee_1_u256: u256 = assert_high_zero(*outputs.at(32));
    let note_count0_u256: u256 = assert_high_zero(*outputs.at(33));
    let note_count1_u256: u256 = assert_high_zero(*outputs.at(34));
    let note_count0: usize = note_count0_u256.low.try_into().expect('NOTE_COUNT0_RANGE');
    let note_count1: usize = note_count1_u256.low.try_into().expect('NOTE_COUNT1_RANGE');
    let protocol_fee_0: u128 = protocol_fee_0_u256.low;
    let protocol_fee_1: u128 = protocol_fee_1_u256.low;
    assert(protocol_fee_0 == 0, 'PROTOCOL_FEE0_NONZERO');
    assert(protocol_fee_1 == 0, 'PROTOCOL_FEE1_NONZERO');

    assert(config.fee == fee, 'FEE_MISMATCH');
    assert(note_count0 == 0, 'NOTE_COUNT0_NONZERO');
    assert(note_count1 == 0, 'NOTE_COUNT1_NONZERO');
    assert(input_commitment_token0 == 0, 'TOKEN0_INPUT_NONZERO');
    assert(input_commitment_token1 == 0, 'TOKEN1_INPUT_NONZERO');
    assert(nullifier_token0 == 0, 'TOKEN0_NULLIFIER_NONZERO');
    assert(nullifier_token1 == 0, 'TOKEN1_NULLIFIER_NONZERO');
    assert(nullifier_position != 0, 'NULLIFIER_ZERO');
    assert(!notes.is_nullifier_used(nullifier_position), 'NULLIFIER_USED');
    assert(notes.is_known_root(config.token0, merkle_root_token0), 'ROOT0_UNKNOWN');
    assert(notes.is_known_root(config.token1, merkle_root_token1), 'ROOT1_UNKNOWN');
    assert(notes.is_known_position_root(merkle_root_position), 'POSITION_ROOT_UNKNOWN');

    // membership path must match verifier output root
    assert(proof_position.root == merkle_root_position, 'ROOT_MISMATCH');
    assert(proof_position.commitment == prev_position_commitment, 'COMMITMENT_MISMATCH');
    assert(notes.verify_position_membership(proof_position), 'INVALID_MEMBERSHIP');
    // position snapshots remain private, proof enforces fee claims against public growth
    assert(liquidity_commitment == prev_position_commitment, 'LIQ_COMMITMENT_MISMATCH');

    // pool pre-state must match proof
    let sqrt_price_current = adapter.get_sqrt_price();
    let tick_current = adapter.get_tick();
    assert(sqrt_price_current == sqrt_price_start, 'PRICE_MISMATCH');
    assert(tick_current == tick_start, 'TICK_START_MISMATCH');
    assert(adapter.get_liquidity() == liquidity_before, 'LIQ_BEFORE_MISMATCH');

    // invariant checks
    let tick_lower_mag: u128 = if tick_lower < 0 {
        (-tick_lower).try_into().expect('TICK_RANGE')
    } else {
        tick_lower.try_into().expect('TICK_RANGE')
    };
    let tick_upper_mag: u128 = if tick_upper < 0 {
        (-tick_upper).try_into().expect('TICK_RANGE')
    } else {
        tick_upper.try_into().expect('TICK_RANGE')
    };
    assert(tick_aligned(tick_lower, tick_spacing), 'TICK_LOWER_ALIGNMENT');
    assert(tick_aligned(tick_upper, tick_spacing), 'TICK_UPPER_ALIGNMENT');
    assert(tick_lower < tick_upper, 'INVALID_TICKS');
    assert(tick_lower_mag <= MAX_TICK_MAGNITUDE, 'TICK_LOWER_RANGE');
    assert(tick_upper_mag <= MAX_TICK_MAGNITUDE, 'TICK_UPPER_RANGE');
    let (liq_sign, liq_mag) = signed_u256_to_sign_mag(liquidity_delta);
    assert(!liq_sign, 'LIQ_DELTA_SIGN');
    assert(liq_mag == 0, 'LIQ_DELTA_NONZERO');

    let (fee_growth_global_0_current, fee_growth_global_1_current) = adapter.get_fee_growth_global();
    assert(fee_growth_global_0_current == fee_growth_global_0_before, 'FEE0_BEFORE_MISMATCH');
    assert(fee_growth_global_1_current == fee_growth_global_1_before, 'FEE1_BEFORE_MISMATCH');
    assert(fee_growth_global_0 == fee_growth_global_0_before, 'FEE0_CHANGED');
    assert(fee_growth_global_1 == fee_growth_global_1_before, 'FEE1_CHANGED');

    let fees_inside_current = core.get_pool_fees_per_liquidity_inside(
        pool_key_from_config(config),
        bounds_from_ticks(tick_lower, tick_upper),
    );
    let fee_inside_0_current: u256 = fees_inside_current.value0;
    let fee_inside_1_current: u256 = fees_inside_current.value1;
    assert(fee_growth_inside_0_after == fee_inside_0_current, 'FEE_INSIDE0_CURRENT');
    assert(fee_growth_inside_1_after == fee_inside_1_current, 'FEE_INSIDE1_CURRENT');

    let tick_lower_i128: i128 = tick_lower.try_into().expect('TICK_RANGE');
    let tick_upper_i128: i128 = tick_upper.try_into().expect('TICK_RANGE');
    let sqrt_ratio_lower_expected = tick_to_sqrt_ratio(tick_lower_i128.into());
    let sqrt_ratio_upper_expected = tick_to_sqrt_ratio(tick_upper_i128.into());
    assert(sqrt_ratio_lower == sqrt_ratio_lower_expected, 'SQRT_LOWER_MISMATCH');
    assert(sqrt_ratio_upper == sqrt_ratio_upper_expected, 'SQRT_UPPER_MISMATCH');

    let mut nullifiers: Array<felt252> = array![];
    nullifiers.append(nullifier_position);
    notes.mark_nullifiers_used(nullifiers.span());

    if new_position_commitment != 0 {
        assert(insert_proof_position.len() == 1, 'POSITION_INSERT_PROOF_LEN');
        notes.append_position_commitment(new_position_commitment, *insert_proof_position.at(0));
    } else {
        assert(insert_proof_position.len() == 0, 'POSITION_INSERT_PROOF_LEN');
    }
    if output_commitment_token0 != 0 {
        assert(output_proof_token0.len() == 1, 'OUT0_PROOF_LEN');
        notes.append_commitment(output_commitment_token0, config.token0, *output_proof_token0.at(0));
    } else {
        assert(output_proof_token0.len() == 0, 'OUT0_PROOF_LEN');
    }
    if output_commitment_token1 != 0 {
        assert(output_proof_token1.len() == 1, 'OUT1_PROOF_LEN');
        notes.append_commitment(output_commitment_token1, config.token1, *output_proof_token1.at(0));
    } else {
        assert(output_proof_token1.len() == 0, 'OUT1_PROOF_LEN');
    }

    // emit event
    state
        .emit(
            PrivateLiquidityFeesClaimed {
                timestamp: get_block_timestamp(),
            },
        );
}

fn tick_aligned(tick: i32, spacing: u128) -> bool {
    let mag: u128 = if tick < 0 {
        (-tick).try_into().expect('TICK_RANGE')
    } else {
        tick.try_into().expect('TICK_RANGE')
    };
    (mag % spacing) == 0
}

fn pool_key_from_config(config: PoolConfig) -> PoolKey {
    let extension: ContractAddress = 0.try_into().expect('ADDRESS_RANGE');
    PoolKey {
        token0: config.token0,
        token1: config.token1,
        fee: config.fee,
        tick_spacing: config.tick_spacing,
        extension,
    }
}

fn bounds_from_ticks(tick_lower: i32, tick_upper: i32) -> Bounds {
    let lower_i128: i128 = tick_lower.try_into().expect('TICK_RANGE');
    let upper_i128: i128 = tick_upper.try_into().expect('TICK_RANGE');
    Bounds {
        lower: lower_i128.into(),
        upper: upper_i128.into(),
    }
}

fn assert_high_zero(input: u256) -> u256 {
    assert(input.high == 0, 'UNEXPECTED_U256_HIGH');
    input
}

fn signed_u256_to_sign_mag(value: u256) -> (bool, u128) {
    assert(value.high == 0, 'LIQ_DELTA_HIGH');
    if value.low < HIGH_BIT_U128 {
        (false, value.low)
    } else {
        let mag = if value.low == HIGH_BIT_U128 {
            HIGH_BIT_U128
        } else {
            (MAX_U128 - value.low) + 1
        };
        (true, mag)
    }
}

fn decode_i128_signed(input: u256) -> Option<i128> {
    if input.high != 0 {
        return Option::None;
    }
    let sign_bit_set = input.low >= HIGH_BIT_U128;
    if !sign_bit_set {
        match input.low.try_into() {
            Option::Some(v) => Option::Some(v),
            Option::None => Option::None,
        }
    } else if input.low == HIGH_BIT_U128 {
        Option::Some(-170141183460469231731687303715884105728_i128)
    } else {
        let twos_mag: u128 = (MAX_U128 - input.low) + 1;
        match twos_mag.try_into() {
            Option::Some(mag_i128) => Option::Some(-mag_i128),
            Option::None => Option::None,
        }
    }
}

fn decode_i32_signed(input: u256) -> Option<i32> {
    match decode_i128_signed(input) {
        Option::Some(value) => {
            if (value < (-2147483648_i128)) || (value > 2147483647_i128) {
                Option::None
            } else {
                Option::Some(value.try_into().unwrap())
            }
        },
        Option::None => Option::None,
    }
}
