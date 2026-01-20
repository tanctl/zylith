use core::integer::u256;
use core::num::traits::Zero;
use core::traits::{Into, TryInto};
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};
use starknet::ContractAddress;
use starknet::SyscallResultTrait;
use crate::components::util::serialize;
use crate::interfaces::core::{
    ICoreDispatcher, ICoreDispatcherTrait, SwapParameters, UpdatePositionParameters,
};
use crate::interfaces::upgradeable::IUpgradeableDispatcher;
use crate::tests::mock_erc20::{IMockERC20Dispatcher, MockERC20IERC20ImplTrait};
use crate::tests::mocks::locker::{Action, ActionResult, ICoreLockerDispatcher, ICoreLockerDispatcherTrait};
use crate::types::bounds::Bounds;
use crate::types::delta::Delta;
use crate::types::i129::i129;
use crate::types::keys::PoolKey;

pub const FEE_ONE_PERCENT: u128 = 0x28f5c28f5c28f5c28f5c28f5c28f5c2;
const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

#[derive(Drop, Copy)]
pub struct Deployer {
    nonce: felt252,
}

impl DefaultDeployer of core::traits::Default<Deployer> {
    fn default() -> Deployer {
        ensure_declared();
        Deployer { nonce: 0 }
    }
}

fn ensure_declared() {
    let _ = declare("Core").unwrap();
    let _ = declare("MockERC20Unit").unwrap();
    let _ = declare("CoreLocker").unwrap();
    let _ = declare("MockUpgradeable").unwrap();
}


pub fn default_owner() -> ContractAddress {
    12121212121212.try_into().unwrap()
}


#[derive(Copy, Drop)]
pub struct SetupPoolResult {
    pub token0: IMockERC20Dispatcher,
    pub token1: IMockERC20Dispatcher,
    pub pool_key: PoolKey,
    pub core: ICoreDispatcher,
    pub locker: ICoreLockerDispatcher,
}

#[generate_trait]
pub impl DeployerTraitImpl of DeployerTrait {
    fn get_next_nonce(ref self: Deployer) -> felt252 {
        let nonce = self.nonce;
        self.nonce += 1;
        nonce
    }

    fn deploy_mock_token_with_balance_and_metadata(
        ref self: Deployer,
        owner: ContractAddress,
        starting_balance: u128,
        name: felt252,
        symbol: felt252,
    ) -> IMockERC20Dispatcher {
        let class = declare("MockERC20Unit").unwrap().contract_class();
        let (address, _) = class
            .deploy(@array![owner.into(), starting_balance.into(), name, symbol])
            .unwrap_syscall();
        return IMockERC20Dispatcher { contract_address: address };
    }


    fn deploy_mock_token_with_balance(
        ref self: Deployer, owner: ContractAddress, starting_balance: u128,
    ) -> IMockERC20Dispatcher {
        self.deploy_mock_token_with_balance_and_metadata(owner, starting_balance, '', '')
    }

    fn deploy_mock_token(ref self: Deployer) -> IMockERC20Dispatcher {
        self.deploy_mock_token_with_balance(Zero::zero(), Zero::zero())
    }


    fn deploy_two_mock_tokens(ref self: Deployer) -> (IMockERC20Dispatcher, IMockERC20Dispatcher) {
        let tokenA = self.deploy_mock_token();
        let tokenB = self.deploy_mock_token();
        if (tokenA.contract_address < tokenB.contract_address) {
            (tokenA, tokenB)
        } else {
            (tokenB, tokenA)
        }
    }


    fn deploy_core(ref self: Deployer) -> ICoreDispatcher {
        let class = declare("Core").unwrap().contract_class();
        let (address, _) = class.deploy(@serialize(@default_owner())).unwrap_syscall();
        return ICoreDispatcher { contract_address: address };
    }


    fn deploy_locker(ref self: Deployer, core: ICoreDispatcher) -> ICoreLockerDispatcher {
        let class = declare("CoreLocker").unwrap().contract_class();
        let (address, _) = class.deploy(@serialize(@core)).unwrap_syscall();

        ICoreLockerDispatcher { contract_address: address }
    }


    fn deploy_mock_upgradeable(ref self: Deployer) -> IUpgradeableDispatcher {
        let class = declare("MockUpgradeable").unwrap().contract_class();
        let (address, _) = class.deploy(@serialize(@default_owner())).unwrap_syscall();
        return IUpgradeableDispatcher { contract_address: address };
    }


