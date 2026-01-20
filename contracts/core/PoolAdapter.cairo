// adapter over the vendored clmm core using a dispatcher to the core contract.
use starknet::ContractAddress;

#[starknet::interface]
pub trait IPoolAdapter<TContractState> {
    fn get_core_address(self: @TContractState) -> ContractAddress;
    fn get_authorized_pool(self: @TContractState) -> ContractAddress;
    fn set_authorized_pool(ref self: TContractState, authorized_pool: ContractAddress);
    fn get_sqrt_price(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);

    fn set_pool_state(
        ref self: TContractState,
        sqrt_price: u256,
        tick: i32,
        tick_spacing: u128,
        liquidity: u128,
        fee_growth_global_0: u256,
        fee_growth_global_1: u256,
    );

    fn apply_swap_state(ref self: TContractState, public_inputs: Span<u256>);

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

    fn apply_protocol_fee_withdraw(
        ref self: TContractState, token: ContractAddress, amount: u128
    );
}

#[starknet::contract]
pub mod PoolAdapter {
    use core::num::traits::Zero;
    use starknet::{ContractAddress, get_caller_address, get_contract_address};
    use crate::clmm::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use crate::clmm::types::i129::i129;
    use super::IPoolAdapter;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        core_address: ContractAddress,
        authorized_pool: ContractAddress,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core_address: ContractAddress,
        authorized_pool: ContractAddress,
        owner: ContractAddress,
    ) {
        assert(core_address.is_non_zero(), 'CORE_ZERO');
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        self.owner.write(owner);
        self.core_address.write(core_address);
        self.authorized_pool.write(authorized_pool);
    }

    #[abi(embed_v0)]
    impl AdapterImpl of IPoolAdapter<ContractState> {
        fn get_core_address(self: @ContractState) -> ContractAddress {
            self.core_address.read()
        }

        fn get_authorized_pool(self: @ContractState) -> ContractAddress {
            self.authorized_pool.read()
        }

        fn set_authorized_pool(ref self: ContractState, authorized_pool: ContractAddress) {
            assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
            assert(self.authorized_pool.read().is_zero(), 'POOL_ALREADY_SET');
            assert(authorized_pool.is_non_zero(), 'POOL_ZERO');
            self.authorized_pool.write(authorized_pool);
        }

        fn get_sqrt_price(self: @ContractState) -> u256 {
            ICoreDispatcher { contract_address: self.core_address.read() }
                .get_pool_price_single()
                .sqrt_ratio
        }

        fn get_tick(self: @ContractState) -> i32 {
            let tick = ICoreDispatcher { contract_address: self.core_address.read() }
                .get_pool_price_single()
                .tick;
            i129_to_i32(tick)
        }

        fn get_liquidity(self: @ContractState) -> u128 {
            ICoreDispatcher { contract_address: self.core_address.read() }
                .get_pool_liquidity_single()
        }

        fn get_fee_growth_global(self: @ContractState) -> (u256, u256) {
            let fees = ICoreDispatcher { contract_address: self.core_address.read() }
                .get_pool_fees_per_liquidity_single();
            (fees.value0, fees.value1)
        }

        fn set_pool_state(
            ref self: ContractState,
            sqrt_price: u256,
            tick: i32,
            tick_spacing: u128,
            liquidity: u128,
            fee_growth_global_0: u256,
            fee_growth_global_1: u256,
        ) {
            assert(get_caller_address() == self.authorized_pool.read(), 'NOT_AUTHORIZED');
            let tick_i129: i129 = i32_to_i129(tick);
            ICoreDispatcher { contract_address: self.core_address.read() }
                .set_pool_state(
                    sqrt_price,
                    tick_i129,
                    tick_spacing,
                    liquidity,
                    fee_growth_global_0,
                    fee_growth_global_1,
                );
        }

        fn apply_swap_state(ref self: ContractState, public_inputs: Span<u256>) {
            assert(get_caller_address() == self.authorized_pool.read(), 'NOT_AUTHORIZED');
            ICoreDispatcher { contract_address: self.core_address.read() }
                .apply_swap_state(public_inputs);
        }

        fn apply_liquidity_state(
            ref self: ContractState,
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
        ) {
            assert(get_caller_address() == self.authorized_pool.read(), 'NOT_AUTHORIZED');
            // adapter never custodies tokens, forbid using pool/adapter as token addresses
            let adapter_address = get_contract_address();
            let pool_address = self.authorized_pool.read();
            assert(token0 != adapter_address, 'ADAPTER_TOKEN0_FORBIDDEN');
            assert(token1 != adapter_address, 'ADAPTER_TOKEN1_FORBIDDEN');
            assert(token0 != pool_address, 'POOL_TOKEN0_FORBIDDEN');
            assert(token1 != pool_address, 'POOL_TOKEN1_FORBIDDEN');
            ICoreDispatcher { contract_address: self.core_address.read() }
                .apply_liquidity_state(
                    tick_lower,
                    tick_upper,
                    liquidity_delta,
                    fee_growth_global_0,
                    fee_growth_global_1,
                    fee,
                    tick_spacing,
                    protocol_fee_0,
                    protocol_fee_1,
                    token0,
                    token1,
                );
        }

        fn apply_protocol_fee_withdraw(
            ref self: ContractState,
            token: ContractAddress,
            amount: u128,
        ) {
            assert(get_caller_address() == self.authorized_pool.read(), 'NOT_AUTHORIZED');
            if amount == 0 {
                return ();
            }
            let adapter_address = get_contract_address();
            let pool_address = self.authorized_pool.read();
            assert(token != adapter_address, 'ADAPTER_TOKEN_FORBIDDEN');
            assert(token != pool_address, 'POOL_TOKEN_FORBIDDEN');
            ICoreDispatcher { contract_address: self.core_address.read() }
                .apply_protocol_fee_withdraw(token, amount);
        }
    }

    fn i32_to_i129(value: i32) -> i129 {
        let as_i128: i128 = value.into();
        as_i128.into()
    }

    fn i129_to_i32(value: i129) -> i32 {
        let mag_i32: i32 = value.mag.try_into().expect('TICK_RANGE');
        if value.sign & value.mag.is_non_zero() {
            -mag_i32
        } else {
            mag_i32
        }
    }
}
