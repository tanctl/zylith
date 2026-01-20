#[feature("deprecated_legacy_map")]
use core::array::ArrayTrait;
use core::traits::TryInto;
use snforge_std::{start_cheat_caller_address, test_address};
use starknet::ContractAddress;

use zylith::core::PoolAdapter::{IPoolAdapterDispatcher, IPoolAdapterDispatcherTrait};
use zylith::core::ZylithPool::{ZylithPoolExternalDispatcher, ZylithPoolExternalDispatcherTrait};
use zylith::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use zylith::privacy::ShieldedNotes::ShieldedNotesExternalDispatcher;
use zylith::privacy::ShieldedNotes::ShieldedNotesExternalDispatcherTrait;
use zylith::clmm::math::ticks::tick_to_sqrt_ratio;

use crate::common::{
    deploy_contract_at,
    insertion_proof_for_empty_leaf,
    insertion_proof_for_second_leaf,
    merkle_proof_for_single_leaf,
    merkle_proof_for_two_leaves,
    merkle_root_for_single_leaf,
    merkle_root_for_two_leaves,
    u256_from_felt,
    u256_from_u128,
};
use crate::common::mock_proof_generator::{
    build_liquidity_add_outputs_with_notes,
    build_liquidity_remove_outputs,
    build_swap_outputs_with_extras,
};
use crate::common::mocks::MockCore::MockCoreExternalDispatcher;
use crate::common::mocks::MockCore::MockCoreExternalDispatcherTrait;
use crate::common::mocks::MockGaragaVerifier::MockGaragaVerifierExternalDispatcher;
use crate::common::mocks::MockGaragaVerifier::MockGaragaVerifierExternalDispatcherTrait;
use crate::common::mocks::MockPoolAdapter::MockPoolAdapterExternalDispatcher;
use crate::common::mocks::MockPoolAdapter::MockPoolAdapterExternalDispatcherTrait;

fn build_deposit_outputs(commitment: felt252, amount: u128, token_id: felt252) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    outputs.append(u256_from_felt('DEPOSIT'));
    outputs.append(u256_from_felt(commitment));
    outputs.append(u256_from_u128(amount));
    outputs.append(u256_from_felt(token_id));
    outputs
}

fn build_withdraw_outputs(
    commitment: felt252,
    nullifier: felt252,
    amount: u128,
    token_id: felt252,
    recipient: ContractAddress,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    outputs.append(u256_from_felt('WITHDRAW'));
    outputs.append(u256_from_felt(commitment));
    outputs.append(u256_from_felt(nullifier));
    outputs.append(u256_from_u128(amount));
    outputs.append(u256_from_felt(token_id));
    outputs.append(u256_from_felt(recipient.into()));
    outputs
}

