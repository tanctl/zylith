use core::array::{ArrayTrait, SpanTrait};
use core::option::{Option, OptionTrait};
use core::traits::TryInto;
use starknet::ContractAddress;
use zylith::constants::generated as generated_constants;
use zylith::clmm::math::fee::compute_fee;
use zylith::clmm::math::liquidity::liquidity_delta_to_amount_delta;
use zylith::privacy::ZylithVerifier::{
    DepositPublicOutputs, WithdrawPublicOutputs, IZylithVerifier,
};
use crate::common::{
    encode_i32_signed, u256_from_bool, u256_from_felt, u256_from_u128, neg_u256_from_mag,
};

const VK_SWAP: felt252 = 'SWAP';
const VK_SWAP_EXACT_OUT: felt252 = 'SWAP_EXACT_OUT';
const VK_LIQ_ADD: felt252 = 'LIQ_ADD';
const VK_LIQ_REMOVE: felt252 = 'LIQ_REMOVE';
const VK_LIQ_CLAIM: felt252 = 'LIQ_CLAIM';

pub fn build_swap_outputs(
    merkle_root: felt252,
    nullifier: felt252,
    sqrt_price_start: u256,
    sqrt_price_end: u256,
    liquidity_before: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    output_commitment: felt252,
    change_commitment: felt252,
    is_limited: bool,
    zero_for_one: bool,
    commitment_in: felt252,
    token_id_in: felt252,
    note_count: u128,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_steps: usize = generated_constants::MAX_SWAP_STEPS;
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;

    outputs.append(u256_from_felt(VK_SWAP));
    outputs.append(u256_from_felt(merkle_root));
    outputs.append(u256_from_felt(nullifier));
    outputs.append(sqrt_price_start);
    outputs.append(sqrt_price_end);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(output_commitment));
    outputs.append(u256_from_felt(change_commitment));
    outputs.append(u256_from_bool(is_limited));
    outputs.append(u256_from_bool(zero_for_one));

    let mut idx: usize = 0;
    while idx < max_steps {
        outputs.append(sqrt_price_end);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(sqrt_price_start);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_0_before);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_1_before);
        idx += 1;
    }

    outputs.append(u256_from_felt(commitment_in));
    outputs.append(u256_from_u128(token_id_in.try_into().unwrap()));
    outputs.append(u256_from_u128(note_count));

    let mut extra: usize = 0;
    while extra < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        extra += 1;
    }
    extra = 0;
    while extra < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        extra += 1;
    }

    outputs
}

pub fn build_swap_outputs_with_extras(
    merkle_root: felt252,
    nullifier: felt252,
    sqrt_price_start: u256,
    sqrt_price_end: u256,
    liquidity_before: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    output_commitment: felt252,
    change_commitment: felt252,
    is_limited: bool,
    zero_for_one: bool,
    commitment_in: felt252,
    token_id_in: felt252,
    note_count: u128,
    extra_nullifiers: Span<felt252>,
    extra_commitments: Span<felt252>,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_steps: usize = generated_constants::MAX_SWAP_STEPS;
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;
    let note_count_usize: usize = note_count.try_into().expect('NOTE_COUNT_RANGE');
    let expected_extra = if note_count_usize > 0 { note_count_usize - 1 } else { 0 };
    assert(extra_nullifiers.len() == expected_extra, 'EXTRA_NULLIFIER_COUNT');
    assert(extra_commitments.len() == expected_extra, 'EXTRA_COMMITMENT_COUNT');

    outputs.append(u256_from_felt(VK_SWAP));
    outputs.append(u256_from_felt(merkle_root));
    outputs.append(u256_from_felt(nullifier));
    outputs.append(sqrt_price_start);
    outputs.append(sqrt_price_end);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(output_commitment));
    outputs.append(u256_from_felt(change_commitment));
    outputs.append(u256_from_bool(is_limited));
    outputs.append(u256_from_bool(zero_for_one));

    let mut idx: usize = 0;
    while idx < max_steps {
        outputs.append(sqrt_price_end);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(sqrt_price_start);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_0_before);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_1_before);
        idx += 1;
    }

    outputs.append(u256_from_felt(commitment_in));
    outputs.append(u256_from_u128(token_id_in.try_into().unwrap()));
    outputs.append(u256_from_u128(note_count));

    idx = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_nullifiers.len() {
            outputs.append(u256_from_felt(*extra_nullifiers.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_commitments.len() {
            outputs.append(u256_from_felt(*extra_commitments.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }

    outputs
}

pub fn build_swap_outputs_with_steps(
    merkle_root: felt252,
    nullifier: felt252,
    sqrt_price_start: u256,
    sqrt_price_end: u256,
    liquidity_before: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    output_commitment: felt252,
    change_commitment: felt252,
    is_limited: bool,
    zero_for_one: bool,
    commitment_in: felt252,
    token_id_in: felt252,
    note_count: u128,
    step_next_value: u256,
    step_limit_value: u256,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_steps: usize = generated_constants::MAX_SWAP_STEPS;
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;

    outputs.append(u256_from_felt(VK_SWAP));
    outputs.append(u256_from_felt(merkle_root));
    outputs.append(u256_from_felt(nullifier));
    outputs.append(sqrt_price_start);
    outputs.append(sqrt_price_end);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(output_commitment));
    outputs.append(u256_from_felt(change_commitment));
    outputs.append(u256_from_bool(is_limited));
    outputs.append(u256_from_bool(zero_for_one));

    let mut idx: usize = 0;
    while idx < max_steps {
        outputs.append(step_next_value);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(step_limit_value);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_0_before);
        idx += 1;
    }
    idx = 0;
    while idx < max_steps {
        outputs.append(fee_growth_global_1_before);
        idx += 1;
    }

    outputs.append(u256_from_felt(commitment_in));
    outputs.append(u256_from_u128(token_id_in.try_into().unwrap()));
    outputs.append(u256_from_u128(note_count));

    let mut extra: usize = 0;
    while extra < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        extra += 1;
    }
    extra = 0;
    while extra < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        extra += 1;
    }

    outputs
}

