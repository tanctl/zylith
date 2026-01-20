use core::integer::u256;
use core::num::traits::Zero;
use core::option::OptionTrait;
use core::traits::TryInto;
use starknet::ContractAddress;
use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
use crate::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
use crate::math::ticks::{
    constants as tick_constants, max_tick, min_tick, tick_to_sqrt_ratio,
};
use crate::tests::helper::{
    Deployer, DeployerTrait, FEE_ONE_PERCENT, default_owner, i129_to_signed_u256,
};
use crate::types::i129::i129;
use crate::types::keys::{PoolKey, SavedBalanceKey};


// floor(log base 1.000001 of 1.01)
const TICKS_IN_ONE_PERCENT: u128 = 9950;

#[derive(Copy, Drop)]
struct ShieldedSetup {
    core: ICoreDispatcher,
    pool_key: PoolKey,
    token0: ContractAddress,
    token1: ContractAddress,
    adapter: ContractAddress,
}

fn u256_from_u128(value: u128) -> u256 {
    u256 { low: value, high: 0 }
}

fn i129_from_i32(value: i32) -> i129 {
    if value < 0 {
        i129 { mag: (-value).try_into().unwrap(), sign: true }
    } else {
        i129 { mag: value.try_into().unwrap(), sign: false }
    }
}

fn setup_shielded_pool(fee: u128, tick_spacing: u128, initial_tick: i129) -> ShieldedSetup {
    let mut d: Deployer = Default::default();
    let core = d.deploy_core();
    let (token0, token1) = d.deploy_two_mock_tokens();
    let pool_key = PoolKey {
        token0: token0.contract_address,
        token1: token1.contract_address,
        fee,
        tick_spacing,
        extension: Zero::zero(),
    };
    let adapter: ContractAddress = 0x1000.try_into().unwrap();

    start_cheat_caller_address(core.contract_address, default_owner());
    core.set_authorized_adapter(adapter);
    stop_cheat_caller_address(core.contract_address);

    start_cheat_caller_address(core.contract_address, adapter);
    core.set_pool_state(
        tick_to_sqrt_ratio(initial_tick),
        initial_tick,
        tick_spacing,
        0,
        u256_from_u128(0),
        u256_from_u128(0),
    );
    stop_cheat_caller_address(core.contract_address);

    ShieldedSetup {
        core,
        pool_key,
        token0: token0.contract_address,
        token1: token1.contract_address,
        adapter,
    }
}

mod owner_tests {
    use crate::components::owned::{IOwnedDispatcher, IOwnedDispatcherTrait};
    use super::{
        Deployer, DeployerTrait, default_owner, start_cheat_caller_address,
        stop_cheat_caller_address,
    };

    #[test]
    fn test_transfer_ownership() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let owned = IOwnedDispatcher { contract_address: core.contract_address };

        assert(owned.get_owner() == default_owner(), 'is default');

        start_cheat_caller_address(core.contract_address, default_owner());
        let new_owner = 123456789.try_into().unwrap();
        owned.transfer_ownership(new_owner);
        stop_cheat_caller_address(core.contract_address);

        assert(owned.get_owner() == new_owner, 'is new owner');
    }
}

mod initialize_pool_tests {
    use crate::math::ticks::constants::MAX_TICK_SPACING;
    use super::{
        Deployer, DeployerTrait, ICoreDispatcherTrait, PoolKey, Zero, i129,
    };

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_direct_call_disabled() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: 0,
            tick_spacing: 1,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, i129 { mag: 1000, sign: true });
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_token_order_same_token() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 1.try_into().unwrap(),
            fee: 0,
            tick_spacing: 1,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_token_order_wrong_order() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 2.try_into().unwrap(),
            token1: 1.try_into().unwrap(),
            fee: 0,
            tick_spacing: 1,
            extension: Zero::zero(),
        };

        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_token_order_zero_token() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: Zero::zero(),
            token1: 1.try_into().unwrap(),
            fee: 0,
            tick_spacing: 1,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_zero_tick_spacing() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: 0,
            tick_spacing: 0,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_succeeds_max_tick_spacing() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: 0,
            tick_spacing: MAX_TICK_SPACING,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_max_tick_spacing_plus_one() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: 0,
            tick_spacing: MAX_TICK_SPACING + 1,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, Zero::zero());
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_initialize_pool_fails_already_initialized() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: 0,
            tick_spacing: 1,
            extension: Zero::zero(),
        };
        core.initialize_pool(pool_key, i129 { mag: 1000, sign: true });
    }

    #[test]
    #[should_panic(expected: ('DIRECT_CALL_DISABLED',))]
    fn test_maybe_initialize_pool_twice() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let pool_key = PoolKey {
            token0: 1.try_into().unwrap(),
            token1: 2.try_into().unwrap(),
            fee: Zero::zero(),
            tick_spacing: 1,
            extension: Zero::zero(),
        };
        let _ = core.maybe_initialize_pool(pool_key, Zero::zero());
    }
}


