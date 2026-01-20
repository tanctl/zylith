#[feature("deprecated_legacy_map")]
use core::traits::TryInto;
use core::serde::Serde;
use snforge_std::{start_cheat_caller_address, test_address};
use starknet::ContractAddress;

use zylith::core::ZylithPool::{ZylithPoolExternalDispatcher, ZylithPoolExternalDispatcherTrait};
use zylith::core::PoolAdapter::IPoolAdapterDispatcher;
use zylith::core::PoolAdapter::IPoolAdapterDispatcherTrait;
use zylith::privacy::ShieldedNotes::MerkleProof;
use zylith::clmm::math::ticks::tick_to_sqrt_ratio;

use crate::common::{deploy_contract_at, u256_from_u128};
use crate::common::mock_proof_generator::{build_swap_outputs, build_swap_outputs_with_steps};
use crate::common::mocks::MockGaragaVerifier::{
    MockGaragaVerifierExternalDispatcher, MockGaragaVerifierExternalDispatcherTrait,
};
use crate::common::mocks::MockPoolAdapter::{
    MockPoolAdapterExternalDispatcher, MockPoolAdapterExternalDispatcherTrait,
};

fn set_adapter_state(
    adapter_address: ContractAddress,
    pool_address: ContractAddress,
    sqrt_price: u256,
    tick: i32,
    liquidity: u128,
) {
    let adapter = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter.set_pool_state(
        sqrt_price,
        tick,
        1_u128,
        liquidity,
        u256_from_u128(0),
        u256_from_u128(0),
    );
}

fn setup_swap_env() -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress, ContractAddress) {
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

    (pool, adapter_address, garaga_address, pool_address)
}

fn dummy_proof(root: felt252, commitment: felt252) -> MerkleProof {
    let path: Array<felt252> = array![];
    let indices: Array<bool> = array![];
    MerkleProof { root, commitment, leaf_index: 0, path: path.span(), indices: indices.span() }
}

fn output_proofs_for_commitment(commitment: felt252) -> Array<MerkleProof> {
    if commitment == 0 {
        array![]
    } else {
        array![dummy_proof(0, 0)]
    }
}

#[test]
fn test_swap_exact_input_single_step() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        111, 999, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        777, 0, false, true, 555, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(111, 555);
    let proofs = array![proof];
    let calldata = array![];
    let output_proofs = output_proofs_for_commitment(777);
    pool.swap_private(calldata.span(), proofs.span(), output_proofs.span());

    assert(pool.get_sqrt_price() == sqrt_end, 'sqrt end');
    assert(pool.get_tick() == -1, 'tick end');
}

#[test]
fn test_swap_exact_input_multi_step() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        222, 1001, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        800, 0, false, true, 600, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(222, 600);
    let proofs = array![proof];
    let calldata = array![];
    let output_proofs = output_proofs_for_commitment(800);
    pool.swap_private(calldata.span(), proofs.span(), output_proofs.span());
}

#[test]
fn test_swap_crossing_ticks() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-2_i128).into());
    let outputs = build_swap_outputs(
        333, 1002, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        801, 0, false, true, 700, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-2);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(333, 700);
    let proofs = array![proof];
    let calldata = array![];
    let output_proofs = output_proofs_for_commitment(801);
    pool.swap_private(calldata.span(), proofs.span(), output_proofs.span());

    assert(pool.get_tick() == -2, 'tick crossed');
}

#[test]
#[should_panic(expected: 'PRICE_BELOW_MIN')]
fn test_swap_price_limits() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = u256_from_u128(0);
    let outputs = build_swap_outputs(
        444, 1003, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        804, 0, false, true, 800, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);
    let proof = dummy_proof(444, 800);
    let proofs = array![proof];
    let output_proofs = output_proofs_for_commitment(804);
    pool.swap_private(array![].span(), proofs.span(), output_proofs.span());
}

#[test]
fn test_swap_with_fees() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        555, 1004, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        900, 0, false, true, 9000, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(555, 9000);
    let proofs = array![proof];
    let output_proofs = output_proofs_for_commitment(900);
    pool.swap_private(array![].span(), proofs.span(), output_proofs.span());
}

#[test]
#[should_panic(expected: 'LIMIT_FLAG_MISMATCH')]
fn test_swap_limit_flag_mismatch() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs_with_steps(
        777,
        7777,
        sqrt_start,
        sqrt_end,
        1000,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        0,
        true,
        true,
        888,
        0,
        1,
        sqrt_end,
        sqrt_start,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(777, 888);
    let proofs = array![proof];
    pool.swap_private(array![].span(), proofs.span(), array![].span());
}