pub fn build_liquidity_add_outputs(
    merkle_root_token0: felt252,
    merkle_root_token1: felt252,
    merkle_root_position: felt252,
    sqrt_price_start: u256,
    tick_start: i32,
    tick_lower: i32,
    tick_upper: i32,
    sqrt_ratio_lower: u256,
    sqrt_ratio_upper: u256,
    liquidity_before: u128,
    liquidity_delta: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    prev_position_commitment: felt252,
    new_position_commitment: felt252,
    fee_growth_inside_0: u256,
    fee_growth_inside_1: u256,
    input_commitment_token0: felt252,
    input_commitment_token1: felt252,
    nullifier_token0: felt252,
    nullifier_token1: felt252,
    output_commitment_token0: felt252,
    output_commitment_token1: felt252,
    note_count0: u128,
    note_count1: u128,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;

    outputs.append(u256_from_felt(VK_LIQ_ADD));
    outputs.append(u256_from_felt(merkle_root_token0));
    outputs.append(u256_from_felt(merkle_root_token1));
    outputs.append(u256_from_felt(merkle_root_position));
    outputs.append(u256_from_u128(0));
    outputs.append(sqrt_price_start);
    outputs.append(encode_i32_signed(tick_start));
    outputs.append(encode_i32_signed(tick_lower));
    outputs.append(encode_i32_signed(tick_upper));
    outputs.append(sqrt_ratio_lower);
    outputs.append(sqrt_ratio_upper);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(liquidity_delta));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(u256_from_felt(new_position_commitment));
    outputs.append(u256_from_felt(new_position_commitment));
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(u256_from_felt(input_commitment_token0));
    outputs.append(u256_from_felt(input_commitment_token1));
    outputs.append(u256_from_felt(nullifier_token0));
    outputs.append(u256_from_felt(nullifier_token1));
    outputs.append(u256_from_felt(output_commitment_token0));
    outputs.append(u256_from_felt(output_commitment_token1));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(note_count0));
    outputs.append(u256_from_u128(note_count1));

    let mut idx: usize = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }

    outputs
}

