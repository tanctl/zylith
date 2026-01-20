#[feature("deprecated_legacy_map")]
use core::serde::Serde;
use core::array::ArrayTrait;
use core::traits::TryInto;
use snforge_std::{start_cheat_caller_address, test_address};
use starknet::ContractAddress;

use zylith::core::ZylithPool::{ZylithPoolExternalDispatcher, ZylithPoolExternalDispatcherTrait};
use zylith::core::PoolAdapter::IPoolAdapterDispatcher;
use zylith::core::PoolAdapter::IPoolAdapterDispatcherTrait;
use zylith::clmm::math::ticks::{tick_to_sqrt_ratio};
use zylith::clmm::math::ticks::constants::MAX_TICK_MAGNITUDE;
use zylith::privacy::ShieldedNotes::MerkleProof;

use crate::common::{deploy_contract_at, u256_from_u128};
use crate::common::mock_proof_generator::{build_liquidity_add_outputs, build_liquidity_remove_outputs};
use crate::common::mocks::MockGaragaVerifier::{
    MockGaragaVerifierExternalDispatcher, MockGaragaVerifierExternalDispatcherTrait,
};
use crate::common::mocks::MockShieldedNotes::{
    MockShieldedNotesAdminDispatcher, MockShieldedNotesAdminDispatcherTrait,
};

fn setup_liquidity_env_with_spacing(
    tick_spacing: i32,
) -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress, ContractAddress) {
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
    tick_spacing.serialize(ref pool_calldata);
    test_address().serialize(ref pool_calldata);
    let _ = deploy_contract_at("ZylithPool", pool_calldata, pool_address);

    let pool = ZylithPoolExternalDispatcher { contract_address: pool_address };
    start_cheat_caller_address(pool_address, test_address());
    pool.initialize(token0, token1, 30, tick_spacing, 0);

    (pool, adapter_address, garaga_address, notes_address)
}

fn setup_liquidity_env() -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress, ContractAddress) {
    setup_liquidity_env_with_spacing(1)
}

fn dummy_proof() -> MerkleProof {
    MerkleProof {
        root: 0,
        commitment: 0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    }
}

fn proofs_for_commitment(commitment: felt252) -> Array<MerkleProof> {
    if commitment == 0 {
        array![]
    } else {
        array![dummy_proof()]
    }
}

#[test]
fn test_add_liquidity_in_range() {
    let (pool, _adapter_address, garaga_address, notes_address) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let input_commitment0: felt252 = 7001;
    let nullifier0: felt252 = 7002;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 901,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let proofs0: Array<MerkleProof> = array![proof0];
    let proofs1: Array<MerkleProof> = array![];
    let proof_pos: Array<MerkleProof> = array![];
    let insert_position = proofs_for_commitment(901);
    let output0 = proofs_for_commitment(0);
    let output1 = proofs_for_commitment(0);
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        proof_pos.span(),
        insert_position.span(),
        output0.span(),
        output1.span(),
    );

    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let (_, _, position_count) = notes_admin.get_commitment_counts();
    assert(position_count == 1, 'position commitment count');
}

