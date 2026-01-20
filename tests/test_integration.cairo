#[feature("deprecated_legacy_map")]
use core::serde::Serde;
use core::traits::TryInto;
use snforge_std::{start_cheat_caller_address, test_address};
use starknet::ContractAddress;

use zylith::core::ZylithPool::{ZylithPoolExternalDispatcher, ZylithPoolExternalDispatcherTrait};
use zylith::core::PoolAdapter::IPoolAdapterDispatcher;
use zylith::core::PoolAdapter::IPoolAdapterDispatcherTrait;
use zylith::clmm::math::ticks::tick_to_sqrt_ratio;
use zylith::clmm::types::i129::i129;
use zylith::privacy::ShieldedNotes::MerkleProof;

use crate::common::{deploy_contract_at, u256_from_u128};
use crate::common::mock_proof_generator::{
    build_swap_outputs, build_swap_outputs_with_extras, build_liquidity_add_outputs,
    build_liquidity_add_outputs_with_notes, build_liquidity_remove_outputs,
};
use crate::common::mocks::MockGaragaVerifier::{
    MockGaragaVerifierExternalDispatcher, MockGaragaVerifierExternalDispatcherTrait,
};
use crate::common::mocks::MockShieldedNotes::{
    MockShieldedNotesCoreDispatcher, MockShieldedNotesCoreDispatcherTrait,
    MockShieldedNotesAdminDispatcher, MockShieldedNotesAdminDispatcherTrait,
};
use crate::common::mocks::MockPoolAdapter::{
    MockPoolAdapterExternalDispatcher, MockPoolAdapterExternalDispatcherTrait,
};

const FEE_ONE_PERCENT: u128 = 0x28f5c28f5c28f5c28f5c28f5c28f5c2;

fn setup_integration_env() -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress, ContractAddress) {
    let pool_address = 0x1000.try_into().expect('ADDRESS_RANGE');
    let core_address = 0x1100.try_into().expect('ADDRESS_RANGE');
    let adapter_address = 0x1200.try_into().expect('ADDRESS_RANGE');
    let notes_address = 0x1300.try_into().expect('ADDRESS_RANGE');
    let garaga_address = 0x1400.try_into().expect('ADDRESS_RANGE');
    let verifier_address = 0x1500.try_into().expect('ADDRESS_RANGE');
    let token0 = 0x2000.try_into().expect('ADDRESS_RANGE');
    let token1 = 0x2100.try_into().expect('ADDRESS_RANGE');
    let mut calldata = array![];
    pool_address.serialize(ref calldata);
    adapter_address.serialize(ref calldata);
    let _ = deploy_contract_at("MockCore", calldata, core_address);

    let mut adapter_calldata = array![];
    core_address.serialize(ref adapter_calldata);
    pool_address.serialize(ref adapter_calldata);
    let _ = deploy_contract_at("MockPoolAdapter", adapter_calldata, adapter_address);

    let mut notes_calldata = array![];
    token0.serialize(ref notes_calldata);
    token1.serialize(ref notes_calldata);
    pool_address.serialize(ref notes_calldata);
    111_u128.serialize(ref notes_calldata);
    222_u128.serialize(ref notes_calldata);
    333_u128.serialize(ref notes_calldata);
    let _ = deploy_contract_at("MockShieldedNotes", notes_calldata, notes_address);

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

    let mut pool_calldata = array![];
    core_address.serialize(ref pool_calldata);
    adapter_address.serialize(ref pool_calldata);
    notes_address.serialize(ref pool_calldata);
    verifier_address.serialize(ref pool_calldata);
    token0.serialize(ref pool_calldata);
    token1.serialize(ref pool_calldata);
    30_u128.serialize(ref pool_calldata);
    1_i32.serialize(ref pool_calldata);
    test_address().serialize(ref pool_calldata);
    let _ = deploy_contract_at("ZylithPool", pool_calldata, pool_address);

    let pool = ZylithPoolExternalDispatcher { contract_address: pool_address };
    start_cheat_caller_address(pool_address, test_address());
    pool.initialize(token0, token1, 30, 1, 0);

    (pool, notes_address, garaga_address, adapter_address)
}