    fn setup_pool(
        ref self: Deployer,
        fee: u128,
        tick_spacing: u128,
        initial_tick: i129,
        extension: ContractAddress,
    ) -> SetupPoolResult {
        let core = self.deploy_core();
        let locker = self.deploy_locker(core);
        let (token0, token1) = self.deploy_two_mock_tokens();

        let pool_key = PoolKey {
            token0: token0.contract_address,
            token1: token1.contract_address,
            fee,
            tick_spacing,
            extension,
        };

        core.initialize_pool(pool_key, initial_tick);

        SetupPoolResult { token0, token1, pool_key, core, locker }
    }

    fn setup_pool_with_core(
        ref self: Deployer,
        core: ICoreDispatcher,
        fee: u128,
        tick_spacing: u128,
        initial_tick: i129,
        extension: ContractAddress,
    ) -> SetupPoolResult {
        let locker = self.deploy_locker(core);
        let (token0, token1) = self.deploy_two_mock_tokens();

        let pool_key = PoolKey {
            token0: token0.contract_address,
            token1: token1.contract_address,
            fee,
            tick_spacing,
            extension,
        };

        core.initialize_pool(pool_key, initial_tick);

        SetupPoolResult { token0, token1, pool_key, core, locker }
    }
}


#[derive(Drop, Copy)]
pub struct Balances {
    token0_balance_core: u256,
    token1_balance_core: u256,
    token0_balance_recipient: u256,
    token1_balance_recipient: u256,
    token0_balance_locker: u256,
    token1_balance_locker: u256,
}
fn get_balances(
    token0: IMockERC20Dispatcher,
    token1: IMockERC20Dispatcher,
    core: ICoreDispatcher,
    locker: ICoreLockerDispatcher,
    recipient: ContractAddress,
) -> Balances {
    let token0_balance_core = token0.balanceOf(core.contract_address);
    let token1_balance_core = token1.balanceOf(core.contract_address);
    let token0_balance_recipient = token0.balanceOf(recipient);
    let token1_balance_recipient = token1.balanceOf(recipient);
    let token0_balance_locker = token0.balanceOf(locker.contract_address);
    let token1_balance_locker = token1.balanceOf(locker.contract_address);
    Balances {
        token0_balance_core,
        token1_balance_core,
        token0_balance_recipient,
        token1_balance_recipient,
        token0_balance_locker,
        token1_balance_locker,
    }
}


pub fn diff(x: u256, y: u256) -> i129 {
    let (lower, upper) = if x < y {
        (x, y)
    } else {
        (y, x)
    };
    let diff = upper - lower;
    assert(diff.high == 0, 'diff_overflow');
    i129 { mag: diff.low, sign: (x < y) & (diff != 0) }
}

pub fn i129_to_signed_u256(value: i129) -> u256 {
    if value.mag.is_zero() {
        u256 { low: 0, high: 0 }
    } else if value.sign {
        u256 { low: (MAX_U128 - value.mag) + 1, high: 0 }
    } else {
        u256 { low: value.mag, high: 0 }
    }
}

pub fn assert_balances_delta(before: Balances, after: Balances, delta: Delta) {
    assert(
        diff(after.token0_balance_core, before.token0_balance_core) == delta.amount0,
        'token0_balance_core',
    );
    assert(
        diff(after.token1_balance_core, before.token1_balance_core) == delta.amount1,
        'token1_balance_core',
    );

    if (delta.amount0.sign) {
        assert(
            diff(after.token0_balance_recipient, before.token0_balance_recipient) == -delta.amount0,
            'token0_balance_recipient',
        );
    } else {
        assert(
            diff(after.token0_balance_locker, before.token0_balance_locker) == -delta.amount0,
            'token0_balance_locker',
        );
    }
    if (delta.amount1.sign) {
        assert(
            diff(after.token1_balance_recipient, before.token1_balance_recipient) == -delta.amount1,
            'token1_balance_recipient',
        );
    } else {
        assert(
            diff(after.token1_balance_locker, before.token1_balance_locker) == -delta.amount1,
            'token1_balance_locker',
        );
    }
}

