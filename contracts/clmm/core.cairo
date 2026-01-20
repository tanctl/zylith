#[starknet::contract]
pub mod Core {
    use core::array::{ArrayTrait, SpanTrait};
    use core::num::traits::Zero;
    use core::option::Option;
    use core::traits::{Into, TryInto};
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePathEntry,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use starknet::storage_access::storage_base_address_from_felt252;
    use starknet::{ContractAddress, Store, get_caller_address};
    use crate::interfaces::erc20::{IERC20Dispatcher, IERC20DispatcherTrait};
    use crate::components::owned::Owned as owned_component;
    use crate::components::upgradeable::{IHasInterface, Upgradeable as upgradeable_component};
    use crate::interfaces::core::{
        GetPositionWithFeesResult, ICore, IExtensionDispatcher, IExtensionDispatcherTrait,
        IForwardeeDispatcher, LockerState, SwapParameters,
        UpdatePositionParameters,
    };
    use crate::math::bitmap::{
        Bitmap, BitmapTrait, tick_to_word_and_bit_index, word_and_bit_index_to_tick,
    };
    use crate::math::fee::{accumulate_fee_amount, compute_fee};
    use crate::math::liquidity::liquidity_delta_to_amount_delta;
    use crate::math::swap::{is_price_increasing, swap_result};
    use crate::math::ticks::{
        max_sqrt_ratio, max_tick, min_sqrt_ratio, min_tick, sqrt_ratio_to_tick, tick_to_sqrt_ratio,
    };
    use crate::math::ticks::constants::MAX_TICK_SPACING;
    use crate::constants::generated as generated_constants;
    use crate::types::bounds::{Bounds, BoundsTrait};
    use crate::types::call_points::CallPoints;
    use crate::types::delta::Delta;
    use crate::types::fees_per_liquidity::{
        FeesPerLiquidity, fees_per_liquidity_from_amount0, fees_per_liquidity_from_amount1,
        fees_per_liquidity_new,
    };
    use crate::types::i129::{AddDeltaTrait, i129};
    use crate::types::keys::{PoolKey, PoolKeyTrait, PositionKey, SavedBalanceKey};
    use crate::types::pool_price::PoolPrice;
    use crate::types::position::Position;

    const MAX_SWAP_STEPS: usize = generated_constants::MAX_SWAP_STEPS;
    const MAX_INPUT_NOTES: usize = generated_constants::MAX_INPUT_NOTES;
    const SWAP_PUBLIC_INPUTS_LEN: usize =
        16 + (MAX_SWAP_STEPS * 6) + (2 * (MAX_INPUT_NOTES - 1));
    // protocol invariant: fee growth values must stay within the stark field
    const MAX_FEE_GROWTH: u256 = generated_constants::MAX_FEE_GROWTH;
    const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;
    const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl Ownable = owned_component::OwnableImpl<ContractState>;

    component!(path: upgradeable_component, storage: upgradeable, event: UpgradeableEvent);
    #[abi(embed_v0)]
    impl Upgradeable = upgradeable_component::UpgradeableImpl<ContractState>;

    #[storage]
    pub struct Storage {
        // protocol fee accounting only; custody stays in ShieldedNotes
        pub protocol_fees_collected: Map<ContractAddress, u128>,
        // transient state of the lockers, which always starts and ends at zero
        pub lock_count: u32,
        pub locker_token_deltas: Map<(u32, ContractAddress), i129>,
        // the rest of transient state is accessed directly using Store::read and Store::write to save on hashes

        // adapter allowed to mutate pool state via apply_* proof-driven entrypoints
        pub authorized_adapter: ContractAddress,
        // configured tick spacing for the single pool, set on first liquidity apply and immutable
        pub configured_tick_spacing: u128,
        // configured pool key for the single pool, bound on first use
        pub configured_token0: ContractAddress,
        pub configured_token1: ContractAddress,
        pub configured_fee: u128,
        pub configured_extension: ContractAddress,
        pub fee_bound: bool,
        pub extension_bound: bool,
        // the persistent state of the single pool is stored in these structs
        pub pool_price: PoolPrice,
        pub pool_liquidity: u128,
        pub pool_fees: FeesPerLiquidity,
        pub tick_liquidity_net: Map<i129, u128>,
        pub tick_liquidity_delta: Map<i129, i129>,
        pub tick_fees_outside: Map<i129, FeesPerLiquidity>,
        // only aggregate tick liquidity on-chain, per user positions are tracked off chain via commitments and direct position updates are disabled
        pub positions: Map<(PoolKey, PositionKey), Position>,
        pub tick_bitmaps: Map<u128, Bitmap>,
        // users may save balances in the singleton to avoid transfers, keyed by (owner, token, cache_key)
        pub saved_balances: Map<SavedBalanceKey, u128>,
        // extensions must be registered before they are used in a pool key
        pub extension_call_points: Map<ContractAddress, CallPoints>,
        #[substorage(v0)]
        upgradeable: upgradeable_component::Storage,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[constructor]
    fn constructor(ref self: ContractState, owner: ContractAddress) {
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        self.initialize_owned(owner);
        self.authorized_adapter.write(Zero::zero());
        self.configured_tick_spacing.write(Zero::zero());
        self.configured_token0.write(Zero::zero());
        self.configured_token1.write(Zero::zero());
        self.configured_fee.write(Zero::zero());
        self.configured_extension.write(Zero::zero());
        self.fee_bound.write(false);
        self.extension_bound.write(false);
    }

    #[derive(starknet::Event, Drop)]
    pub struct ProtocolFeesWithdrawn {
        pub recipient: ContractAddress,
        pub token: ContractAddress,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct ProtocolFeesPaid {
        pub pool_key: PoolKey,
        pub position_key: PositionKey,
        pub delta: Delta,
    }

    #[derive(starknet::Event, Drop)]
    pub struct PoolInitialized {
        pub pool_key: PoolKey,
        pub initial_tick: i129,
        pub sqrt_ratio: u256,
    }

    #[derive(starknet::Event, Drop)]
    pub struct PositionUpdated {
        pub locker: ContractAddress,
        pub pool_key: PoolKey,
        pub params: UpdatePositionParameters,
        pub delta: Delta,
    }

    #[derive(starknet::Event, Drop)]
    pub struct PositionFeesCollected {
        pub pool_key: PoolKey,
        pub position_key: PositionKey,
        pub delta: Delta,
    }