fn setup_pool_with_verifier() -> (
    ZylithPoolExternalDispatcher,
    ShieldedNotesExternalDispatcher,
    MockGaragaVerifierExternalDispatcher,
    IERC20Dispatcher,
    IERC20Dispatcher,
    ContractAddress,
    ContractAddress,
    ContractAddress,
    ContractAddress,
) {
    let pool_address = 0x7000.try_into().expect('ADDRESS_RANGE');
    let core_address = 0x7100.try_into().expect('ADDRESS_RANGE');
    let adapter_address = 0x7200.try_into().expect('ADDRESS_RANGE');
    let notes_address = 0x7300.try_into().expect('ADDRESS_RANGE');
    let verifier_address = 0x7400.try_into().expect('ADDRESS_RANGE');
    let garaga_address = 0x7500.try_into().expect('ADDRESS_RANGE');
    let token0_address = 0x7600.try_into().expect('ADDRESS_RANGE');
    let token1_address = 0x7700.try_into().expect('ADDRESS_RANGE');
    let mut core_calldata = array![];
    pool_address.serialize(ref core_calldata);
    adapter_address.serialize(ref core_calldata);
    let _ = deploy_contract_at("MockCore", core_calldata, core_address);

    let mut adapter_calldata = array![];
    core_address.serialize(ref adapter_calldata);
    pool_address.serialize(ref adapter_calldata);
    let _ = deploy_contract_at("MockPoolAdapter", adapter_calldata, adapter_address);

    let garaga_calldata = array![];
    let _ = deploy_contract_at("MockGaragaVerifier", garaga_calldata, garaga_address);

    let mut verifier_calldata = array![];
    test_address().serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    let _ = deploy_contract_at("ZylithVerifier", verifier_calldata, verifier_address);

    let mut token0_calldata = array![];
    test_address().serialize(ref token0_calldata);
    1_000_000_u128.serialize(ref token0_calldata);
    't0'.serialize(ref token0_calldata);
    't0'.serialize(ref token0_calldata);
    let _ = deploy_contract_at("MockERC20", token0_calldata, token0_address);

    let mut token1_calldata = array![];
    test_address().serialize(ref token1_calldata);
    1_000_000_u128.serialize(ref token1_calldata);
    't1'.serialize(ref token1_calldata);
    't1'.serialize(ref token1_calldata);
    let _ = deploy_contract_at("MockERC20", token1_calldata, token1_address);

    let mut notes_calldata = array![];
    token0_address.serialize(ref notes_calldata);
    token1_address.serialize(ref notes_calldata);
    pool_address.serialize(ref notes_calldata);
    verifier_address.serialize(ref notes_calldata);
    test_address().serialize(ref notes_calldata);
    let _ = deploy_contract_at("ShieldedNotes", notes_calldata, notes_address);

    let mut pool_calldata = array![];
    core_address.serialize(ref pool_calldata);
    adapter_address.serialize(ref pool_calldata);
    notes_address.serialize(ref pool_calldata);
    verifier_address.serialize(ref pool_calldata);
    token0_address.serialize(ref pool_calldata);
    token1_address.serialize(ref pool_calldata);
    30_u128.serialize(ref pool_calldata);
    1_i32.serialize(ref pool_calldata);
    test_address().serialize(ref pool_calldata);
    let _ = deploy_contract_at("ZylithPool", pool_calldata, pool_address);

    let pool = ZylithPoolExternalDispatcher { contract_address: pool_address };
    start_cheat_caller_address(pool_address, test_address());
    pool.initialize(token0_address, token1_address, 30, 1, 0);

    (
        pool,
        ShieldedNotesExternalDispatcher { contract_address: notes_address },
        MockGaragaVerifierExternalDispatcher { contract_address: garaga_address },
        IERC20Dispatcher { contract_address: token0_address },
        IERC20Dispatcher { contract_address: token1_address },
        pool_address,
        adapter_address,
        core_address,
        notes_address,
    )
}

#[available_gas(max: 100000000)]
#[test]
fn test_deposit_with_verifier() {
    let (_, notes, garaga, token0, _, _, _, _, notes_address) = setup_pool_with_verifier();
    let commitment: felt252 = 111;
    let amount: u128 = 100;
    let outputs = build_deposit_outputs(commitment, amount, 0);
    garaga.set_outputs(outputs.span());
    token0.approve(notes_address, u256_from_u128(amount));
    let out_commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    assert(out_commitment == commitment, 'commitment mismatch');
}

#[available_gas(max: 100000000)]
#[test]
fn test_withdraw_with_verifier() {
    let (_, notes, garaga, token0, _, _, _, _, notes_address) = setup_pool_with_verifier();
    let commitment: felt252 = 222;
    let amount: u128 = 200;
    let deposit_outputs = build_deposit_outputs(commitment, amount, 0);
    garaga.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(amount));
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());

    let root = merkle_root_for_single_leaf(commitment);
    let proof = merkle_proof_for_single_leaf(root, commitment);
    let nullifier: felt252 = 333;
    let withdraw_outputs = build_withdraw_outputs(commitment, nullifier, amount, 0, test_address());
    garaga.set_outputs(withdraw_outputs.span());
    notes.withdraw_token0(array![].span(), proof);
    assert(notes.is_nullifier_used(nullifier), 'nullifier not marked');
}