pub fn build_liquidity_add_outputs_with_notes(
    merkle_root_token0: felt252,
    merkle_root_token1: felt252,
    merkle_root_position: felt252,
    nullifier_position: felt252,
    sqrt_price_start: u256,
    tick_start: i32,
    tick_lower: i32,
    tick_upper: i32,
    sqrt_ratio_lower: u256,
    sqrt_ratio_upper: u256,
    liquidity_before: u128,
    liquidity_delta: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    prev_position_commitment: felt252,
    new_position_commitment: felt252,
    fee_growth_inside_0: u256,
    fee_growth_inside_1: u256,
    input_commitment_token0: felt252,
    input_commitment_token1: felt252,
    nullifier_token0: felt252,
    nullifier_token1: felt252,
    output_commitment_token0: felt252,
    output_commitment_token1: felt252,
    note_count0: u128,
    note_count1: u128,
    extra_nullifiers0: Span<felt252>,
    extra_nullifiers1: Span<felt252>,
    extra_commitments0: Span<felt252>,
    extra_commitments1: Span<felt252>,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;
    let note0_usize: usize = note_count0.try_into().expect('NOTE_COUNT0_RANGE');
    let note1_usize: usize = note_count1.try_into().expect('NOTE_COUNT1_RANGE');
    let expected0 = if note0_usize > 0 { note0_usize - 1 } else { 0 };
    let expected1 = if note1_usize > 0 { note1_usize - 1 } else { 0 };
    assert(extra_nullifiers0.len() == expected0, 'EXTRA_NULLIFIER0_COUNT');
    assert(extra_commitments0.len() == expected0, 'EXTRA_COMMITMENT0_COUNT');
    assert(extra_nullifiers1.len() == expected1, 'EXTRA_NULLIFIER1_COUNT');
    assert(extra_commitments1.len() == expected1, 'EXTRA_COMMITMENT1_COUNT');

    outputs.append(u256_from_felt(VK_LIQ_ADD));
    outputs.append(u256_from_felt(merkle_root_token0));
    outputs.append(u256_from_felt(merkle_root_token1));
    outputs.append(u256_from_felt(merkle_root_position));
    outputs.append(u256_from_felt(nullifier_position));
    outputs.append(sqrt_price_start);
    outputs.append(encode_i32_signed(tick_start));
    outputs.append(encode_i32_signed(tick_lower));
    outputs.append(encode_i32_signed(tick_upper));
    outputs.append(sqrt_ratio_lower);
    outputs.append(sqrt_ratio_upper);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(liquidity_delta));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(u256_from_felt(new_position_commitment));
    outputs.append(u256_from_felt(new_position_commitment));
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(u256_from_felt(input_commitment_token0));
    outputs.append(u256_from_felt(input_commitment_token1));
    outputs.append(u256_from_felt(nullifier_token0));
    outputs.append(u256_from_felt(nullifier_token1));
    outputs.append(u256_from_felt(output_commitment_token0));
    outputs.append(u256_from_felt(output_commitment_token1));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(note_count0));
    outputs.append(u256_from_u128(note_count1));

    let mut idx: usize = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_nullifiers0.len() {
            outputs.append(u256_from_felt(*extra_nullifiers0.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_nullifiers1.len() {
            outputs.append(u256_from_felt(*extra_nullifiers1.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_commitments0.len() {
            outputs.append(u256_from_felt(*extra_commitments0.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        if idx < extra_commitments1.len() {
            outputs.append(u256_from_felt(*extra_commitments1.at(idx)));
        } else {
            outputs.append(u256_from_u128(0));
        }
        idx += 1;
    }

    outputs
}

pub fn build_liquidity_remove_outputs(
    merkle_root_token0: felt252,
    merkle_root_token1: felt252,
    merkle_root_position: felt252,
    nullifier_position: felt252,
    sqrt_price_start: u256,
    tick_start: i32,
    tick_lower: i32,
    tick_upper: i32,
    sqrt_ratio_lower: u256,
    sqrt_ratio_upper: u256,
    liquidity_before: u128,
    liquidity_delta_mag: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    prev_position_commitment: felt252,
    fee_growth_inside_0: u256,
    fee_growth_inside_1: u256,
    output_commitment_token0: felt252,
    output_commitment_token1: felt252,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;

    outputs.append(u256_from_felt(VK_LIQ_REMOVE));
    outputs.append(u256_from_felt(merkle_root_token0));
    outputs.append(u256_from_felt(merkle_root_token1));
    outputs.append(u256_from_felt(merkle_root_position));
    outputs.append(u256_from_felt(nullifier_position));
    outputs.append(sqrt_price_start);
    outputs.append(encode_i32_signed(tick_start));
    outputs.append(encode_i32_signed(tick_lower));
    outputs.append(encode_i32_signed(tick_upper));
    outputs.append(sqrt_ratio_lower);
    outputs.append(sqrt_ratio_upper);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(neg_u256_from_mag(liquidity_delta_mag));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(fee_growth_inside_0);
    outputs.append(fee_growth_inside_1);
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_felt(output_commitment_token0));
    outputs.append(u256_from_felt(output_commitment_token1));
    let liquidity_delta = neg_u256_from_mag(liquidity_delta_mag);
    let delta = liquidity_delta_to_amount_delta(
        sqrt_price_start, liquidity_delta, sqrt_ratio_lower, sqrt_ratio_upper,
    );
    let protocol_fee_0: u128 = compute_fee(delta.amount0.mag, fee);
    let protocol_fee_1: u128 = compute_fee(delta.amount1.mag, fee);
    outputs.append(u256_from_u128(protocol_fee_0));
    outputs.append(u256_from_u128(protocol_fee_1));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));

    let mut idx: usize = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }

    outputs
}

pub fn build_liquidity_claim_outputs(
    merkle_root_token0: felt252,
    merkle_root_token1: felt252,
    merkle_root_position: felt252,
    nullifier_position: felt252,
    sqrt_price_start: u256,
    tick_start: i32,
    tick_lower: i32,
    tick_upper: i32,
    sqrt_ratio_lower: u256,
    sqrt_ratio_upper: u256,
    liquidity_before: u128,
    fee: u128,
    fee_growth_global_0_before: u256,
    fee_growth_global_1_before: u256,
    prev_position_commitment: felt252,
    new_position_commitment: felt252,
    fee_growth_inside_0_before: u256,
    fee_growth_inside_1_before: u256,
    fee_growth_inside_0_after: u256,
    fee_growth_inside_1_after: u256,
    output_commitment_token0: felt252,
    output_commitment_token1: felt252,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    let max_input_notes: usize = generated_constants::MAX_INPUT_NOTES;

    outputs.append(u256_from_felt(VK_LIQ_CLAIM));
    outputs.append(u256_from_felt(merkle_root_token0));
    outputs.append(u256_from_felt(merkle_root_token1));
    outputs.append(u256_from_felt(merkle_root_position));
    outputs.append(u256_from_felt(nullifier_position));
    outputs.append(sqrt_price_start);
    outputs.append(encode_i32_signed(tick_start));
    outputs.append(encode_i32_signed(tick_lower));
    outputs.append(encode_i32_signed(tick_upper));
    outputs.append(sqrt_ratio_lower);
    outputs.append(sqrt_ratio_upper);
    outputs.append(u256_from_u128(liquidity_before));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(fee));
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(fee_growth_global_0_before);
    outputs.append(fee_growth_global_1_before);
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(u256_from_felt(new_position_commitment));
    outputs.append(u256_from_felt(prev_position_commitment));
    outputs.append(fee_growth_inside_0_before);
    outputs.append(fee_growth_inside_1_before);
    outputs.append(fee_growth_inside_0_after);
    outputs.append(fee_growth_inside_1_after);
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_felt(output_commitment_token0));
    outputs.append(u256_from_felt(output_commitment_token1));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));
    outputs.append(u256_from_u128(0));

    let mut idx: usize = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }
    idx = 0;
    while idx < (max_input_notes - 1) {
        outputs.append(u256_from_u128(0));
        idx += 1;
    }

    outputs
}