    #[derive(starknet::Event, Drop)]
    pub struct Swapped {
        pub locker: ContractAddress,
        pub pool_key: PoolKey,
        pub params: SwapParameters,
        pub delta: Delta,
        pub sqrt_ratio_after: u256,
        pub tick_after: i129,
        pub liquidity_after: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct FeesAccumulated {
        pub pool_key: PoolKey,
        pub amount0: u128,
        pub amount1: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct SavedBalance {
        pub key: SavedBalanceKey,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    pub struct LoadedBalance {
        pub key: SavedBalanceKey,
        pub amount: u128,
    }

    #[derive(starknet::Event, Drop)]
    #[event]
    enum Event {
        #[flat]
        UpgradeableEvent: upgradeable_component::Event,
        OwnedEvent: owned_component::Event,
        ProtocolFeesPaid: ProtocolFeesPaid,
        ProtocolFeesWithdrawn: ProtocolFeesWithdrawn,
        PoolInitialized: PoolInitialized,
        PositionUpdated: PositionUpdated,
        PositionFeesCollected: PositionFeesCollected,
        Swapped: Swapped,
        SavedBalance: SavedBalance,
        LoadedBalance: LoadedBalance,
        FeesAccumulated: FeesAccumulated,
    }

    #[generate_trait]
    impl Internal of InternalTrait {
        fn get_current_locker_id(self: @ContractState) -> u32 {
            let lock_count = self.lock_count.read();
            assert(lock_count > 0, 'NOT_LOCKED');
            lock_count - 1
        }

        fn get_locker_address(self: @ContractState, id: u32) -> ContractAddress {
            Store::read(0, storage_base_address_from_felt252(id.into()))
                .expect('FAILED_READ_LOCKER_ADDRESS')
        }

        fn set_locker_address(self: @ContractState, id: u32, address: ContractAddress) {
            Store::write(0, storage_base_address_from_felt252(id.into()), address)
                .expect('FAILED_WRITE_LOCKER_ADDRESS');
        }

        fn get_nonzero_delta_count(self: @ContractState, id: u32) -> u32 {
            Store::read(0, storage_base_address_from_felt252(0x100000000 + id.into()))
                .expect('FAILED_READ_NZD_COUNT')
        }

        fn crement_storage_delta_count(self: @ContractState, id: u32, decrease: bool) {
            let delta_count_storage_location = storage_base_address_from_felt252(
                0x100000000 + id.into(),
            );

            let count = Store::read(0, delta_count_storage_location)
                .expect('FAILED_READ_NZD_COUNT');

            Store::write(
                0, delta_count_storage_location, if decrease {
                    count - 1
                } else {
                    count + 1
                },
            )
                .expect('FAILED_WRITE_NZD_COUNT');
        }

        fn get_locker(self: @ContractState) -> (u32, ContractAddress) {
            let id = self.get_current_locker_id();
            let locker = self.get_locker_address(id);
            (id, locker)
        }

        fn require_locker(self: @ContractState) -> (u32, ContractAddress) {
            let (id, locker) = self.get_locker();
            assert(locker == get_caller_address(), 'NOT_LOCKER');
            (id, locker)
        }

        fn account_delta(
            ref self: ContractState, id: u32, token_address: ContractAddress, delta: i129,
        ) {
            let delta_storage_location = self.locker_token_deltas.entry((id, token_address));
            let current = delta_storage_location.read();
            let next = current + delta;
            delta_storage_location.write(next);

            let next_is_zero = next.is_zero();

            if (current.is_zero() != next_is_zero) {
                self.crement_storage_delta_count(id, next_is_zero);
            }
        }

        fn account_pool_delta(ref self: ContractState, id: u32, pool_key: PoolKey, delta: Delta) {
            self.account_delta(id, pool_key.token0, delta.amount0);
            self.account_delta(id, pool_key.token1, delta.amount1);
        }

        // remove the initialized tick for the pool
        fn remove_initialized_tick(ref self: ContractState, index: i129, tick_spacing: u128) {
            let (word_index, bit_index) = tick_to_word_and_bit_index(index, tick_spacing);
            let bitmap_entry = self.tick_bitmaps.entry(word_index);
            let bitmap = bitmap_entry.read();
            // it is assumed that bitmap already contains the set bit exp2(bit_index)
            bitmap_entry.write(bitmap.unset_bit(bit_index));
        }

        // insert an initialized tick for the pool
        fn insert_initialized_tick(ref self: ContractState, index: i129, tick_spacing: u128) {
            let (word_index, bit_index) = tick_to_word_and_bit_index(index, tick_spacing);
            let bitmap_entry = self.tick_bitmaps.entry(word_index);
            let bitmap = bitmap_entry.read();
            // it is assumed that bitmap does not contain the set bit exp2(bit_index) already
            bitmap_entry.write(bitmap.set_bit(bit_index));
        }

        fn update_tick(
            ref self: ContractState,
            index: i129,
            liquidity_delta: i129,
            is_upper: bool,
            tick_spacing: u128,
        ) {
            let liquidity_delta_current = self
                .tick_liquidity_delta
                .entry(index)
                .read();

            let liquidity_net_current = self.tick_liquidity_net.entry(index).read();
            let next_liquidity_net = liquidity_net_current.add(liquidity_delta);

            self
                .tick_liquidity_delta
                .write(
                    index,
                    if is_upper {
                        liquidity_delta_current - liquidity_delta
                    } else {
                        liquidity_delta_current + liquidity_delta
                    },
                );

            self.tick_liquidity_net.write(index, next_liquidity_net);

            if ((next_liquidity_net == 0) != (liquidity_net_current == 0)) {
                if (next_liquidity_net == 0) {
                    self.remove_initialized_tick(index, tick_spacing);
                } else {
                    self.insert_initialized_tick(index, tick_spacing);
                }
            };
        }


        fn prefix_next_initialized_tick(
            self: @ContractState,
            tick_spacing: u128,
            from: i129,
            skip_ahead: u128,
        ) -> (i129, bool) {
            assert(from < max_tick(), 'NEXT_FROM_MAX');

            let (word_index, bit_index) = tick_to_word_and_bit_index(
                from + i129 { mag: tick_spacing, sign: false }, tick_spacing,
            );

            let bitmap = self.tick_bitmaps.read(word_index);

            match bitmap.next_set_bit(bit_index) {
                Option::Some(next_bit) => {
                    (word_and_bit_index_to_tick((word_index, next_bit), tick_spacing), true)
                },
                Option::None => {
                    let next = word_and_bit_index_to_tick((word_index, 0), tick_spacing);
                    if (next > max_tick()) {
                        return (max_tick(), false);
                    }
                    if (skip_ahead.is_zero()) {
                        (next, false)
                    } else {
                        self.prefix_next_initialized_tick(tick_spacing, next, skip_ahead - 1)
                    }
                },
            }
        }

        fn prefix_prev_initialized_tick(
            self: @ContractState,
            tick_spacing: u128,
            from: i129,
            skip_ahead: u128,
        ) -> (i129, bool) {
            assert(from >= min_tick(), 'PREV_FROM_MIN');
            let (word_index, bit_index) = tick_to_word_and_bit_index(from, tick_spacing);

            let bitmap = self.tick_bitmaps.read(word_index);

            match bitmap.prev_set_bit(bit_index) {
                Option::Some(prev_bit_index) => {
                    (word_and_bit_index_to_tick((word_index, prev_bit_index), tick_spacing), true)
                },
                Option::None => {
                    // if it's not set, we know there is no set bit in this word
                    let prev = word_and_bit_index_to_tick((word_index, 250), tick_spacing);
                    if (prev < min_tick()) {
                        return (min_tick(), false);
                    }
                    if (skip_ahead == 0) {
                        (prev, false)
                    } else {
                        self.prefix_prev_initialized_tick(
                            tick_spacing,
                            prev - i129 { mag: 1, sign: false },
                            skip_ahead - 1,
                        )
                    }
                },
            }
        }

        fn get_call_points_for_caller(
            self: @ContractState, pool_key: PoolKey, caller: ContractAddress,
        ) -> CallPoints {
            if pool_key.extension.is_non_zero() {
                if (pool_key.extension != caller) {
                    self.extension_call_points.read(pool_key.extension)
                } else {
                    Default::default()
                }
            } else {
                Default::default()
            }
        }
    }

    #[abi(embed_v0)]
    impl CoreHasInterface of IHasInterface<ContractState> {
        fn get_primary_interface_id(self: @ContractState) -> felt252 {
            return selector!("ekubo::core::Core");
        }
    }

    #[abi(embed_v0)]
    impl Core of ICore<ContractState> {
        fn set_authorized_adapter(ref self: ContractState, adapter: ContractAddress) {
            self.require_owner();
            assert(adapter.is_non_zero(), 'ADAPTER_ZERO');
            let current = self.authorized_adapter.read();
            assert((current.is_zero()) | (current == adapter), 'ADAPTER_ALREADY_SET');
            self.authorized_adapter.write(adapter);
        }

        fn get_authorized_adapter(self: @ContractState) -> ContractAddress {
            self.authorized_adapter.read()
        }

        // apply-only pool initialization (proof-driven)
        fn set_pool_state(
            ref self: ContractState,
            sqrt_price: u256,
            tick: i129,
            tick_spacing: u128,
            liquidity: u128,
            fee_growth_global_0: u256,
            fee_growth_global_1: u256,
        ) {
            assert(get_caller_address() == self.authorized_adapter.read(), 'NOT_AUTHORIZED');
            assert(self.pool_price.read().sqrt_ratio.is_zero(), 'ALREADY_INITIALIZED');
            assert(
                (tick_spacing.is_non_zero()) & (tick_spacing <= MAX_TICK_SPACING),
                'TICK_SPACING',
            );
            let configured_spacing = self.configured_tick_spacing.read();
            if configured_spacing.is_zero() {
                self.configured_tick_spacing.write(tick_spacing);
            } else {
                assert(configured_spacing == tick_spacing, 'TICK_SPACING_MISMATCH');
            }
            assert(sqrt_price >= min_sqrt_ratio(), 'PRICE_BELOW_MIN');
            assert(sqrt_price <= max_sqrt_ratio(), 'PRICE_ABOVE_MAX');
            assert(tick >= min_tick(), 'TICK_BELOW_MIN');
            assert(tick <= max_tick(), 'TICK_ABOVE_MAX');
            assert(fee_growth_global_0 <= MAX_FEE_GROWTH, 'FEE0_MAX');
            assert(fee_growth_global_1 <= MAX_FEE_GROWTH, 'FEE1_MAX');
            self.pool_price.write(PoolPrice { sqrt_ratio: sqrt_price, tick });
            self.pool_liquidity.write(liquidity);
            self.pool_fees.write(
                FeesPerLiquidity { value0: fee_growth_global_0, value1: fee_growth_global_1 }
            );
        }

        // apply-only swap state update (proof-driven)
        fn apply_swap_state(ref self: ContractState, public_inputs: Span<u256>) {
            assert(get_caller_address() == self.authorized_adapter.read(), 'NOT_AUTHORIZED');
            assert(public_inputs.len() == SWAP_PUBLIC_INPUTS_LEN, 'SWAP_INPUTS_LEN');

            let sqrt_price_start: u256 = *public_inputs.at(3);
            let sqrt_price_end: u256 = *public_inputs.at(4);
            let liquidity_before: u128 = assert_high_zero(*public_inputs.at(5)).low;
            let fee: u128 = assert_high_zero(*public_inputs.at(6)).low;
            let fee_growth_global_0_before: u256 = *public_inputs.at(7);
            let fee_growth_global_1_before: u256 = *public_inputs.at(8);
            let zero_for_one = decode_bool(*public_inputs.at(12));

            bind_pool_fee(ref self, fee);
            assert(fee_growth_global_0_before <= MAX_FEE_GROWTH, 'FEE0_MAX');
            assert(fee_growth_global_1_before <= MAX_FEE_GROWTH, 'FEE1_MAX');

            let mut price = self.pool_price.read();
            let mut liquidity = self.pool_liquidity.read();
            let mut fees_per_liquidity = self.pool_fees.read();

            assert(price.sqrt_ratio == sqrt_price_start, 'PRICE_MISMATCH');
            assert(liquidity == liquidity_before, 'LIQ_BEFORE_MISMATCH');
            assert(fees_per_liquidity.value0 == fee_growth_global_0_before, 'FEE0_BEFORE_MISMATCH');
            assert(fees_per_liquidity.value1 == fee_growth_global_1_before, 'FEE1_BEFORE_MISMATCH');

            assert(sqrt_price_end >= min_sqrt_ratio(), 'PRICE_BELOW_MIN');
            assert(sqrt_price_end <= max_sqrt_ratio(), 'PRICE_ABOVE_MAX');
            if zero_for_one {
                assert(sqrt_price_end <= sqrt_price_start, 'PRICE_DIR');
            } else {
                assert(sqrt_price_end >= sqrt_price_start, 'PRICE_DIR');
            }

            let spacing = self.configured_tick_spacing.read();
            assert(spacing.is_non_zero(), 'TICK_SPACING_UNSET');

            let mut tick = price.tick;
            let mut sqrt_ratio = price.sqrt_ratio;
            let mut fees_value0: u256 = fee_growth_global_0_before;
            let mut fees_value1: u256 = fee_growth_global_1_before;

            let base: usize = 13;
            for step_idx in 0..MAX_SWAP_STEPS {
                let step_sqrt_price_next: u256 = *public_inputs.at(base + step_idx);
                let step_sqrt_price_limit: u256 = *public_inputs.at(base + MAX_SWAP_STEPS + step_idx);
                let step_tick_next_i32 = decode_i32_signed(
                    *public_inputs.at(base + (MAX_SWAP_STEPS * 2) + step_idx),
                )
                    .expect('STEP_TICK_RANGE');
                let step_liquidity_net = signed_u256_to_i129(
                    *public_inputs.at(base + (MAX_SWAP_STEPS * 3) + step_idx),
                );
                let step_fee_growth_global_0: u256 =
                    *public_inputs.at(base + (MAX_SWAP_STEPS * 4) + step_idx);
                let step_fee_growth_global_1: u256 =
                    *public_inputs.at(base + (MAX_SWAP_STEPS * 5) + step_idx);
                assert(step_fee_growth_global_0 <= MAX_FEE_GROWTH, 'FEE0_MAX');
                assert(step_fee_growth_global_1 <= MAX_FEE_GROWTH, 'FEE1_MAX');

                let (expected_tick, is_initialized) = if zero_for_one {
                    self.prefix_prev_initialized_tick(spacing, tick, 0)
                } else {
                    self.prefix_next_initialized_tick(spacing, tick, 0)
                };
                assert(step_tick_next_i32 == i129_to_i32(expected_tick), 'STEP_TICK_MISMATCH');

                let expected_tick_sqrt_ratio = tick_to_sqrt_ratio(expected_tick);
                assert(step_sqrt_price_limit == expected_tick_sqrt_ratio, 'STEP_LIMIT_MISMATCH');
                if is_initialized {
                    let stored_delta = self.tick_liquidity_delta.entry(expected_tick).read();
                    assert(step_liquidity_net == stored_delta, 'STEP_LIQ_NET_MISMATCH');
                } else {
                    assert(step_liquidity_net.is_zero(), 'STEP_LIQ_NET_NONZERO');
                }

                let step_limit = if zero_for_one {
                    if sqrt_price_end > step_sqrt_price_limit {
                        sqrt_price_end
                    } else {
                        step_sqrt_price_limit
                    }
                } else {
                    if sqrt_price_end < step_sqrt_price_limit {
                        sqrt_price_end
                    } else {
                        step_sqrt_price_limit
                    }
                };

                if zero_for_one {
                    assert(step_sqrt_price_next <= sqrt_ratio, 'STEP_PRICE_DIR');
                    assert(step_sqrt_price_next >= step_limit, 'STEP_PRICE_LIMIT');
                } else {
                    assert(step_sqrt_price_next >= sqrt_ratio, 'STEP_PRICE_DIR');
                    assert(step_sqrt_price_next <= step_limit, 'STEP_PRICE_LIMIT');
                }

                if sqrt_ratio == sqrt_price_end {
                    assert(step_sqrt_price_next == sqrt_price_end, 'STEP_NOOP_PRICE');
                    assert(step_fee_growth_global_0 == fees_value0, 'STEP_NOOP_FEE0');
                    assert(step_fee_growth_global_1 == fees_value1, 'STEP_NOOP_FEE1');
                    continue;
                }

                assert(step_fee_growth_global_0 >= fees_value0, 'FEE0_REGRESSION');
                assert(step_fee_growth_global_1 >= fees_value1, 'FEE1_REGRESSION');
                fees_value0 = step_fee_growth_global_0;
                fees_value1 = step_fee_growth_global_1;
                fees_per_liquidity = FeesPerLiquidity { value0: fees_value0, value1: fees_value1 };

                let crossed = step_sqrt_price_next == step_sqrt_price_limit;
                if crossed {
                    sqrt_ratio = step_sqrt_price_next;
                    tick = if zero_for_one {
                        expected_tick - i129 { mag: 1, sign: false }
                    } else {
                        expected_tick
                    };

                    if is_initialized {
                        if zero_for_one {
                            liquidity = liquidity.sub(step_liquidity_net);
                        } else {
                            liquidity = liquidity.add(step_liquidity_net);
                        }

                        let tick_fpl_storage = self.tick_fees_outside.entry(expected_tick);
                        tick_fpl_storage.write(fees_per_liquidity - tick_fpl_storage.read());
                    }
                } else if sqrt_ratio != step_sqrt_price_next {
                    sqrt_ratio = step_sqrt_price_next;
                    tick = sqrt_ratio_to_tick(sqrt_ratio);
                }
            }

            assert(sqrt_ratio == sqrt_price_end, 'FINAL_PRICE_MISMATCH');
            // allow min_tick - 1 after crossing the minimum price boundary
            let min_tick_minus_one = min_tick() - i129 { mag: 1, sign: false };
            assert(tick >= min_tick_minus_one, 'TICK_BELOW_MIN');
            assert(tick <= max_tick(), 'TICK_ABOVE_MAX');
            self.pool_price.write(PoolPrice { sqrt_ratio, tick });
            self.pool_liquidity.write(liquidity);
            self.pool_fees.write(fees_per_liquidity);
        }

        // apply-only liquidity update (proof-driven)
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
            assert(get_caller_address() == self.authorized_adapter.read(), 'NOT_AUTHORIZED');
            bind_pool_identity(ref self, token0, token1, tick_spacing);
            bind_pool_fee(ref self, fee);
            assert(fee_growth_global_0 <= MAX_FEE_GROWTH, 'FEE0_MAX');
            assert(fee_growth_global_1 <= MAX_FEE_GROWTH, 'FEE1_MAX');
            let tick_lower_i128: i128 = tick_lower.try_into().expect('TICK_RANGE');
            let tick_upper_i128: i128 = tick_upper.try_into().expect('TICK_RANGE');
            let tick_lower_i129: i129 = tick_lower_i128.into();
            let tick_upper_i129: i129 = tick_upper_i128.into();
            assert(tick_lower_i129 < tick_upper_i129, 'INVALID_TICKS');
            assert(tick_lower_i129 >= min_tick(), 'TICK_LOWER_BELOW_MIN');
            assert(tick_upper_i129 <= max_tick(), 'TICK_UPPER_ABOVE_MAX');
            assert(tick_aligned(tick_lower_i129, tick_spacing), 'TICK_LOWER_ALIGNMENT');
            assert(tick_aligned(tick_upper_i129, tick_spacing), 'TICK_UPPER_ALIGNMENT');
            let (liq_sign, liq_mag) = signed_u256_to_sign_mag(liquidity_delta);
            let liquidity_delta_i129 = i129 { mag: liq_mag, sign: liq_sign & liq_mag.is_non_zero() };
            assert(liq_mag.is_non_zero(), 'LIQ_DELTA_ZERO');

            let price = self.pool_price.read();
            let fees_current = self.pool_fees.read();
            assert(fee_growth_global_0 >= fees_current.value0, 'FEE0_REGRESSION');
            assert(fee_growth_global_1 >= fees_current.value1, 'FEE1_REGRESSION');
            // allow min_tick - 1 after crossing the minimum price boundary (ekubo behavior)
            let min_tick_minus_one = min_tick() - i129 { mag: 1, sign: false };
            assert(price.tick >= min_tick_minus_one, 'TICK_BELOW_MIN');
            assert(price.tick <= max_tick(), 'TICK_ABOVE_MAX');

            self.update_tick(tick_lower_i129, liquidity_delta_i129, false, tick_spacing);
            self.update_tick(tick_upper_i129, liquidity_delta_i129, true, tick_spacing);

            if ((price.tick >= tick_lower_i129) & (price.tick < tick_upper_i129)) {
                let liq = self.pool_liquidity.read();
                self.pool_liquidity.write(liq.add(liquidity_delta_i129));
            }

            self
                .pool_fees
                .write(
                    FeesPerLiquidity {
                        value0: fee_growth_global_0,
                        value1: fee_growth_global_1,
                    },
                );

            if (protocol_fee_0.is_non_zero()) {
                self
                    .protocol_fees_collected
                    .write(
                        token0,
                        accumulate_fee_amount(
                            self.protocol_fees_collected.read(token0), protocol_fee_0,
                        ),
                    );
            }
            if (protocol_fee_1.is_non_zero()) {
                self
                    .protocol_fees_collected
                    .write(
                        token1,
                        accumulate_fee_amount(
                            self.protocol_fees_collected.read(token1), protocol_fee_1,
                        ),
                    );
            }
        }

        fn get_protocol_fees_collected(self: @ContractState, token: ContractAddress) -> u128 {
            self.protocol_fees_collected.read(token)
        }

        fn get_locker_state(self: @ContractState, id: u32) -> LockerState {
            let _ = id;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            LockerState { address: Zero::zero(), nonzero_delta_count: 0 }
        }


        fn get_locker_delta(self: @ContractState, id: u32, token_address: ContractAddress) -> i129 {
            let _ = id;
            let _ = token_address;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            Zero::zero()
        }

        fn get_pool_price(self: @ContractState, pool_key: PoolKey) -> PoolPrice {
            assert_pool_key(self, pool_key);
            self.pool_price.read()
        }

        fn get_pool_price_single(self: @ContractState) -> PoolPrice {
            self.pool_price.read()
        }

        fn get_pool_liquidity(self: @ContractState, pool_key: PoolKey) -> u128 {
            assert_pool_key(self, pool_key);
            self.pool_liquidity.read()
        }

        fn get_pool_liquidity_single(self: @ContractState) -> u128 {
            self.pool_liquidity.read()
        }

        fn get_pool_fees_per_liquidity(
            self: @ContractState, pool_key: PoolKey,
        ) -> FeesPerLiquidity {
            assert_pool_key(self, pool_key);
            self.pool_fees.read()
        }

        fn get_pool_fees_per_liquidity_single(self: @ContractState) -> FeesPerLiquidity {
            self.pool_fees.read()
        }

        fn get_pool_tick_liquidity_delta(
            self: @ContractState, pool_key: PoolKey, index: i129,
        ) -> u256 {
            assert_pool_key(self, pool_key);
            i129_to_signed_u256(self.tick_liquidity_delta.entry(index).read())
        }

        fn get_pool_tick_liquidity_net(
            self: @ContractState, pool_key: PoolKey, index: i129,
        ) -> u128 {
            assert_pool_key(self, pool_key);
            self.tick_liquidity_net.entry(index).read()
        }

        fn get_pool_tick_fees_outside(
            self: @ContractState, pool_key: PoolKey, index: i129,
        ) -> FeesPerLiquidity {
            assert_pool_key(self, pool_key);
            self.tick_fees_outside.entry(index).read()
        }

        fn get_position(
            self: @ContractState, pool_key: PoolKey, position_key: PositionKey,
        ) -> Position {
            let _ = pool_key;
            let _ = position_key;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            Zero::zero()
        }

        fn get_position_with_fees(
            self: @ContractState, pool_key: PoolKey, position_key: PositionKey,
        ) -> GetPositionWithFeesResult {
            let _ = pool_key;
            let _ = position_key;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            GetPositionWithFeesResult {
                position: Zero::zero(),
                fees0: 0,
                fees1: 0,
                fees_per_liquidity_inside_current: Zero::zero(),
            }
        }

        fn get_saved_balance(self: @ContractState, key: SavedBalanceKey) -> u128 {
            let _ = key;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            0
        }


        fn next_initialized_tick(
            self: @ContractState, pool_key: PoolKey, from: i129, skip_ahead: u128,
        ) -> (i129, bool) {
            assert_pool_key(self, pool_key);
            self.prefix_next_initialized_tick(pool_key.tick_spacing, from, skip_ahead)
        }

        fn prev_initialized_tick(
            self: @ContractState, pool_key: PoolKey, from: i129, skip_ahead: u128,
        ) -> (i129, bool) {
            assert_pool_key(self, pool_key);
            self.prefix_prev_initialized_tick(pool_key.tick_spacing, from, skip_ahead)
        }

        fn withdraw_all_protocol_fees(
            ref self: ContractState, recipient: ContractAddress, token: ContractAddress,
        ) -> u128 {
            // keeps custody in ShieldedNotes, core does not transfer erc20s
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            let amount_collected = self.get_protocol_fees_collected(token);
            self.withdraw_protocol_fees(recipient, token, amount_collected);
            amount_collected
        }

        fn withdraw_protocol_fees(
            ref self: ContractState,
            recipient: ContractAddress,
            token: ContractAddress,
            amount: u128,
        ) {
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            self.require_owner();

            let collected: u128 = self.protocol_fees_collected.read(token);
            self.protocol_fees_collected.write(token, collected - amount);

            assert(
                IERC20Dispatcher { contract_address: token }.transfer(recipient, amount.into()),
                'TOKEN_TRANSFER_FAILED',
            );
            self.emit(ProtocolFeesWithdrawn { recipient, token, amount });
        }

        fn apply_protocol_fee_withdraw(
            ref self: ContractState, token: ContractAddress, amount: u128,
        ) {
            // accounting-only adjustment for shielded withdrawals
            assert(get_caller_address() == self.authorized_adapter.read(), 'NOT_AUTHORIZED');
            if amount == 0 {
                return ();
            }
            let collected: u128 = self.protocol_fees_collected.read(token);
            assert(collected >= amount, 'FEE_BALANCE_LOW');
            self.protocol_fees_collected.write(token, collected - amount);
        }

        fn lock(ref self: ContractState, data: Span<felt252>) -> Span<felt252> {
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            array![].span()
        }

        fn forward(
            ref self: ContractState, to: IForwardeeDispatcher, data: Span<felt252>,
        ) -> Span<felt252> {
            let _ = to;
            let _ = data;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            array![].span()
        }

        fn withdraw(
            ref self: ContractState,
            token_address: ContractAddress,
            recipient: ContractAddress,
            amount: u128,
        ) {
            let _ = token_address;
            let _ = recipient;
            let _ = amount;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
        }

        fn save(ref self: ContractState, key: SavedBalanceKey, amount: u128) -> u128 {
            let _ = key;
            let _ = amount;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            0
        }

        fn pay(ref self: ContractState, token_address: ContractAddress) {
            let _ = token_address;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
        }

        fn load(
            ref self: ContractState, token: ContractAddress, salt: felt252, amount: u128,
        ) -> u128 {
            let _ = token;
            let _ = salt;
            let _ = amount;
            assert(false, 'DISABLED_IN_SHIELDED_MODE');
            0
        }

        fn maybe_initialize_pool(
            ref self: ContractState, pool_key: PoolKey, initial_tick: i129,
        ) -> Option<u256> {
            let _ = pool_key;
            let _ = initial_tick;
            assert(false, 'DIRECT_CALL_DISABLED');
            Option::None
        }

        fn initialize_pool(ref self: ContractState, pool_key: PoolKey, initial_tick: i129) -> u256 {
            assert(false, 'DIRECT_CALL_DISABLED');
            bind_pool_key(ref self, pool_key);

            assert(
                pool_key.extension.is_zero()
                    || (self.extension_call_points.read(pool_key.extension) != Default::default()),
                'EXTENSION_NOT_REGISTERED',
            );

            let call_points = self.get_call_points_for_caller(pool_key, get_caller_address());

            if (call_points.before_initialize_pool) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .before_initialize_pool(get_caller_address(), pool_key, initial_tick);
            }

            let price = self.pool_price.read();
            assert(price.sqrt_ratio.is_zero(), 'ALREADY_INITIALIZED');

            let sqrt_ratio = tick_to_sqrt_ratio(initial_tick);
            self.pool_price.write(PoolPrice { sqrt_ratio, tick: initial_tick });

            self.emit(PoolInitialized { pool_key, initial_tick, sqrt_ratio });

            if (call_points.after_initialize_pool) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .after_initialize_pool(get_caller_address(), pool_key, initial_tick);
            }

            sqrt_ratio
        }