mod initialized_ticks {
    use super::{
        i129_from_i32, i129_to_signed_u256, setup_shielded_pool, u256_from_u128, FEE_ONE_PERCENT,
        ICoreDispatcherTrait, ShieldedSetup, TICKS_IN_ONE_PERCENT, Zero, i129, max_tick, min_tick,
        start_cheat_caller_address, stop_cheat_caller_address, tick_constants,
    };

    fn apply_liquidity(setup: ShieldedSetup, lower: i32, upper: i32, delta: i129) {
        setup.core.apply_liquidity_state(
            lower,
            upper,
            i129_to_signed_u256(delta),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            0,
            0,
            setup.token0,
            setup.token1,
        );
    }

    #[test]
    #[should_panic(expected: ('PREV_FROM_MIN',))]
    fn test_prev_initialized_tick_min_tick_minus_one() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());
        setup.core.prev_initialized_tick(
            pool_key: setup.pool_key,
            from: min_tick() - i129 { mag: 1, sign: false },
            skip_ahead: 0,
        );
    }

    #[test]
    fn test_prev_initialized_tick_min_tick() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: min_tick(), skip_ahead: 5,
                ) == (min_tick(), false),
            'min tick always limited',
        );
    }

    #[test]
    #[should_panic(expected: ('NEXT_FROM_MAX',))]
    fn test_next_initialized_tick_max_tick() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());
        setup.core.next_initialized_tick(pool_key: setup.pool_key, from: max_tick(), skip_ahead: 0);
    }

    #[test]
    fn test_next_initialized_tick_max_tick_minus_one() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: max_tick() - i129 { mag: 1, sign: false },
                    skip_ahead: 5,
                ) == (max_tick(), false),
            'max tick always limited',
        );
    }

    #[test]
    fn test_next_initialized_tick_exceeds_max_tick_spacing() {
        let setup =
            setup_shielded_pool(FEE_ONE_PERCENT, tick_constants::MAX_TICK_SPACING, Zero::zero());
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 0,
                ) == (max_tick(), false),
            'max tick limited',
        );
    }

    #[test]
    fn test_prev_initialized_tick_exceeds_min_tick_spacing() {
        let setup =
            setup_shielded_pool(FEE_ONE_PERCENT, tick_constants::MAX_TICK_SPACING, Zero::zero());
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 0,
                ) == (i129 { mag: Zero::zero(), sign: false }, false),
            'min tick 0',
        );

        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: i129 { mag: 1, sign: true }, skip_ahead: 0,
                ) == (min_tick(), false),
            'min tick',
        );
    }

    #[test]
    fn test_next_prev_initialized_tick_none_initialized() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());

        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 0,
                ) == (Zero::zero(), false),
            'prev from 0',
        );

        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 2,
                ) == (i129 { mag: 4994900, sign: true }, false),
            'prev from 0, skip 2',
        );

        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 5,
                ) == (i129 { mag: 12487250, sign: true }, false),
            'prev from 0, skip 5',
        );

        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 0,
                ) == (i129 { mag: 2487500, sign: false }, false),
            'next from 0',
        );

        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 1,
                ) == (i129 { mag: 4984950, sign: false }, false),
            'next from 0, skip 1',
        );

        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key, from: Zero::zero(), skip_ahead: 5,
                ) == (i129 { mag: 14974750, sign: false }, false),
            'next from 0, skip 5',
        );
    }

    #[test]
    fn test_next_prev_initialized_tick_several_initialized() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, TICKS_IN_ONE_PERCENT, Zero::zero());
        let spacing: i32 = TICKS_IN_ONE_PERCENT.try_into().unwrap();

        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        apply_liquidity(
            setup,
            -(spacing * 12),
            spacing * 9,
            i129 { mag: 1, sign: false },
        );
        apply_liquidity(
            setup,
            -(spacing * 128),
            spacing * 128,
            i129 { mag: 1, sign: false },
        );
        apply_liquidity(
            setup,
            -(spacing * 154),
            spacing * 200,
            i129 { mag: 1, sign: false },
        );
        stop_cheat_caller_address(setup.core.contract_address);

        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 500)),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 154)), true),
            'next from -500, skip 5',
        );
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 154)),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 128)), true),
            'next from -154, skip 5',
        );
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 128)),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 12)), true),
            'next from -128, skip 5',
        );
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 12)),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 9), true),
            'next from -12, skip 5',
        );
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 9),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 128), true),
            'next from 9, skip 5',
        );
        assert(
            setup
                .core
                .next_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 128),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 200), true),
            'next from 128, skip 5',
        );

        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 500),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 200), true),
            'prev from 500, skip 5',
        );
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 199),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 128), true),
            'prev from 199, skip 5',
        );
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 127),
                    skip_ahead: 5,
                ) == (i129_from_i32(spacing * 9), true),
            'prev from 127, skip 5',
        );
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(spacing * 8),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 12)), true),
            'prev from 8, skip 5',
        );
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 13)),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 128)), true),
            'prev from -13, skip 5',
        );
        assert(
            setup
                .core
                .prev_initialized_tick(
                    pool_key: setup.pool_key,
                    from: i129_from_i32(-(spacing * 129)),
                    skip_ahead: 5,
                ) == (i129_from_i32(-(spacing * 154)), true),
            'prev from -129, skip 5',
        );
    }
}