#[starknet::contract]
pub mod MockZylithVerifier {
    use super::{
        ArrayTrait, ContractAddress, DepositPublicOutputs, Option,
        OptionTrait, SpanTrait, WithdrawPublicOutputs, IZylithVerifier,
    };
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    #[storage]
    struct Storage {
        swap_outputs_len: u32,
        swap_outputs: Map<u32, u256>,
        swap_should_verify: bool,
        swap_exact_outputs_len: u32,
        swap_exact_outputs: Map<u32, u256>,
        swap_exact_should_verify: bool,
        liq_add_outputs_len: u32,
        liq_add_outputs: Map<u32, u256>,
        liq_add_should_verify: bool,
        liq_remove_outputs_len: u32,
        liq_remove_outputs: Map<u32, u256>,
        liq_remove_should_verify: bool,
        liq_claim_outputs_len: u32,
        liq_claim_outputs: Map<u32, u256>,
        liq_claim_should_verify: bool,
        deposit_commitment: felt252,
        deposit_amount: u256,
        deposit_token_id: felt252,
        deposit_should_verify: bool,
        withdraw_commitment: felt252,
        withdraw_nullifier: felt252,
        withdraw_amount: u256,
        withdraw_token_id: felt252,
        withdraw_recipient: ContractAddress,
        withdraw_should_verify: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.swap_should_verify.write(true);
        self.swap_exact_should_verify.write(true);
        self.liq_add_should_verify.write(true);
        self.liq_remove_should_verify.write(true);
        self.liq_claim_should_verify.write(true);
        self.deposit_should_verify.write(true);
        self.withdraw_should_verify.write(true);
    }