#[test]
#[should_panic(expected: 'LIMIT_FLAG_MISMATCH')]
fn test_swap_limit_flag_missing() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs_with_steps(
        888,
        8888,
        sqrt_start,
        sqrt_end,
        1000,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        0,
        false,
        true,
        999,
        0,
        1,
        sqrt_end,
        sqrt_end,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(888, 999);
    let proofs = array![proof];
    pool.swap_private(array![].span(), proofs.span(), array![].span());
}

#[test]
#[should_panic(expected: 'OUTPUT_PROOF_LEN')]
fn test_swap_output_proof_len_mismatch() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        888,
        8888,
        sqrt_start,
        sqrt_end,
        1000,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        999,
        0,
        false,
        true,
        900,
        0,
        1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(888, 900);
    let proofs = array![proof];
    pool.swap_private(array![].span(), proofs.span(), array![].span());
}

#[test]
#[should_panic(expected: 'NOTE_COUNT_ZERO')]
fn test_swap_rejects_zero_note_count() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        999,
        9999,
        sqrt_start,
        sqrt_end,
        1000,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        0,
        0,
        false,
        true,
        1111,
        0,
        0,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(999, 1111);
    let proofs = array![proof];
    pool.swap_private(array![].span(), proofs.span(), array![].span());
}

#[test]
#[should_panic(expected: 'PROOF_INVALID')]
fn test_swap_reverts_on_invalid_proof() {
    let (pool, _, garaga_address, _) = setup_swap_env();
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_should_verify(false);
    let proof = dummy_proof(1, 1);
    let proofs = array![proof];
    pool.swap_private(array![].span(), proofs.span(), array![].span());
}

#[test]
#[should_panic(expected: 'NULLIFIER_USED')]
fn test_swap_reverts_on_used_nullifier() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        666, 9999, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        802, 0, false, true, 901, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(-1);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, 1000);

    let proof = dummy_proof(666, 901);
    let proofs = array![proof];
    let output_proofs = output_proofs_for_commitment(802);
    pool.swap_private(array![].span(), proofs.span(), output_proofs.span());

    let sqrt_end_second = tick_to_sqrt_ratio((-2_i128).into());
    let outputs_second = build_swap_outputs(
        666, 9999, sqrt_end, sqrt_end_second, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        802, 0, false, true, 901, 0, 1,
    );
    verifier.set_outputs(outputs_second.span());
    let output_proofs = output_proofs_for_commitment(802);
    pool.swap_private(array![].span(), proofs.span(), output_proofs.span());
}

#[test]
#[should_panic(expected: 'PRICE_MISMATCH')]
fn test_swap_reverts_on_price_mismatch() {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = tick_to_sqrt_ratio((-1_i128).into());
    let outputs = build_swap_outputs(
        777, 1005, sqrt_start, sqrt_end, 1000, 30, u256_from_u128(0), u256_from_u128(0),
        803, 0, false, true, 902, 0, 1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter
        .set_pool_state(u256_from_u128(999), 0, 1_u128, 1000, u256_from_u128(0), u256_from_u128(0));

    let proof = dummy_proof(777, 902);
    let proofs = array![proof];
    let output_proofs = output_proofs_for_commitment(803);
    pool.swap_private(array![].span(), proofs.span(), output_proofs.span());
}

#[fuzzer(runs: 24)]
#[test]
fn test_swap_fuzz_basic(seed: u128) {
    let (pool, adapter_address, garaga_address, pool_address) = setup_swap_env();
    let zero_for_one = (seed % 2) == 0;
    let sqrt_start = tick_to_sqrt_ratio(0_i128.into());
    let sqrt_end = if zero_for_one {
        tick_to_sqrt_ratio((-1_i128).into())
    } else {
        tick_to_sqrt_ratio((1_i128).into())
    };
    let liquidity_before = seed % 1000;
    let commitment_in: felt252 = (seed % 100000 + 1).into();
    let nullifier: felt252 = (seed % 100000 + 2).into();
    let output_commitment: felt252 =
        if liquidity_before == 0 { 0 } else { (seed % 100000 + 3).into() };
    let token_id_in: felt252 = if zero_for_one { 0 } else { 1 };
    let outputs = build_swap_outputs(
        111,
        nullifier,
        sqrt_start,
        sqrt_end,
        liquidity_before,
        30,
        u256_from_u128(0),
        u256_from_u128(0),
        output_commitment,
        0,
        false,
        zero_for_one,
        commitment_in,
        token_id_in,
        1,
    );
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };
    verifier.set_outputs(outputs.span());

    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    let next_tick = if zero_for_one { -1 } else { 1 };
    adapter.set_next_tick(next_tick);
    set_adapter_state(adapter_address, pool_address, sqrt_start, 0, liquidity_before);

    let proof = dummy_proof(111, commitment_in);
    let output_proofs = output_proofs_for_commitment(output_commitment);
    pool.swap_private(array![].span(), array![proof].span(), output_proofs.span());
}