        fn get_pool_fees_per_liquidity_inside(
            self: @ContractState, pool_key: PoolKey, bounds: Bounds,
        ) -> FeesPerLiquidity {
            assert_pool_key(self, pool_key);
            let price = self.pool_price.read();
            assert(price.sqrt_ratio.is_non_zero(), 'NOT_INITIALIZED');

            let fees_outside_lower = self.tick_fees_outside.entry(bounds.lower).read();
            let fees_outside_upper = self.tick_fees_outside.entry(bounds.upper).read();

            if (price.tick < bounds.lower) {
                fees_outside_lower - fees_outside_upper
            } else if (price.tick < bounds.upper) {
                let fees = self.pool_fees.read();

                fees - fees_outside_lower - fees_outside_upper
            } else {
                fees_outside_upper - fees_outside_lower
            }
        }

        fn update_position(
            ref self: ContractState, pool_key: PoolKey, params: UpdatePositionParameters,
        ) -> Delta {
            // per-user positions are not stored on-chain in shielded mode
            assert(false, 'DIRECT_CALL_DISABLED');
            let (id, locker) = self.require_locker();
            bind_pool_key(ref self, pool_key);

            let call_points = self.get_call_points_for_caller(pool_key, locker);

            if (call_points.before_update_position) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .before_update_position(locker, pool_key, params);
            }