mod shielded_mode {
    use super::{
        i129_to_signed_u256, setup_shielded_pool, u256_from_u128, Deployer, DeployerTrait,
        FEE_ONE_PERCENT, ICoreDispatcherTrait, Zero, default_owner, i129, start_cheat_caller_address,
        stop_cheat_caller_address, tick_to_sqrt_ratio,
    };
    use core::array::ArrayTrait;
    use core::traits::TryInto;
    use starknet::ContractAddress;

    #[test]
    #[should_panic(expected: ('NOT_AUTHORIZED',))]
    fn test_set_pool_state_requires_authorized_adapter() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        let adapter: ContractAddress = 0x1000.try_into().unwrap();
        let attacker: ContractAddress = 0x2000.try_into().unwrap();

        start_cheat_caller_address(core.contract_address, default_owner());
        core.set_authorized_adapter(adapter);
        stop_cheat_caller_address(core.contract_address);

        start_cheat_caller_address(core.contract_address, attacker);
        core.set_pool_state(
            tick_to_sqrt_ratio(Zero::zero()),
            Zero::zero(),
            1,
            0,
            u256_from_u128(0),
            u256_from_u128(0),
        );
    }

    #[test]
    #[should_panic(expected: ('LIQ_DELTA_ZERO',))]
    fn test_apply_liquidity_state_rejects_zero_delta() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_liquidity_state(
            -60,
            60,
            u256_from_u128(0),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            0,
            0,
            setup.token0,
            setup.token1,
        );
    }

    #[test]
    #[should_panic(expected: ('INVALID_TICKS',))]
    fn test_apply_liquidity_state_rejects_invalid_ticks() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_liquidity_state(
            0,
            0,
            i129_to_signed_u256(Zero::zero()),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            0,
            0,
            setup.token0,
            setup.token1,
        );
    }

    #[test]
    #[should_panic(expected: ('TICK_LOWER_ALIGNMENT',))]
    fn test_apply_liquidity_state_rejects_tick_lower_alignment() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_liquidity_state(
            1,
            60,
            i129_to_signed_u256(i129 { mag: 1, sign: false }),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            0,
            0,
            setup.token0,
            setup.token1,
        );
    }

    #[test]
    #[should_panic(expected: ('TICK_UPPER_ALIGNMENT',))]
    fn test_apply_liquidity_state_rejects_tick_upper_alignment() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_liquidity_state(
            0,
            1,
            i129_to_signed_u256(i129 { mag: 1, sign: false }),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            0,
            0,
            setup.token0,
            setup.token1,
        );
    }

    #[test]
    fn test_apply_liquidity_state_updates_protocol_fees() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_liquidity_state(
            -60,
            60,
            i129_to_signed_u256(i129 { mag: 1, sign: false }),
            u256_from_u128(0),
            u256_from_u128(0),
            setup.pool_key.fee,
            setup.pool_key.tick_spacing,
            7,
            11,
            setup.token0,
            setup.token1,
        );
        stop_cheat_caller_address(setup.core.contract_address);

        assert(
            setup.core.get_protocol_fees_collected(setup.token0) == 7,
            'protocol fee token0',
        );
        assert(
            setup.core.get_protocol_fees_collected(setup.token1) == 11,
            'protocol fee token1',
        );
    }

    #[test]
    #[should_panic(expected: ('SWAP_INPUTS_LEN',))]
    fn test_apply_swap_state_rejects_bad_len() {
        let setup = setup_shielded_pool(FEE_ONE_PERCENT, 60, Zero::zero());
        let mut public_inputs = array![];
        start_cheat_caller_address(setup.core.contract_address, setup.adapter);
        setup.core.apply_swap_state(public_inputs.span());
    }
}



mod save_load_tests {
    use super::{Deployer, DeployerTrait, ICoreDispatcherTrait, SavedBalanceKey};
    use core::traits::TryInto;

    #[test]
    #[should_panic(expected: ('DISABLED_IN_SHIELDED_MODE',))]
    fn test_save_disabled_in_shielded_mode() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        core.save(
            SavedBalanceKey {
                owner: 1.try_into().unwrap(),
                token: 2.try_into().unwrap(),
                salt: 3,
            },
            1,
        );
    }

    #[test]
    #[should_panic(expected: ('DISABLED_IN_SHIELDED_MODE',))]
    fn test_load_disabled_in_shielded_mode() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        core.load(2.try_into().unwrap(), 3, 1);
    }

    #[test]
    #[should_panic(expected: ('DISABLED_IN_SHIELDED_MODE',))]
    fn test_get_saved_balance_disabled_in_shielded_mode() {
        let mut d: Deployer = Default::default();
        let core = d.deploy_core();
        core.get_saved_balance(
            SavedBalanceKey {
                owner: 1.try_into().unwrap(),
                token: 2.try_into().unwrap(),
                salt: 3,
            },
        );
    }
}