    #[abi(embed_v0)]
    impl ExternalImpl of MockZylithVerifierExternal<ContractState> {
        fn set_swap_outputs(ref self: ContractState, outputs: Span<u256>) {
            write_outputs(ref self, outputs, OutputKind::SwapOutputs);
        }

        fn set_swap_exact_outputs(ref self: ContractState, outputs: Span<u256>) {
            write_outputs(ref self, outputs, OutputKind::SwapExactOutputs);
        }

        fn set_liq_add_outputs(ref self: ContractState, outputs: Span<u256>) {
            write_outputs(ref self, outputs, OutputKind::LiquidityAddOutputs);
        }

        fn set_liq_remove_outputs(ref self: ContractState, outputs: Span<u256>) {
            write_outputs(ref self, outputs, OutputKind::LiquidityRemoveOutputs);
        }

        fn set_liq_claim_outputs(ref self: ContractState, outputs: Span<u256>) {
            write_outputs(ref self, outputs, OutputKind::LiquidityClaimOutputs);
        }

        fn set_deposit_output(
            ref self: ContractState, commitment: felt252, amount: u256, token_id: felt252
        ) {
            self.deposit_commitment.write(commitment);
            self.deposit_amount.write(amount);
            self.deposit_token_id.write(token_id);
        }

        fn set_withdraw_output(
            ref self: ContractState,
            commitment: felt252,
            nullifier: felt252,
            amount: u256,
            token_id: felt252,
            recipient: ContractAddress,
        ) {
            self.withdraw_commitment.write(commitment);
            self.withdraw_nullifier.write(nullifier);
            self.withdraw_amount.write(amount);
            self.withdraw_token_id.write(token_id);
            self.withdraw_recipient.write(recipient);
        }

        fn set_should_verify(ref self: ContractState, selector: felt252, value: bool) {
            match selector {
                'swap' => self.swap_should_verify.write(value),
                'swap_exact' => self.swap_exact_should_verify.write(value),
                'liq_add' => self.liq_add_should_verify.write(value),
                'liq_remove' => self.liq_remove_should_verify.write(value),
                'liq_claim' => self.liq_claim_should_verify.write(value),
                'deposit' => self.deposit_should_verify.write(value),
                'withdraw' => self.withdraw_should_verify.write(value),
                _ => panic!("UNKNOWN_SELECTOR"),
            }
        }
    }

    #[starknet::interface]
    pub trait MockZylithVerifierExternal<TContractState> {
        fn set_swap_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_swap_exact_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_liq_add_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_liq_remove_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_liq_claim_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_deposit_output(
            ref self: TContractState, commitment: felt252, amount: u256, token_id: felt252
        );
        fn set_withdraw_output(
            ref self: TContractState,
            commitment: felt252,
            nullifier: felt252,
            amount: u256,
            token_id: felt252,
            recipient: ContractAddress,
        );
        fn set_should_verify(ref self: TContractState, selector: felt252, value: bool);
    }

    #[abi(embed_v0)]
    impl MockZylithVerifierImpl of IZylithVerifier<ContractState> {
        fn verify_private_swap(self: @ContractState, calldata: Span<felt252>) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.swap_should_verify.read() {
                return Option::<Span<u256>>::None;
            }
            Option::Some(read_outputs(self, OutputKind::SwapOutputs).span())
        }

        fn verify_private_swap_exact_out(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.swap_exact_should_verify.read() {
                return Option::<Span<u256>>::None;
            }
            Option::Some(read_outputs(self, OutputKind::SwapExactOutputs).span())
        }

        fn verify_private_liquidity_add(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.liq_add_should_verify.read() {
                return Option::<Span<u256>>::None;
            }
            Option::Some(read_outputs(self, OutputKind::LiquidityAddOutputs).span())
        }

        fn verify_private_liquidity_remove(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.liq_remove_should_verify.read() {
                return Option::<Span<u256>>::None;
            }
            Option::Some(read_outputs(self, OutputKind::LiquidityRemoveOutputs).span())
        }

        fn verify_private_liquidity_claim(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.liq_claim_should_verify.read() {
                return Option::<Span<u256>>::None;
            }
            Option::Some(read_outputs(self, OutputKind::LiquidityClaimOutputs).span())
        }