            // bounds must be multiple of tick spacing
            params.bounds.check_valid(pool_key.tick_spacing);
            let (liq_sign, liq_mag) = signed_u256_to_sign_mag(params.liquidity_delta);
            let liquidity_delta_i129 = i129 { mag: liq_mag, sign: liq_sign & liq_mag.is_non_zero() };

            // pool must be initialized
            let mut price = self.pool_price.read();
            assert(price.sqrt_ratio.is_non_zero(), 'NOT_INITIALIZED');

            let (sqrt_ratio_lower, sqrt_ratio_upper) = (
                tick_to_sqrt_ratio(params.bounds.lower), tick_to_sqrt_ratio(params.bounds.upper),
            );

            // compute the amount deltas due to the liquidity delta
            let mut delta = liquidity_delta_to_amount_delta(
                price.sqrt_ratio, params.liquidity_delta, sqrt_ratio_lower, sqrt_ratio_upper,
            );

            // accumulating fees owed to the position based on its current liquidity
            let position_key = PositionKey {
                owner: locker, salt: params.salt, bounds: params.bounds,
            };

            // account the withdrawal protocol fee, its based on the deltas
            if (liq_sign) {
                let amount0_fee = compute_fee(delta.amount0.mag, pool_key.fee);
                let amount1_fee = compute_fee(delta.amount1.mag, pool_key.fee);

                let withdrawal_fee_delta = Delta {
                    amount0: i129 { mag: amount0_fee, sign: true },
                    amount1: i129 { mag: amount1_fee, sign: true },
                };

                if (amount0_fee.is_non_zero()) {
                    self
                        .protocol_fees_collected
                        .write(
                            pool_key.token0,
                            accumulate_fee_amount(
                                self.protocol_fees_collected.read(pool_key.token0), amount0_fee,
                            ),
                        );
                }
                if (amount1_fee.is_non_zero()) {
                    self
                        .protocol_fees_collected
                        .write(
                            pool_key.token1,
                            accumulate_fee_amount(
                                self.protocol_fees_collected.read(pool_key.token1), amount1_fee,
                            ),
                        );
                }

                delta -= withdrawal_fee_delta;
                self.emit(ProtocolFeesPaid { pool_key, position_key, delta: withdrawal_fee_delta });
            }