pub fn update_position_inner(
    core: ICoreDispatcher,
    pool_key: PoolKey,
    locker: ICoreLockerDispatcher,
    bounds: Bounds,
    liquidity_delta: i129,
    recipient: ContractAddress,
) -> Delta {
    assert(recipient != core.contract_address, 'recipient is core');
    assert(recipient != locker.contract_address, 'recipient is locker');

    let before: Balances = get_balances(
        token0: IMockERC20Dispatcher { contract_address: pool_key.token0 },
        token1: IMockERC20Dispatcher { contract_address: pool_key.token1 },
        core: core,
        locker: locker,
        recipient: recipient,
    );
    match locker
        .call(
            Action::UpdatePosition(
                (
                    pool_key,
                    UpdatePositionParameters {
                        bounds,
                        liquidity_delta: i129_to_signed_u256(liquidity_delta),
                        salt: 0,
                    },
                    recipient,
                ),
            ),
        ) {
        ActionResult::UpdatePosition(delta) => {
            let after: Balances = get_balances(
                token0: IMockERC20Dispatcher { contract_address: pool_key.token0 },
                token1: IMockERC20Dispatcher { contract_address: pool_key.token1 },
                core: core,
                locker: locker,
                recipient: recipient,
            );
            assert_balances_delta(before, after, delta);
            delta
        },
        _ => {
            assert(false, 'unexpected');
            Zero::zero()
        },
    }
}

pub fn flash_borrow_inner(
    core: ICoreDispatcher,
    locker: ICoreLockerDispatcher,
    token: ContractAddress,
    amount_borrow: u128,
    amount_repay: u128,
) {
    match locker.call(Action::FlashBorrow((token, amount_borrow, amount_repay))) {
        ActionResult::FlashBorrow(_) => {},
        _ => { assert(false, 'expected flash borrow'); },
    }
}

pub fn update_position(
    setup: SetupPoolResult, bounds: Bounds, liquidity_delta: i129, recipient: ContractAddress,
) -> Delta {
    update_position_inner(
        setup.core,
        setup.pool_key,
        setup.locker,
        bounds: bounds,
        liquidity_delta: liquidity_delta,
        recipient: recipient,
    )
}


pub fn accumulate_as_fees(setup: SetupPoolResult, amount0: u128, amount1: u128) {
    accumulate_as_fees_inner(setup.core, setup.pool_key, setup.locker, amount0, amount1)
}

pub fn accumulate_as_fees_inner(
    core: ICoreDispatcher,
    pool_key: PoolKey,
    locker: ICoreLockerDispatcher,
    amount0: u128,
    amount1: u128,
) {
    match locker.call(Action::AccumulateAsFees((pool_key, amount0, amount1))) {
        ActionResult::AccumulateAsFees => {},
        _ => { assert(false, 'unexpected') },
    }
}

pub fn swap_inner(
    core: ICoreDispatcher,
    pool_key: PoolKey,
    locker: ICoreLockerDispatcher,
    amount: i129,
    is_token1: bool,
    sqrt_ratio_limit: u256,
    recipient: ContractAddress,
    skip_ahead: u128,
) -> Delta {
    let before: Balances = get_balances(
        token0: IMockERC20Dispatcher { contract_address: pool_key.token0 },
        token1: IMockERC20Dispatcher { contract_address: pool_key.token1 },
        core: core,
        locker: locker,
        recipient: recipient,
    );

    match locker
        .call(
            Action::Swap(
                (
                    pool_key,
                    SwapParameters { amount, is_token1, sqrt_ratio_limit, skip_ahead },
                    recipient,
                ),
            ),
        ) {
        ActionResult::Swap(delta) => {
            let after: Balances = get_balances(
                token0: IMockERC20Dispatcher { contract_address: pool_key.token0 },
                token1: IMockERC20Dispatcher { contract_address: pool_key.token1 },
                core: core,
                locker: locker,
                recipient: recipient,
            );
            assert_balances_delta(before, after, delta);
            delta
        },
        _ => {
            assert(false, 'unexpected');
            Zero::zero()
        },
    }
}

pub fn swap(
    setup: SetupPoolResult,
    amount: i129,
    is_token1: bool,
    sqrt_ratio_limit: u256,
    recipient: ContractAddress,
    skip_ahead: u128,
) -> Delta {
    swap_inner(
        setup.core,
        setup.pool_key,
        setup.locker,
        amount,
        is_token1,
        sqrt_ratio_limit,
        recipient,
        skip_ahead,
    )
}