        fn verify_deposit(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<DepositPublicOutputs> {
            let _ = calldata;
            if !self.deposit_should_verify.read() {
                return Option::<DepositPublicOutputs>::None;
            }
            Option::Some(
                DepositPublicOutputs {
                    commitment: self.deposit_commitment.read(),
                    amount: self.deposit_amount.read(),
                    token_id: self.deposit_token_id.read(),
                }
            )
        }

        fn verify_withdraw(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<WithdrawPublicOutputs> {
            let _ = calldata;
            if !self.withdraw_should_verify.read() {
                return Option::<WithdrawPublicOutputs>::None;
            }
            Option::Some(
                WithdrawPublicOutputs {
                    commitment: self.withdraw_commitment.read(),
                    nullifier: self.withdraw_nullifier.read(),
                    amount: self.withdraw_amount.read(),
                    token_id: self.withdraw_token_id.read(),
                    recipient: self.withdraw_recipient.read(),
                }
            )
        }

        fn update_swap_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_swap_exact_out_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_liquidity_add_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_liquidity_remove_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_liquidity_claim_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_membership_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_deposit_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn update_withdraw_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
        }

        fn set_verifier_update_delay(ref self: ContractState, delay_secs: u64) {
            let _ = delay_secs;
        }
    }

    #[derive(Copy, Drop)]
    enum OutputKind {
        SwapOutputs,
        SwapExactOutputs,
        LiquidityAddOutputs,
        LiquidityRemoveOutputs,
        LiquidityClaimOutputs,
    }

    fn write_outputs(ref self: ContractState, outputs: Span<u256>, kind: OutputKind) {
        let len: u32 = outputs.len().try_into().unwrap();
        let mut idx: u32 = 0;
        match kind {
            OutputKind::SwapOutputs => {
                self.swap_outputs_len.write(len);
                while idx < len {
                    self.swap_outputs.write(idx, *outputs.at(idx.into()));
                    idx += 1;
                }
            },
            OutputKind::SwapExactOutputs => {
                self.swap_exact_outputs_len.write(len);
                while idx < len {
                    self.swap_exact_outputs.write(idx, *outputs.at(idx.into()));
                    idx += 1;
                }
            },
            OutputKind::LiquidityAddOutputs => {
                self.liq_add_outputs_len.write(len);
                while idx < len {
                    self.liq_add_outputs.write(idx, *outputs.at(idx.into()));
                    idx += 1;
                }
            },
            OutputKind::LiquidityRemoveOutputs => {
                self.liq_remove_outputs_len.write(len);
                while idx < len {
                    self.liq_remove_outputs.write(idx, *outputs.at(idx.into()));
                    idx += 1;
                }
            },
            OutputKind::LiquidityClaimOutputs => {
                self.liq_claim_outputs_len.write(len);
                while idx < len {
                    self.liq_claim_outputs.write(idx, *outputs.at(idx.into()));
                    idx += 1;
                }
            },
        }
    }

    fn read_outputs(self: @ContractState, kind: OutputKind) -> Array<u256> {
        let (len, map) = match kind {
            OutputKind::SwapOutputs => (self.swap_outputs_len.read(), OutputMap::Swap),
            OutputKind::SwapExactOutputs => (self.swap_exact_outputs_len.read(), OutputMap::SwapExact),
            OutputKind::LiquidityAddOutputs => (self.liq_add_outputs_len.read(), OutputMap::LiqAdd),
            OutputKind::LiquidityRemoveOutputs => {
                (self.liq_remove_outputs_len.read(), OutputMap::LiqRemove)
            },
            OutputKind::LiquidityClaimOutputs => {
                (self.liq_claim_outputs_len.read(), OutputMap::LiqClaim)
            },
        };
        let mut outputs: Array<u256> = array![];
        let mut idx: u32 = 0;
        while idx < len {
            let value = match map {
                OutputMap::Swap => self.swap_outputs.read(idx),
                OutputMap::SwapExact => self.swap_exact_outputs.read(idx),
                OutputMap::LiqAdd => self.liq_add_outputs.read(idx),
                OutputMap::LiqRemove => self.liq_remove_outputs.read(idx),
                OutputMap::LiqClaim => self.liq_claim_outputs.read(idx),
            };
            outputs.append(value);
            idx += 1;
        }
        outputs
    }

    #[derive(Copy, Drop)]
    enum OutputMap {
        Swap,
        SwapExact,
        LiqAdd,
        LiqRemove,
        LiqClaim,
    }
}