            let get_position_result = self.get_position_with_fees(pool_key, position_key);

            let position_liquidity_next: u128 = get_position_result
                .position
                .liquidity
                .add(liquidity_delta_i129);

            // if the user is withdrawing everything, they must have collected all the fees
            if position_liquidity_next.is_non_zero() {
                // fees are implicitly stored in the fees per liquidity inside snapshot variable
                let fees_per_liquidity_inside_last = get_position_result
                    .fees_per_liquidity_inside_current
                    - fees_per_liquidity_new(
                        get_position_result.fees0,
                        get_position_result.fees1,
                        position_liquidity_next,
                    );

                // update the position
                self
                    .positions
                    .write(
                        (pool_key, position_key),
                        Position {
                            liquidity: position_liquidity_next,
                            fees_per_liquidity_inside_last: fees_per_liquidity_inside_last,
                        },
                    );
            } else {
                assert(
                    (get_position_result.fees0.is_zero()) & (get_position_result.fees1.is_zero()),
                    'MUST_COLLECT_FEES',
                );
                // delete the position from storage
                self.positions.write((pool_key, position_key), Zero::zero());
            }

            self.update_tick(params.bounds.lower, liquidity_delta_i129, false, pool_key.tick_spacing);
            self.update_tick(params.bounds.upper, liquidity_delta_i129, true, pool_key.tick_spacing);