#[available_gas(max: 100000000)]
#[test]
fn test_swap_multi_note_with_verifier() {
    let (pool, notes, garaga, token0, _, pool_address, adapter_address, _, notes_address) =
        setup_pool_with_verifier();
    let commitment0: felt252 = 1001;
    let commitment1: felt252 = 1002;
    let amount0: u128 = 120;
    let amount1: u128 = 80;

    let outputs0 = build_deposit_outputs(commitment0, amount0, 0);
    garaga.set_outputs(outputs0.span());
    token0.approve(notes_address, u256_from_u128(amount0));
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());

    let outputs1 = build_deposit_outputs(commitment1, amount1, 0);
    garaga.set_outputs(outputs1.span());
    token0.approve(notes_address, u256_from_u128(amount1));
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_second_leaf(commitment0));

    let root0 = merkle_root_for_two_leaves(commitment0, commitment1);
    let proof0 = merkle_proof_for_two_leaves(root0, commitment0, 0, commitment1);
    let proof1 = merkle_proof_for_two_leaves(root0, commitment1, 1, commitment0);

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    let adapter_state = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter_state
        .set_pool_state(sqrt_start, 0, 1_u128, 1_u128, u256_from_u128(0), u256_from_u128(0));

    let output_commitment: felt252 = 2001;
    let nullifier0: felt252 = 3001;
    let nullifier1: felt252 = 3002;
    let outputs = build_swap_outputs_with_extras(
        root0,
        nullifier0,
        sqrt_start,
        sqrt_end,
        1,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        output_commitment,
        0,
        false,
        true,
        commitment0,
        0,
        2,
        array![nullifier1].span(),
        array![commitment1].span(),
    );
    garaga.set_outputs(outputs.span());
    let output_proof = insertion_proof_for_empty_leaf();
    pool.swap_private(array![].span(), array![proof0, proof1].span(), array![output_proof].span());
    assert(notes.is_nullifier_used(nullifier0), 'nullifier0 not used');
    assert(notes.is_nullifier_used(nullifier1), 'nullifier1 not used');
    let state = pool.get_pool_state();
    assert(state.sqrt_price == sqrt_end, 'price update');
}

#[available_gas(max: 100000000)]
#[test]
fn test_liquidity_add_update_with_verifier() {
    let (pool, notes, garaga, token0, token1, pool_address, adapter_address, core_address, notes_address) =
        setup_pool_with_verifier();
    let commitment0: felt252 = 3001;
    let commitment1: felt252 = 3002;
    let amount0: u128 = 500;
    let amount1: u128 = 600;

    let outputs0 = build_deposit_outputs(commitment0, amount0, 0);
    garaga.set_outputs(outputs0.span());
    token0.approve(notes_address, u256_from_u128(amount0));
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());

    let outputs1 = build_deposit_outputs(commitment1, amount1, 1);
    garaga.set_outputs(outputs1.span());
    token1.approve(notes_address, u256_from_u128(amount1));
    let _ = notes.deposit_token1(array![].span(), insertion_proof_for_empty_leaf());

    let prev_position_commitment: felt252 = 4001;
    start_cheat_caller_address(notes_address, pool_address);
    let _ = notes.append_position_commitment(
        prev_position_commitment,
        insertion_proof_for_empty_leaf(),
    );
    let root_position = merkle_root_for_single_leaf(prev_position_commitment);

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let adapter_state = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter_state
        .set_pool_state(sqrt_start, 0, 1_u128, 100_u128, u256_from_u128(0), u256_from_u128(0));
    let core = MockCoreExternalDispatcher { contract_address: core_address };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let tick_lower = -120;
    let tick_upper = 120;
    let tick_lower_i128: i128 = tick_lower.try_into().unwrap();
    let tick_upper_i128: i128 = tick_upper.try_into().unwrap();
    let sqrt_ratio_lower = tick_to_sqrt_ratio(tick_lower_i128.into());
    let sqrt_ratio_upper = tick_to_sqrt_ratio(tick_upper_i128.into());
    let new_position_commitment: felt252 = 4002;
    let nullifier_position: felt252 = 5001;
    let nullifier_token0: felt252 = 5002;
    let nullifier_token1: felt252 = 5003;

    let root0 = merkle_root_for_single_leaf(commitment0);
    let root1 = merkle_root_for_single_leaf(commitment1);
    let outputs = build_liquidity_add_outputs_with_notes(
        root0,
        root1,
        root_position,
        nullifier_position,
        sqrt_start,
        0,
        tick_lower,
        tick_upper,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        100,
        10,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        prev_position_commitment,
        new_position_commitment,
        u256_from_u128(0),
        u256_from_u128(0),
        commitment0,
        commitment1,
        nullifier_token0,
        nullifier_token1,
        0,
        0,
        1,
        1,
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
    garaga.set_outputs(outputs.span());

    let proof0 = merkle_proof_for_single_leaf(root0, commitment0);
    let proof1 = merkle_proof_for_single_leaf(root1, commitment1);
    let proof_position = merkle_proof_for_single_leaf(root_position, prev_position_commitment);
    let insert_proof_position = insertion_proof_for_second_leaf(prev_position_commitment);

    pool.add_liquidity_private(
        array![].span(),
        array![proof0].span(),
        array![proof1].span(),
        array![proof_position].span(),
        array![insert_proof_position].span(),
        array![].span(),
        array![].span(),
    );
    assert(notes.is_nullifier_used(nullifier_position), 'position nullifier');
    assert(notes.is_nullifier_used(nullifier_token0), 'token0 nullifier');
    assert(notes.is_nullifier_used(nullifier_token1), 'token1 nullifier');
    assert(pool.get_liquidity() == 110, 'liquidity updated');
}