fn setup_integration_env_with_fee(
    fee: u128,
) -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress, ContractAddress) {
    let pool_address = 0x3000.try_into().expect('ADDRESS_RANGE');
    let core_address = 0x3100.try_into().expect('ADDRESS_RANGE');
    let adapter_address = 0x3200.try_into().expect('ADDRESS_RANGE');
    let notes_address = 0x3300.try_into().expect('ADDRESS_RANGE');
    let garaga_address = 0x3400.try_into().expect('ADDRESS_RANGE');
    let verifier_address = 0x3500.try_into().expect('ADDRESS_RANGE');
    let token0 = 0x4000.try_into().expect('ADDRESS_RANGE');
    let token1 = 0x4100.try_into().expect('ADDRESS_RANGE');
    let mut calldata = array![];
    pool_address.serialize(ref calldata);
    adapter_address.serialize(ref calldata);
    let _ = deploy_contract_at("MockCore", calldata, core_address);

    let mut adapter_calldata = array![];
    core_address.serialize(ref adapter_calldata);
    pool_address.serialize(ref adapter_calldata);
    let _ = deploy_contract_at("MockPoolAdapter", adapter_calldata, adapter_address);

    let mut notes_calldata = array![];
    token0.serialize(ref notes_calldata);
    token1.serialize(ref notes_calldata);
    pool_address.serialize(ref notes_calldata);
    111_u128.serialize(ref notes_calldata);
    222_u128.serialize(ref notes_calldata);
    333_u128.serialize(ref notes_calldata);
    let _ = deploy_contract_at("MockShieldedNotes", notes_calldata, notes_address);

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

    let mut pool_calldata = array![];
    core_address.serialize(ref pool_calldata);
    adapter_address.serialize(ref pool_calldata);
    notes_address.serialize(ref pool_calldata);
    verifier_address.serialize(ref pool_calldata);
    token0.serialize(ref pool_calldata);
    token1.serialize(ref pool_calldata);
    fee.serialize(ref pool_calldata);
    1_i32.serialize(ref pool_calldata);
    test_address().serialize(ref pool_calldata);
    let _ = deploy_contract_at("ZylithPool", pool_calldata, pool_address);

    let pool = ZylithPoolExternalDispatcher { contract_address: pool_address };
    start_cheat_caller_address(pool_address, test_address());
    pool.initialize(token0, token1, fee, 1, 0);

    (pool, notes_address, garaga_address, adapter_address)
}

#[available_gas(max: 100000000)]
#[test]
fn test_full_swap_flow() {
    let (pool, notes_address, garaga_address, adapter_address) = setup_integration_env();
    let notes_core = MockShieldedNotesCoreDispatcher { contract_address: notes_address };
    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };

    let commitment_in: felt252 = 1001;
    let dummy_proof = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let _ = notes_core.append_commitment(
        commitment_in,
        0x2000.try_into().expect('ADDRESS_RANGE'),
        dummy_proof,
    );
    let (count0_before, count1_before, _) = notes_admin.get_commitment_counts();

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        111, 5001, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        2002, 0, false, true, commitment_in, 0, 1,
    );
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    let adapter_state = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, 0x1000.try_into().expect('ADDRESS_RANGE'));
    adapter_state
        .set_pool_state(sqrt_start, 0, 1_u128, 1000, u256_from_u128(0), u256_from_u128(0));

    let proof = MerkleProof {
        root: 111,
        commitment: commitment_in,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let output_proof = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.swap_private(array![].span(), array![proof].span(), array![output_proof].span());

    let (count0_after, count1_after, _) = notes_admin.get_commitment_counts();
    assert(count0_after == count0_before, 'token0 count');
    assert(count1_after == (count1_before + 1), 'token1 output');
}

#[available_gas(max: 100000000)]
#[test]
fn test_full_swap_flow_multi_note() {
    let (pool, notes_address, garaga_address, adapter_address) = setup_integration_env();
    let notes_core = MockShieldedNotesCoreDispatcher { contract_address: notes_address };
    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };

    let commitment_in0: felt252 = 1001;
    let commitment_in1: felt252 = 1002;
    let dummy_proof = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let _ = notes_core.append_commitment(
        commitment_in0,
        0x2000.try_into().expect('ADDRESS_RANGE'),
        dummy_proof,
    );
    let _ = notes_core.append_commitment(
        commitment_in1,
        0x2000.try_into().expect('ADDRESS_RANGE'),
        dummy_proof,
    );
    let (count0_before, count1_before, _) = notes_admin.get_commitment_counts();

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs_with_extras(
        111, 5001, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        2002, 0, false, true, commitment_in0, 0, 2,
        array![5002].span(),
        array![commitment_in1].span(),
    );
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    let adapter_state = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, 0x1000.try_into().expect('ADDRESS_RANGE'));
    adapter_state
        .set_pool_state(sqrt_start, 0, 1_u128, 1000, u256_from_u128(0), u256_from_u128(0));

    let proof0 = MerkleProof {
        root: 111,
        commitment: commitment_in0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let proof1 = MerkleProof {
        root: 111,
        commitment: commitment_in1,
        leaf_index: 1,
        path: array![].span(),
        indices: array![].span(),
    };
    let output_proof = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.swap_private(
        array![].span(),
        array![proof0, proof1].span(),
        array![output_proof].span(),
    );

    let (count0_after, count1_after, _) = notes_admin.get_commitment_counts();
    assert(count0_after == count0_before, 'token0 count');
    assert(count1_after == (count1_before + 1), 'token1 output');
}