            // update pool liquidity if it changed
            if ((price.tick >= params.bounds.lower) & (price.tick < params.bounds.upper)) {
                let liquidity = self.pool_liquidity.read();
                self.pool_liquidity.write(liquidity.add(liquidity_delta_i129));
            }

            // and finally account the computed deltas
            self.account_pool_delta(id, pool_key, delta);

            self.emit(PositionUpdated { locker, pool_key, params, delta });

            if (call_points.after_update_position) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .after_update_position(locker, pool_key, params, delta);
            }

            delta
        }

        fn collect_fees(
            ref self: ContractState, pool_key: PoolKey, salt: felt252, bounds: Bounds,
        ) -> Delta {
            assert(false, 'DIRECT_CALL_DISABLED');
            let (id, locker) = self.require_locker();
            bind_pool_key(ref self, pool_key);

            let call_points = self.get_call_points_for_caller(pool_key, locker);

            if (call_points.before_collect_fees) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .before_collect_fees(locker, pool_key, salt, bounds);
            }

            let position_key = PositionKey { owner: locker, salt, bounds };
            let result = self.get_position_with_fees(pool_key, position_key);

            // update the position
            self
                .positions
                .write(
                    (pool_key, position_key),
                    Position {
                        liquidity: result.position.liquidity,
                        fees_per_liquidity_inside_last: result.fees_per_liquidity_inside_current,
                    },
                );