#[available_gas(max: 100000000)]
#[test]
fn test_liquidity_remove_with_verifier() {
    let (pool, notes, garaga, token0, token1, pool_address, adapter_address, core_address, notes_address) =
        setup_pool_with_verifier();
    let commitment0: felt252 = 6001;
    let commitment1: felt252 = 6002;
    let amount0: u128 = 500;
    let amount1: u128 = 500;

    let outputs0 = build_deposit_outputs(commitment0, amount0, 0);
    garaga.set_outputs(outputs0.span());
    token0.approve(notes_address, u256_from_u128(amount0));
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());

    let outputs1 = build_deposit_outputs(commitment1, amount1, 1);
    garaga.set_outputs(outputs1.span());
    token1.approve(notes_address, u256_from_u128(amount1));
    let _ = notes.deposit_token1(array![].span(), insertion_proof_for_empty_leaf());

    let prev_position_commitment: felt252 = 7001;
    start_cheat_caller_address(notes_address, pool_address);
    let _ = notes.append_position_commitment(
        prev_position_commitment,
        insertion_proof_for_empty_leaf(),
    );
    let root_position = merkle_root_for_single_leaf(prev_position_commitment);

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let adapter_state = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter_state
        .set_pool_state(sqrt_start, 0, 1_u128, 20_u128, u256_from_u128(0), u256_from_u128(0));
    let core = MockCoreExternalDispatcher { contract_address: core_address };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let tick_lower = -120;
    let tick_upper = 120;
    let tick_lower_i128: i128 = tick_lower.try_into().unwrap();
    let tick_upper_i128: i128 = tick_upper.try_into().unwrap();
    let sqrt_ratio_lower = tick_to_sqrt_ratio(tick_lower_i128.into());
    let sqrt_ratio_upper = tick_to_sqrt_ratio(tick_upper_i128.into());
    let nullifier_position: felt252 = 8001;
    let output_commitment_token0: felt252 = 8002;
    let output_commitment_token1: felt252 = 8003;

    let root0 = merkle_root_for_single_leaf(commitment0);
    let root1 = merkle_root_for_single_leaf(commitment1);
    let outputs = build_liquidity_remove_outputs(
        root0,
        root1,
        root_position,
        nullifier_position,
        sqrt_start,
        0,
        tick_lower,
        tick_upper,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        20,
        5,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        prev_position_commitment,
        u256_from_u128(0),
        u256_from_u128(0),
        output_commitment_token0,
        output_commitment_token1,
    );
    garaga.set_outputs(outputs.span());

    let proof_position = merkle_proof_for_single_leaf(root_position, prev_position_commitment);
    let output_proof_token0 = insertion_proof_for_second_leaf(commitment0);
    let output_proof_token1 = insertion_proof_for_second_leaf(commitment1);
    pool.remove_liquidity_private(
        array![].span(),
        proof_position,
        array![].span(),
        array![output_proof_token0].span(),
        array![output_proof_token1].span(),
    );
    assert(notes.is_nullifier_used(nullifier_position), 'position nullifier');
    assert(pool.get_liquidity() == 15, 'liquidity reduced');
}
