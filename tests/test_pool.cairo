#[feature("deprecated_legacy_map")]
use core::traits::TryInto;
use core::serde::Serde;
use snforge_std::{start_cheat_caller_address, test_address};
use starknet::ContractAddress;

use zylith::core::ZylithPool::{ZylithPoolExternalDispatcher, ZylithPoolExternalDispatcherTrait};
use zylith::core::PoolAdapter::IPoolAdapterDispatcher;
use zylith::core::PoolAdapter::IPoolAdapterDispatcherTrait;
use zylith::clmm::math::ticks::tick_to_sqrt_ratio;

use crate::common::{deploy_contract_at, u256_from_u128};
use crate::common::mocks::MockPoolAdapter::{
    MockPoolAdapterExternalDispatcher, MockPoolAdapterExternalDispatcherTrait,
};

fn setup_pool() -> (ZylithPoolExternalDispatcher, ContractAddress, ContractAddress) {
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

    (pool, adapter_address, pool_address)
}

#[test]
fn test_initialize_pool() {
    let (pool, _, _) = setup_pool();
    let state = pool.get_pool_state();
    let expected = tick_to_sqrt_ratio(0_i128.into());
    assert(state.sqrt_price == expected, 'sqrt price mismatch');
    assert(state.tick == 0, 'tick mismatch');
    assert(state.liquidity == 0, 'liquidity mismatch');
}

#[test]
fn test_initialize_pool_sets_tick_spacing() {
    let (_, adapter_address, _) = setup_pool();
    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    let spacing = adapter.get_last_tick_spacing();
    assert(spacing == 1, 'tick spacing');
}

#[test]
fn test_pool_state_updates() {
    let (pool, adapter_address, pool_address) = setup_pool();
    let adapter = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter
        .set_pool_state(u256_from_u128(5), 5, 1_u128, 100, u256_from_u128(1), u256_from_u128(2));
    let state = pool.get_pool_state();
    assert(state.sqrt_price.low == 5, 'sqrt price update');
    assert(state.tick == 5, 'tick update');
    assert(state.liquidity == 100, 'liquidity update');
}

#[test]
fn test_fee_growth_tracking() {
    let (pool, adapter_address, pool_address) = setup_pool();
    let adapter = IPoolAdapterDispatcher { contract_address: adapter_address };
    start_cheat_caller_address(adapter_address, pool_address);
    adapter
        .set_pool_state(u256_from_u128(7), 0, 1_u128, 0, u256_from_u128(9), u256_from_u128(11));
    let (fee0, fee1) = pool.get_fee_growth_global();
    assert(fee0.low == 9, 'fee0 mismatch');
    assert(fee1.low == 11, 'fee1 mismatch');
}

#[test]
fn test_tick_crossing() {
    let (pool, adapter_address, pool_address) = setup_pool();
    let adapter = MockPoolAdapterExternalDispatcher { contract_address: adapter_address };
    adapter.set_next_tick(12);
    start_cheat_caller_address(adapter_address, pool_address);
    let adapter_core = IPoolAdapterDispatcher { contract_address: adapter_address };
    adapter_core
        .set_pool_state(u256_from_u128(3), 12, 1_u128, 0, u256_from_u128(0), u256_from_u128(0));
    assert(pool.get_tick() == 12, 'tick crossing');
}