            let delta = Delta {
                amount0: i129 { mag: result.fees0, sign: true },
                amount1: i129 { mag: result.fees1, sign: true },
            };

            self.account_pool_delta(id, pool_key, delta);

            self.emit(PositionFeesCollected { pool_key, position_key, delta });

            if (call_points.after_collect_fees) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .after_collect_fees(locker, pool_key, salt, bounds, delta);
            }

            delta
        }

        fn swap(ref self: ContractState, pool_key: PoolKey, params: SwapParameters) -> Delta {
            assert(false, 'DIRECT_CALL_DISABLED');
            let (id, locker) = self.require_locker();
            bind_pool_key(ref self, pool_key);

            let call_points = self.get_call_points_for_caller(pool_key, locker);

            if (call_points.before_swap) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .before_swap(locker, pool_key, params);
            }

            let mut price: PoolPrice = self.pool_price.read();

            // pool must be initialized
            assert(price.sqrt_ratio.is_non_zero(), 'NOT_INITIALIZED');

            let increasing = is_price_increasing(params.amount.sign, params.is_token1);

            // check the limit is not in the wrong direction and is within the price bounds
            assert((params.sqrt_ratio_limit > price.sqrt_ratio) == increasing, 'LIMIT_DIRECTION');
            assert(
                (params.sqrt_ratio_limit >= min_sqrt_ratio())
                    & (params.sqrt_ratio_limit <= max_sqrt_ratio()),
                'LIMIT_MAG',
            );

            let mut tick = price.tick;
            let mut amount_remaining = params.amount;
            let mut sqrt_ratio = price.sqrt_ratio;

            let mut liquidity = self.pool_liquidity.read();
            let mut calculated_amount: u128 = Zero::zero();

            let mut fees_per_liquidity = self.pool_fees.read();

            while (amount_remaining.is_non_zero() & (sqrt_ratio != params.sqrt_ratio_limit)) {
                let (next_tick, is_initialized) = if (increasing) {
                    self.prefix_next_initialized_tick(
                        pool_key.tick_spacing, tick, params.skip_ahead,
                    )
                } else {
                    self.prefix_prev_initialized_tick(
                        pool_key.tick_spacing, tick, params.skip_ahead,
                    )
                };

                let next_tick_sqrt_ratio = tick_to_sqrt_ratio(next_tick);

                let step_sqrt_ratio_limit = if (increasing) {
                    if (params.sqrt_ratio_limit < next_tick_sqrt_ratio) {
                        params.sqrt_ratio_limit
                    } else {
                        next_tick_sqrt_ratio
                    }
                } else {
                    if (params.sqrt_ratio_limit > next_tick_sqrt_ratio) {
                        params.sqrt_ratio_limit
                    } else {
                        next_tick_sqrt_ratio
                    }
                };

                let swap_result = swap_result(
                    sqrt_ratio,
                    liquidity,
                    sqrt_ratio_limit: step_sqrt_ratio_limit,
                    amount: amount_remaining,
                    is_token1: params.is_token1,
                    fee: pool_key.fee,
                );

                // this only happens when liquidity is non zero
                if (swap_result.fee_amount.is_non_zero()) {
                    fees_per_liquidity = fees_per_liquidity
                        + if increasing {
                            fees_per_liquidity_from_amount1(
                                swap_result.fee_amount, liquidity.into(),
                            )
                        } else {
                            fees_per_liquidity_from_amount0(
                                swap_result.fee_amount, liquidity.into(),
                            )
                        };
                }

                amount_remaining -= swap_result.consumed_amount;
                calculated_amount += swap_result.calculated_amount;

                // hit the tick boundary, transition to the next tick
                if (swap_result.sqrt_ratio_next == next_tick_sqrt_ratio) {
                    sqrt_ratio = swap_result.sqrt_ratio_next;
                    // crossing the tick, so the tick is changed to the next tick
                    tick =
                        if (increasing) {
                            next_tick
                        } else {
                            next_tick - i129 { mag: 1, sign: false }
                        };

                    if (is_initialized) {
                        let liquidity_delta = self.tick_liquidity_delta.read(next_tick);
                        // update our working liquidity based on the direction we are crossing the tick
                        if (increasing) {
                            liquidity = liquidity.add(liquidity_delta);
                        } else {
                            liquidity = liquidity.sub(liquidity_delta);
                        }

                        let tick_fpl_storage_address = self.tick_fees_outside.entry(next_tick);
                        tick_fpl_storage_address
                            .write(fees_per_liquidity - tick_fpl_storage_address.read());
                    }
                } else if sqrt_ratio != swap_result.sqrt_ratio_next {
                    // the price moved but it did not cross the next tick, we must only update the tick in case the price moved, otherwise we may transition the tick incorrectly
                    sqrt_ratio = swap_result.sqrt_ratio_next;
                    tick = sqrt_ratio_to_tick(sqrt_ratio);
                };
            }

            let delta = if (params.is_token1) {
                Delta {
                    amount0: i129 { mag: calculated_amount, sign: !params.amount.sign },
                    amount1: params.amount - amount_remaining,
                }
            } else {
                Delta {
                    amount0: params.amount - amount_remaining,
                    amount1: i129 { mag: calculated_amount, sign: !params.amount.sign },
                }
            };

            self.pool_price.write(PoolPrice { sqrt_ratio, tick });
            self.pool_liquidity.write(liquidity);
            self.pool_fees.write(fees_per_liquidity);

            self.account_pool_delta(id, pool_key, delta);

            self
                .emit(
                    Swapped {
                        locker,
                        pool_key,
                        params,
                        delta,
                        sqrt_ratio_after: sqrt_ratio,
                        tick_after: tick,
                        liquidity_after: liquidity,
                    },
                );

            if (call_points.after_swap) {
                IExtensionDispatcher { contract_address: pool_key.extension }
                    .after_swap(locker, pool_key, params, delta);
            }

            delta
        }

        fn accumulate_as_fees(
            ref self: ContractState, pool_key: PoolKey, amount0: u128, amount1: u128,
        ) {
            let (id, locker) = self.require_locker();
            bind_pool_key(ref self, pool_key);

            // this method is only allowed for the extension of a pool, because otherwise it complicates extension implementation considerably
            assert(locker == pool_key.extension, 'NOT_EXTENSION');

            self
                .pool_fees
                .write(
                    self.pool_fees.read()
                        + fees_per_liquidity_new(amount0, amount1, self.pool_liquidity.read()),
                );

            self
                .account_pool_delta(
                    id,
                    pool_key,
                    Delta {
                        amount0: i129 { mag: amount0, sign: false },
                        amount1: i129 { mag: amount1, sign: false },
                    },
                );

            self.emit(FeesAccumulated { pool_key, amount0, amount1 });
        }

        fn set_call_points(ref self: ContractState, call_points: CallPoints) {
            assert(call_points != Default::default(), 'INVALID_CALL_POINTS');
            self.extension_call_points.write(get_caller_address(), call_points);
        }

        // returns the call points for the given extension
        fn get_call_points(self: @ContractState, extension: ContractAddress) -> CallPoints {
            self.extension_call_points.read(extension)
        }
    }

    fn bind_pool_identity(
        ref self: ContractState, token0: ContractAddress, token1: ContractAddress, tick_spacing: u128,
    ) {
        assert(token0 < token1, 'TOKEN_ORDER');
        assert(token0.is_non_zero(), 'TOKEN_NON_ZERO');
        assert(
            (tick_spacing.is_non_zero()) & (tick_spacing <= MAX_TICK_SPACING),
            'TICK_SPACING',
        );

        let configured_token0 = self.configured_token0.read();
        if configured_token0.is_zero() {
            self.configured_token0.write(token0);
            self.configured_token1.write(token1);
        } else {
            assert(configured_token0 == token0, 'TOKEN0_MISMATCH');
            assert(self.configured_token1.read() == token1, 'TOKEN1_MISMATCH');
        }

        let configured_spacing = self.configured_tick_spacing.read();
        if configured_spacing.is_zero() {
            self.configured_tick_spacing.write(tick_spacing);
        } else {
            assert(configured_spacing == tick_spacing, 'TICK_SPACING_MISMATCH');
        }
    }

    fn bind_pool_fee(ref self: ContractState, fee: u128) {
        if self.fee_bound.read() {
            assert(self.configured_fee.read() == fee, 'FEE_MISMATCH');
        } else {
            self.configured_fee.write(fee);
            self.fee_bound.write(true);
        }
    }

    fn bind_pool_key(ref self: ContractState, pool_key: PoolKey) {
        pool_key.check_valid();
        bind_pool_identity(ref self, pool_key.token0, pool_key.token1, pool_key.tick_spacing);

        if self.fee_bound.read() {
            assert(self.configured_fee.read() == pool_key.fee, 'FEE_MISMATCH');
        } else {
            self.configured_fee.write(pool_key.fee);
            self.fee_bound.write(true);
        }

        if self.extension_bound.read() {
            assert(self.configured_extension.read() == pool_key.extension, 'EXTENSION_MISMATCH');
        } else {
            self.configured_extension.write(pool_key.extension);
            self.extension_bound.write(true);
        }
    }

    fn assert_pool_key(self: @ContractState, pool_key: PoolKey) {
        pool_key.check_valid();
        let configured_token0 = self.configured_token0.read();
        if configured_token0.is_non_zero() {
            assert(configured_token0 == pool_key.token0, 'TOKEN0_MISMATCH');
            assert(self.configured_token1.read() == pool_key.token1, 'TOKEN1_MISMATCH');
            let configured_spacing = self.configured_tick_spacing.read();
            assert(configured_spacing == pool_key.tick_spacing, 'TICK_SPACING_MISMATCH');
            if self.fee_bound.read() {
                assert(self.configured_fee.read() == pool_key.fee, 'FEE_MISMATCH');
            }
            if self.extension_bound.read() {
                assert(self.configured_extension.read() == pool_key.extension, 'EXTENSION_MISMATCH');
            }
        }
    }

    fn assert_high_zero(input: u256) -> u256 {
        assert(input.high == 0, 'UNEXPECTED_U256_HIGH');
        input
    }

    fn decode_bool(input: u256) -> bool {
        let felt: felt252 = assert_high_zero(input).try_into().expect('BOOL_RANGE');
        assert((felt == 0) | (felt == 1), 'BOOL_VALUE');
        felt == 1
    }

    fn decode_i128_signed(input: u256) -> Option<i128> {
        if input.high == 0 {
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
        } else if input.high == MAX_U128 {
            let sign_bit_set = input.low >= HIGH_BIT_U128;
            if !sign_bit_set {
                return Option::None;
            }
            if input.low == HIGH_BIT_U128 {
                Option::Some(-170141183460469231731687303715884105728_i128)
            } else {
                let twos_mag: u128 = (MAX_U128 - input.low) + 1;
                match twos_mag.try_into() {
                    Option::Some(mag_i128) => Option::Some(-mag_i128),
                    Option::None => Option::None,
                }
            }
        } else {
            Option::None
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

    fn signed_u256_to_i129(value: u256) -> i129 {
        let (sign, mag) = signed_u256_to_sign_mag(value);
        i129 { mag, sign: sign & mag.is_non_zero() }
    }

    fn i129_to_signed_u256(value: i129) -> u256 {
        if value.mag.is_zero() {
            u256 { low: 0, high: 0 }
        } else if value.sign {
            u256 { low: (MAX_U128 - value.mag) + 1, high: 0 }
        } else {
            u256 { low: value.mag, high: 0 }
        }
    }

    fn i129_to_i32(value: i129) -> i32 {
        let mag_i32: i32 = value.mag.try_into().expect('TICK_RANGE');
        if value.sign & value.mag.is_non_zero() {
            -mag_i32
        } else {
            mag_i32
        }
    }

    fn tick_aligned(tick: i129, spacing: u128) -> bool {
        let mag: u128 = tick.mag;
        (mag % spacing) == 0
    }
}