#[test]
fn test_add_liquidity_single_sided_token1() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let input_commitment: felt252 = 1001;
    let nullifier: felt252 = 2002;
    let outputs = build_liquidity_add_outputs(
        111,
        222,
        333,
        sqrt_start,
        0,
        tick_lower,
        tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0,
        100,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        911,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        input_commitment,
        0,
        nullifier,
        0,
        0,
        0,
        1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let proof_token1 = MerkleProof {
        root: 222,
        commitment: input_commitment,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let insert_position = proofs_for_commitment(911);
    pool.add_liquidity_private(
        array![].span(),
        array![].span(),
        array![proof_token1].span(),
        array![].span(),
        insert_position.span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
#[should_panic(expected: 'TICK_LOWER_MAX')]
fn test_add_liquidity_out_of_range() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let bad_tick = (MAX_TICK_MAGNITUDE + 1).try_into().unwrap();
    let upper_tick = bad_tick + 1;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, bad_tick, upper_tick,
        sqrt_start,
        sqrt_start,
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 902,
        u256_from_u128(0), u256_from_u128(0),
        0, 0, 0, 0, 0, 0, 0, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());
    let proofs0: Array<MerkleProof> = array![];
    let proofs1: Array<MerkleProof> = array![];
    let proof_pos: Array<MerkleProof> = array![];
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        proof_pos.span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
#[should_panic(expected: 'TICK_LOWER_ALIGNMENT')]
fn test_add_liquidity_tick_alignment() {
    let (pool, _, garaga_address, _) = setup_liquidity_env_with_spacing(2);
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -3;
    let tick_upper = 4;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-3_i128).into()),
        tick_to_sqrt_ratio((4_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 901,
        u256_from_u128(0), u256_from_u128(0),
        0, 0, 0, 0, 0, 0, 0, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    pool.add_liquidity_private(
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
#[should_panic(expected: 'SQRT_LOWER_MISMATCH')]
fn test_add_liquidity_sqrt_ratio_mismatch() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-9_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 901,
        u256_from_u128(0), u256_from_u128(0),
        0, 0, 0, 0, 0, 0, 0, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    pool.add_liquidity_private(
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
#[should_panic(expected: 'IN0_NONZERO')]
fn test_add_liquidity_requires_token0_inputs() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let input_commitment1: felt252 = 4321;
    let nullifier1: felt252 = 8765;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 901,
        u256_from_u128(0), u256_from_u128(0),
        1234, input_commitment1, 5678, nullifier1, 0, 0, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let proof1 = MerkleProof {
        root: 222,
        commitment: input_commitment1,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    pool.add_liquidity_private(
        array![].span(),
        array![].span(),
        array![proof1].span(),
        array![].span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
fn test_remove_liquidity() {
    let (pool, _adapter_address, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let input_commitment0: felt252 = 7011;
    let nullifier0: felt252 = 7012;
    let add_outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 903,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(add_outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let proofs0: Array<MerkleProof> = array![proof0];
    let proofs1: Array<MerkleProof> = array![];
    let proof_pos: Array<MerkleProof> = array![];
    let insert_position = proofs_for_commitment(903);
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        proof_pos.span(),
        insert_position.span(),
        array![].span(),
        array![].span(),
    );

    let remove_outputs = build_liquidity_remove_outputs(
        111, 222, 333, 999, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        100, 50, 30, u256_from_u128(0), u256_from_u128(0), 903,
        u256_from_u128(0), u256_from_u128(0), 0, 0,
    );
    verifier.set_outputs(remove_outputs.span());

    let proof = MerkleProof { root: 333, commitment: 903, leaf_index: 0, path: array![].span(), indices: array![].span() };
    pool.remove_liquidity_private(
        array![].span(),
        proof,
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
fn test_position_fee_accumulation() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -5;
    let tick_upper = 5;
    let fee_inside_0 = u256_from_u128(7);
    let fee_inside_1 = u256_from_u128(9);
    let input_commitment0: felt252 = 7021;
    let nullifier0: felt252 = 7022;
    let outputs = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-5_i128).into()),
        tick_to_sqrt_ratio((5_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 904,
        fee_inside_0, fee_inside_1,
        input_commitment0, 0, nullifier0, 0, 0, 0, 1, 0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(fee_inside_0, fee_inside_1);

    let proof0 = MerkleProof {
        root: 111,
        commitment: input_commitment0,
        leaf_index: 0,
        path: array![].span(),
        indices: array![].span(),
    };
    let proofs0: Array<MerkleProof> = array![proof0];
    let proofs1: Array<MerkleProof> = array![];
    let proof_pos: Array<MerkleProof> = array![];
    let insert_position = proofs_for_commitment(904);
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        proof_pos.span(),
        insert_position.span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
#[should_panic(expected: 'PROOF_INVALID')]
fn test_liquidity_reverts_on_invalid_proof() {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_should_verify(false);
    let proofs0: Array<MerkleProof> = array![];
    let proofs1: Array<MerkleProof> = array![];
    let proof_pos: Array<MerkleProof> = array![];
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        proof_pos.span(),
        array![].span(),
        array![].span(),
        array![].span(),
    );
}

#[test]
fn test_multiple_positions_same_range() {
    let (pool, _, garaga_address, notes_address) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let tick_lower = -10;
    let tick_upper = 10;
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    let input_commitment0_first: felt252 = 7031;
    let nullifier0_first: felt252 = 7032;
    let input_commitment0_second: felt252 = 7033;
    let nullifier0_second: felt252 = 7034;

    let outputs_first = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        0, 100, 30, u256_from_u128(0), u256_from_u128(0), 0, 905,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0_first, 0, nullifier0_first, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs_first.span());
    let insert_first = proofs_for_commitment(905);
    pool.add_liquidity_private(
        array![].span(),
        array![
            MerkleProof {
                root: 111,
                commitment: input_commitment0_first,
                leaf_index: 0,
                path: array![].span(),
                indices: array![].span(),
            }
        ]
            .span(),
        array![].span(),
        array![].span(),
        insert_first.span(),
        array![].span(),
        array![].span(),
    );

    let outputs_second = build_liquidity_add_outputs(
        111, 222, 333, sqrt_start, 0, tick_lower, tick_upper,
        tick_to_sqrt_ratio((-10_i128).into()),
        tick_to_sqrt_ratio((10_i128).into()),
        100, 200, 30, u256_from_u128(0), u256_from_u128(0), 0, 906,
        u256_from_u128(0), u256_from_u128(0),
        input_commitment0_second, 0, nullifier0_second, 0, 0, 0, 1, 0,
    );
    verifier.set_outputs(outputs_second.span());
    let insert_second = proofs_for_commitment(906);
    pool.add_liquidity_private(
        array![].span(),
        array![
            MerkleProof {
                root: 111,
                commitment: input_commitment0_second,
                leaf_index: 0,
                path: array![].span(),
                indices: array![].span(),
            }
        ]
            .span(),
        array![].span(),
        array![].span(),
        insert_second.span(),
        array![].span(),
        array![].span(),
    );

    let notes_admin = MockShieldedNotesAdminDispatcher { contract_address: notes_address };
    let (_, _, position_count) = notes_admin.get_commitment_counts();
    assert(position_count == 2, 'position commitment count');
}

#[fuzzer(runs: 24)]
#[test]
fn test_add_liquidity_fuzz_single_sided(seed: u128) {
    let (pool, _, garaga_address, _) = setup_liquidity_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let offset: i32 = (seed % 5).try_into().unwrap();
    let tick_lower = -10 + offset;
    let tick_upper = tick_lower + 5;
    let liquidity_delta: u128 = (seed % 1000) + 1;
    let use_token0 = (seed % 2) == 0;
    let input_commitment: felt252 = (seed % 100000 + 1).into();
    let nullifier: felt252 = (seed % 100000 + 2).into();
    let position_commitment: felt252 = (920_u128 + (seed % 10)).into();
    let input_commitment_token0 = if use_token0 { input_commitment } else { 0 };
    let input_commitment_token1 = if use_token0 { 0 } else { input_commitment };
    let nullifier_token0 = if use_token0 { nullifier } else { 0 };
    let nullifier_token1 = if use_token0 { 0 } else { nullifier };
    let note_count0: u128 = if use_token0 { 1 } else { 0 };
    let note_count1: u128 = if use_token0 { 0 } else { 1 };
    let tick_lower_i128: i128 = tick_lower.try_into().unwrap();
    let tick_upper_i128: i128 = tick_upper.try_into().unwrap();
    let outputs = build_liquidity_add_outputs(
        111,
        222,
        333,
        sqrt_start,
        0,
        tick_lower,
        tick_upper,
        tick_to_sqrt_ratio(tick_lower_i128.into()),
        tick_to_sqrt_ratio(tick_upper_i128.into()),
        0,
        liquidity_delta,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        position_commitment,
        u256_from_u128(0),
        u256_from_u128(0),
        input_commitment_token0,
        input_commitment_token1,
        nullifier_token0,
        nullifier_token1,
        0,
        0,
        note_count0,
        note_count1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let core = MockCoreExternalDispatcher {
        contract_address: 0x1100.try_into().expect('ADDRESS_RANGE'),
    };
    core.set_fee_inside(u256_from_u128(0), u256_from_u128(0));

    let mut proofs0: Array<MerkleProof> = array![];
    let mut proofs1: Array<MerkleProof> = array![];
    if use_token0 {
        let proof_token0 = MerkleProof {
            root: 111,
            commitment: input_commitment,
            leaf_index: 0,
            path: array![].span(),
            indices: array![].span(),
        };
        proofs0.append(proof_token0);
    } else {
        let proof_token1 = MerkleProof {
            root: 222,
            commitment: input_commitment,
            leaf_index: 0,
            path: array![].span(),
            indices: array![].span(),
        };
        proofs1.append(proof_token1);
    }
    let insert_position = proofs_for_commitment(position_commitment);
    pool.add_liquidity_private(
        array![].span(),
        proofs0.span(),
        proofs1.span(),
        array![].span(),
        insert_position.span(),
        array![].span(),
        array![].span(),
    );
}