#[test]
fn test_full_lp_flow() {
    let (pool, notes_address, garaga_address, _) = setup_integration_env();
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let input_commitment0: felt252 = 8001;
    let nullifier0: felt252 = 8002;
    let outputs_add = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio(i129 { mag: 10, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 10, sign: false }),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 3001,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs_add.span());
    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position_proof = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![proof0].span(),
        array![].span(),
        array![].span(),
        array![insert_position_proof].span(),
        array![].span(),
        array![].span(),
    );

    let outputs_remove = build_liquidity_remove_outputs(
        111, 222, 333, 4001, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio(i129 { mag: 10, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 10, sign: false }),
        100, 50, 30, u256_from_u128(0), u256_from_u128(0), 3001,
        u256_from_u128(0), u256_from_u128(0), 0, 0,
    );
    verifier.set_outputs(outputs_remove.span());
    let proof = MerkleProof {
        root: 333,
        commitment: 3001,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.remove_liquidity_private(
        array![].span(),
        proof,
        array![].span(),
        array![].span(),
        array![].span(),
    );

    let (_, _, position_count) = notes_admin.get_commitment_counts();
    assert(position_count == 1, 'position commitment count');
}

#[test]
fn test_full_lp_update_flow() {
    let (pool, notes_address, garaga_address, _) = setup_integration_env();
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let input_commitment0: felt252 = 8301;
    let nullifier0: felt252 = 8302;
    let outputs_add = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio(i129 { mag: 10, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 10, sign: false }),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 7001,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs_add.span());
    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![proof0].span(),
        array![].span(),
        array![].span(),
        array![insert_position].span(),
        array![].span(),
        array![].span(),
    );

    let (count0_mid, count1_mid, position_mid) = notes_admin.get_commitment_counts();

    let input_commitment1: felt252 = 8303;
    let nullifier1: felt252 = 8304;
    let outputs_update = build_liquidity_add_outputs_with_notes(
        111, 222, 333, 9001, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio(i129 { mag: 10, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 10, sign: false }),
        100, 50, 30, u256_from_u128(0), u256_from_u128(0), 7001, 7002,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment1, 0, nullifier1, 0, 0, 0, 1, 0,
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
    verifier.set_outputs(outputs_update.span());
    let proof1 = MerkleProof {
        root: 111,
        commitment: input_commitment1,
        leaf_index: 1,
        path: array![].span(),
        indices: array![].span(),
    };
    let proof_position = MerkleProof {
        root: 333,
        commitment: 7001,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position_update = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![proof1].span(),
        array![].span(),
        array![proof_position].span(),
        array![insert_position_update].span(),
        array![].span(),
        array![].span(),
    );

    let (count0_after, count1_after, position_after) = notes_admin.get_commitment_counts();
    assert(count0_after == count0_mid, 'token0 count');
    assert(count1_after == count1_mid, 'token1 count');
    assert(position_after == (position_mid + 1), 'position commitment count');
}

#[test]
fn test_cross_tick_liquidity() {
    let (pool, _, garaga_address, _) = setup_integration_env();
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let input_commitment0: felt252 = 8101;
    let nullifier0: felt252 = 8102;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, -20, 20,
        tick_to_sqrt_ratio(i129 { mag: 20, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 20, sign: false }),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 4002,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs.span());
    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![proof0].span(),
        array![].span(),
        array![].span(),
        array![insert_position].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
fn test_protocol_fees_collection() {
    let (pool, notes_address, garaga_address, _) = setup_integration_env_with_fee(
        FEE_ONE_PERCENT,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let core = MockCoreExternalDispatcher {
        contract_address: 0x3100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let liquidity_amount: u128 = 1_000_000_000_000;
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let input_commitment0: felt252 = 8201;
    let nullifier0: felt252 = 8202;
    let outputs_add = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio(i129 { mag: 10, sign: true }),
        tick_to_sqrt_ratio(i129 { mag: 10, sign: false }),
        0, liquidity_amount, FEE_ONE_PERCENT, u256_from_u128(0), u256_from_u128(0), 0, 5001,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs_add.span());
    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position = MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![proof0].span(),
        array![].span(),
        array![].span(),
        array![insert_position].span(),
        array![].span(),
        array![].span(),
    );

    let outputs_remove = build_liquidity_remove_outputs(
        111, 222, 333, 6001, sqrt_start, 0, -10, 10,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        liquidity_amount, liquidity_amount, FEE_ONE_PERCENT, u256_from_u128(0), u256_from_u128(0), 5001,
        u256_from_u128(0), u256_from_u128(0), 0, 0,
    );
    verifier.set_outputs(outputs_remove.span());
    let proof = MerkleProof { root: 333, commitment: 5001, leaf_index: 0, path: array![].span(), indices: array![].span() };
    pool.remove_liquidity_private(
        array![].span(),
        proof,
        array![].span(),
        array![].span(),
        array![].span(),
    );

    let (fee0, fee1) = notes_admin.get_protocol_fee_totals();
    assert((fee0 > 0) | (fee1 > 0), 'fees collected');
}
