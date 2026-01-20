// main shielded pool contract for zylith, structure and entrypoints, logic delegated to helpers
// proofs derive state transitions, on-chain checks enforce global invariants
// token custody is exclusively in ShieldedNotes, pool/adapter never transfer erc20s
use starknet::ContractAddress;
use crate::clmm::interfaces::core::SwapParameters;
use crate::clmm::types::delta::Delta;
use crate::privacy::ShieldedNotes::MerkleProof;

#[derive(Drop, Serde, Copy)]
pub struct PoolState {
    pub sqrt_price: u256,
    pub tick: i32,
    pub liquidity: u128,
    pub fee_growth_global_0: u256,
    pub fee_growth_global_1: u256,
}

#[derive(Drop, Serde, Copy, starknet::Store)]
pub struct PoolConfig {
    pub token0: ContractAddress,
    pub token1: ContractAddress,
    pub fee: u128,
    pub tick_spacing: u128,
    pub min_sqrt_ratio: u256,
    pub max_sqrt_ratio: u256,
}

#[derive(Drop, Serde, Copy)]
pub struct SwapQuote {
    pub delta: Delta,
    pub sqrt_price_after: u256,
    pub tick_after: i32,
    pub liquidity_after: u128,
}

#[derive(Drop, Serde, Copy)]
pub struct SwapStepQuote {
    pub sqrt_price_next: u256,
    pub sqrt_price_limit: u256,
    pub tick_next: i32,
    pub liquidity_net: u256,
    pub fee_growth_global_0: u256,
    pub fee_growth_global_1: u256,
    pub amount_in: u128,
    pub amount_out: u128,
    pub fee_amount: u128,
}

#[derive(Drop, Serde)]
pub struct SwapStepsQuote {
    pub sqrt_price_start: u256,
    pub sqrt_price_end: u256,
    pub tick_start: i32,
    pub tick_end: i32,
    pub liquidity_start: u128,
    pub liquidity_end: u128,
    pub fee_growth_global_0_before: u256,
    pub fee_growth_global_1_before: u256,
    pub fee_growth_global_0_after: u256,
    pub fee_growth_global_1_after: u256,
    pub is_limited: bool,
    pub steps: Array<SwapStepQuote>,
}

#[starknet::interface]
pub trait ZylithPoolExternal<TContractState> {
    fn initialize(
        ref self: TContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        fee: u128,
        tick_spacing: i32,
        initial_tick: i32,
    );
    fn transfer_ownership(ref self: TContractState, new_owner: ContractAddress);
    fn swap_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    );
    fn swap_private_exact_out(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    );
    fn quote_swap(self: @TContractState, params: SwapParameters) -> SwapQuote;
    fn quote_swap_steps(self: @TContractState, params: SwapParameters) -> SwapStepsQuote;
    fn add_liquidity_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proofs_token0: Span<MerkleProof>,
        proofs_token1: Span<MerkleProof>,
        proof_position: Span<MerkleProof>,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn remove_liquidity_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn claim_liquidity_fees_private(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    );
    fn get_pool_state(self: @TContractState) -> PoolState;
    fn get_pool_config(self: @TContractState) -> PoolConfig;
    fn get_sqrt_price(self: @TContractState) -> u256;
    fn get_tick(self: @TContractState) -> i32;
    fn get_liquidity(self: @TContractState) -> u128;
    fn get_fee_growth_global(self: @TContractState) -> (u256, u256);
    fn get_sqrt_ratio_at_tick(self: @TContractState, tick: i32) -> u256;
    fn get_fee_growth_inside(self: @TContractState, tick_lower: i32, tick_upper: i32) -> (u256, u256);
    fn withdraw_protocol_fees(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
    );
    fn get_protocol_fee_totals(self: @TContractState) -> (u128, u128);
}

// note commitments are handled off-chain, no plaintext note data is stored on-chain

#[starknet::contract]
pub mod ZylithPool {
    use core::num::traits::Zero;
    use core::array::ArrayTrait;
    use super::{ContractAddress, PoolConfig, PoolState, SwapQuote, SwapStepQuote, SwapStepsQuote};
    use starknet::{get_caller_address, get_contract_address};
    use crate::core::zylith_pool_swap::{swap_private_exact_out_impl, swap_private_impl};
    use crate::core::zylith_pool_liquidity::{
        liquidity_add_impl, liquidity_claim_impl, liquidity_remove_impl,
    };
    use crate::clmm::math::ticks::{min_sqrt_ratio, max_sqrt_ratio};
    use crate::clmm::math::ticks::constants::MAX_TICK_SPACING;
    use crate::clmm::math::swap::{is_price_increasing, no_op_swap_result, swap_result};
    use crate::clmm::math::ticks::{sqrt_ratio_to_tick, tick_to_sqrt_ratio};
    use crate::clmm::types::delta::Delta;
    use crate::clmm::types::i129::i129;
    use crate::clmm::types::i129::AddDeltaTrait;
    use crate::clmm::types::bounds::Bounds;
    use crate::clmm::interfaces::core::{ICoreDispatcher, ICoreDispatcherTrait};
    use crate::clmm::interfaces::core::SwapParameters;
    use crate::clmm::types::keys::PoolKey;
    use crate::core::PoolAdapter::IPoolAdapterDispatcher;
    use crate::core::PoolAdapter::IPoolAdapterDispatcherTrait;
    use crate::privacy::ShieldedNotes::MerkleProof;
    use crate::privacy::ShieldedNotes::ShieldedNotesExternalDispatcher;
    use crate::privacy::ShieldedNotes::ShieldedNotesExternalDispatcherTrait;
    use crate::constants::generated as generated_constants;
    use core::traits::TryInto;

    #[storage]
    struct Storage {
        owner: ContractAddress,
        core_address: ContractAddress,
        pool_adapter: ContractAddress,
        shielded_notes: ContractAddress,
        verifier: ContractAddress,
        pool_config: PoolConfig,
        initialized: bool,
    }

    #[derive(Drop, Serde, starknet::Event)]
    pub struct PrivateSwap {
        pub sqrt_price_after: u256,
        pub tick_after: i32,
        pub timestamp: u64,
    }

    #[derive(Drop, Serde, starknet::Event)]
    pub struct PrivateLiquidityAdded {
        pub timestamp: u64,
    }

    #[derive(Drop, Serde, starknet::Event)]
    pub struct PrivateLiquidityRemoved {
        pub timestamp: u64,
    }

    #[derive(Drop, Serde, starknet::Event)]
    pub struct PrivateLiquidityFeesClaimed {
        pub timestamp: u64,
    }

    #[derive(Drop, Serde, starknet::Event)]
    pub struct OwnerTransferred {
        pub old_owner: ContractAddress,
        pub new_owner: ContractAddress,
        pub timestamp: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        PrivateSwap: PrivateSwap,
        PrivateLiquidityAdded: PrivateLiquidityAdded,
        PrivateLiquidityRemoved: PrivateLiquidityRemoved,
        PrivateLiquidityFeesClaimed: PrivateLiquidityFeesClaimed,
        OwnerTransferred: OwnerTransferred,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core_address: ContractAddress,
        pool_adapter: ContractAddress,
        shielded_notes: ContractAddress,
        verifier: ContractAddress,
        token0: ContractAddress,
        token1: ContractAddress,
        fee: u128,
        tick_spacing: i32,
        owner: ContractAddress,
    ) {
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        assert(tick_spacing > 0, 'INVALID_TICK_SPACING');
        let tick_spacing_u128: u128 = tick_spacing.try_into().expect('TICKSPACING_RANGE');
        assert(tick_spacing_u128 <= MAX_TICK_SPACING, 'TICKSPACING_MAX');
        assert(core_address.is_non_zero(), 'CORE_ZERO');
        assert(pool_adapter.is_non_zero(), 'ADAPTER_ZERO');
        assert(shielded_notes.is_non_zero(), 'NOTES_ZERO');
        assert(verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(token0.is_non_zero(), 'TOKEN0_ZERO');
        assert(token1.is_non_zero(), 'TOKEN1_ZERO');
        assert(token0 < token1, 'TOKEN_ORDER');
        // pool/adapter never custody erc20s, forbid using them as token addresses
        assert(token0 != get_contract_address(), 'POOL_TOKEN0_FORBIDDEN');
        assert(token1 != get_contract_address(), 'POOL_TOKEN1_FORBIDDEN');
        assert(token0 != pool_adapter, 'ADAPTER_TOKEN0_FORBIDDEN');
        assert(token1 != pool_adapter, 'ADAPTER_TOKEN1_FORBIDDEN');
        let notes = ShieldedNotesExternalDispatcher { contract_address: shielded_notes };
        let notes_token0 = notes.get_token0();
        let notes_token1 = notes.get_token1();
        assert(notes_token0 == token0, 'NOTES_TOKEN0_MISMATCH');
        assert(notes_token1 == token1, 'NOTES_TOKEN1_MISMATCH');
        let authorized_pool = notes.get_authorized_pool();
        assert(
            authorized_pool.is_zero() | (authorized_pool == get_contract_address()),
            'NOTES_POOL_MISMATCH',
        );
        let adapter = IPoolAdapterDispatcher { contract_address: pool_adapter };
        assert(adapter.get_core_address() == core_address, 'ADAPTER_CORE_MISMATCH');
        let adapter_pool = adapter.get_authorized_pool();
        assert(
            adapter_pool.is_zero() | (adapter_pool == get_contract_address()),
            'ADAPTER_POOL_MISMATCH',
        );
        self.owner.write(owner);
        self.core_address.write(core_address);
        self.pool_adapter.write(pool_adapter);
        self.shielded_notes.write(shielded_notes);
        self.verifier.write(verifier);
        let config = PoolConfig {
            token0,
            token1,
            fee,
            tick_spacing: tick_spacing_u128,
            min_sqrt_ratio: min_sqrt_ratio(),
            max_sqrt_ratio: max_sqrt_ratio(),
        };
        self.pool_config.write(config);
        let core = ICoreDispatcher { contract_address: core_address };
        let current_adapter = core.get_authorized_adapter();
        assert(current_adapter.is_non_zero(), 'CORE_ADAPTER_ZERO');
        assert(current_adapter == pool_adapter, 'CORE_ADAPTER_MISMATCH');

    }

    #[abi(embed_v0)]
    impl External of super::ZylithPoolExternal<ContractState> {
    fn initialize(
        ref self: ContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        fee: u128,
        tick_spacing: i32,
        initial_tick: i32,
    ) {
        assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
        assert(!self.initialized.read(), 'ALREADY_INITIALIZED');
        let pool_address = get_contract_address();
        let core = ICoreDispatcher { contract_address: self.core_address.read() };
        assert(core.get_authorized_adapter() == self.pool_adapter.read(), 'CORE_ADAPTER_MISMATCH');
        let adapter = IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() };
        assert(adapter.get_authorized_pool() == pool_address, 'ADAPTER_POOL_MISMATCH');
        let notes = ShieldedNotesExternalDispatcher { contract_address: self.shielded_notes.read() };
        assert(notes.get_authorized_pool() == pool_address, 'NOTES_POOL_MISMATCH');
        let config = self.pool_config.read();
        assert(config.token0 == token0, 'TOKEN0_MISMATCH');
        assert(config.token1 == token1, 'TOKEN1_MISMATCH');
        assert(config.fee == fee, 'FEE_MISMATCH');
        let tick_spacing_u128: u128 = tick_spacing.try_into().expect('TICKSPACING_RANGE');
        assert(config.tick_spacing == tick_spacing_u128, 'TICKSPACING_MISMATCH');

        // pool is proof-driven state orchestration only, token custody stays in ShieldedNotes.
        let initial_tick_i128: i128 = initial_tick.try_into().expect('TICK_RANGE');
        let initial_tick_i129: i129 = initial_tick_i128.into();
        let sqrt_price = tick_to_sqrt_ratio(initial_tick_i129);
        assert(sqrt_price >= config.min_sqrt_ratio, 'PRICE_BELOW_MIN');
        assert(sqrt_price <= config.max_sqrt_ratio, 'PRICE_ABOVE_MAX');

        IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() }.set_pool_state(
            sqrt_price,
            initial_tick,
            tick_spacing_u128,
            0,
            u256 { low: 0, high: 0 },
            u256 { low: 0, high: 0 },
        );
        self.initialized.write(true);
    }

    fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
        assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
        assert(new_owner.is_non_zero(), 'OWNER_ZERO');
        let old_owner = self.owner.read();
        assert(new_owner != old_owner, 'OWNER_NO_CHANGE');
        self.owner.write(new_owner);
        self.emit(
            OwnerTransferred {
                old_owner,
                new_owner,
                timestamp: starknet::get_block_timestamp(),
            },
        );
    }

    fn swap_private(
        ref self: ContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    ) {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        swap_private_impl(ref self, calldata, proofs, output_proofs);
    }

    fn swap_private_exact_out(
        ref self: ContractState,
        calldata: Span<felt252>,
        proofs: Span<MerkleProof>,
        output_proofs: Span<MerkleProof>,
    ) {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        swap_private_exact_out_impl(ref self, calldata, proofs, output_proofs);
    }

    fn add_liquidity_private(
        ref self: ContractState,
        calldata: Span<felt252>,
        proofs_token0: Span<MerkleProof>,
        proofs_token1: Span<MerkleProof>,
        proof_position: Span<MerkleProof>,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    ) {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        liquidity_add_impl(
            ref self,
            calldata,
            proofs_token0,
            proofs_token1,
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
        );
    }

    fn remove_liquidity_private(
        ref self: ContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    ) {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        liquidity_remove_impl(
            ref self,
            calldata,
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
        );
    }

    fn claim_liquidity_fees_private(
        ref self: ContractState,
        calldata: Span<felt252>,
        proof_position: MerkleProof,
        insert_proof_position: Span<MerkleProof>,
        output_proof_token0: Span<MerkleProof>,
        output_proof_token1: Span<MerkleProof>,
    ) {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        liquidity_claim_impl(
            ref self,
            calldata,
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
        );
    }

    fn quote_swap(self: @ContractState, params: SwapParameters) -> SwapQuote {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        let config = self.pool_config.read();
        let adapter = IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() };
        let core = ICoreDispatcher { contract_address: self.core_address.read() };
        let pool_key = pool_key_from_config(config);

        let mut sqrt_ratio = adapter.get_sqrt_price();
        assert(sqrt_ratio.is_non_zero(), 'NOT_INITIALIZED');
        let mut tick_i32 = adapter.get_tick();
        let mut tick_i129 = i32_to_i129(tick_i32);
        let mut liquidity = adapter.get_liquidity();
        let _sqrt_price_start = sqrt_ratio;
        let _tick_start = tick_i32;
        let _liquidity_start = liquidity;

        // proof-driven swaps currently pin skip_ahead to zero
        assert(params.skip_ahead == 0, 'SKIP_AHEAD_UNSUPPORTED');

        let increasing = is_price_increasing(params.amount.sign, params.is_token1);
        assert((params.sqrt_ratio_limit > sqrt_ratio) == increasing, 'LIMIT_DIRECTION');
        assert(
            (params.sqrt_ratio_limit >= config.min_sqrt_ratio)
                & (params.sqrt_ratio_limit <= config.max_sqrt_ratio),
            'LIMIT_MAG',
        );

        let mut amount_remaining = params.amount;
        let mut calculated_amount: u128 = Zero::zero();

        while (amount_remaining.is_non_zero() & (sqrt_ratio != params.sqrt_ratio_limit)) {
            let (next_tick, is_initialized) = if (increasing) {
                core.next_initialized_tick(pool_key, tick_i129, params.skip_ahead)
            } else {
                core.prev_initialized_tick(pool_key, tick_i129, params.skip_ahead)
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

            let swap = swap_result(
                sqrt_ratio,
                liquidity,
                step_sqrt_ratio_limit,
                amount_remaining,
                params.is_token1,
                config.fee,
            );

            amount_remaining -= swap.consumed_amount;
            calculated_amount += swap.calculated_amount;

            if (swap.sqrt_ratio_next == next_tick_sqrt_ratio) {
                sqrt_ratio = swap.sqrt_ratio_next;
                tick_i129 = if (increasing) {
                    next_tick
                } else {
                    next_tick - i129 { mag: 1, sign: false }
                };
                tick_i32 = i129_to_i32(tick_i129);

                if (is_initialized) {
                    let delta_u256 = core.get_pool_tick_liquidity_delta(pool_key, next_tick);
                    let delta = signed_u256_to_i129(delta_u256);
                    if (increasing) {
                        liquidity = liquidity.add(delta);
                    } else {
                        liquidity = liquidity.sub(delta);
                    }
                }
            } else if (sqrt_ratio != swap.sqrt_ratio_next) {
                sqrt_ratio = swap.sqrt_ratio_next;
                tick_i129 = sqrt_ratio_to_tick(sqrt_ratio);
                tick_i32 = i129_to_i32(tick_i129);
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

        SwapQuote {
            delta,
            sqrt_price_after: sqrt_ratio,
            tick_after: tick_i32,
            liquidity_after: liquidity,
        }
    }

    fn quote_swap_steps(self: @ContractState, params: SwapParameters) -> SwapStepsQuote {
        assert(self.initialized.read(), 'NOT_INITIALIZED');
        let config = self.pool_config.read();
        let adapter = IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() };
        let core = ICoreDispatcher { contract_address: self.core_address.read() };
        let pool_key = pool_key_from_config(config);

        let mut sqrt_ratio = adapter.get_sqrt_price();
        assert(sqrt_ratio.is_non_zero(), 'NOT_INITIALIZED');
        let mut tick_i32 = adapter.get_tick();
        let mut tick_i129 = i32_to_i129(tick_i32);
        let mut liquidity = adapter.get_liquidity();
        let sqrt_price_start = sqrt_ratio;
        let tick_start = tick_i32;
        let liquidity_start = liquidity;
        let (fee_growth_global_0_before, fee_growth_global_1_before) = adapter.get_fee_growth_global();
        let mut fee_growth_global_0 = fee_growth_global_0_before;
        let mut fee_growth_global_1 = fee_growth_global_1_before;

        assert(params.skip_ahead == 0, 'SKIP_AHEAD_UNSUPPORTED');

        let increasing = is_price_increasing(params.amount.sign, params.is_token1);
        assert((params.sqrt_ratio_limit > sqrt_ratio) == increasing, 'LIMIT_DIRECTION');
        assert(
            (params.sqrt_ratio_limit >= config.min_sqrt_ratio)
                & (params.sqrt_ratio_limit <= config.max_sqrt_ratio),
            'LIMIT_MAG',
        );

        let mut amount_remaining = params.amount;
        let mut steps: Array<SwapStepQuote> = array![];
        let mut step_idx: usize = 0;

        while step_idx < generated_constants::MAX_SWAP_STEPS {
            let (next_tick, is_initialized) = if (increasing) {
                core.next_initialized_tick(pool_key, tick_i129, params.skip_ahead)
            } else {
                core.prev_initialized_tick(pool_key, tick_i129, params.skip_ahead)
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

            let active = amount_remaining.is_non_zero() & (sqrt_ratio != params.sqrt_ratio_limit);
            let swap = if (active) {
                swap_result(
                    sqrt_ratio,
                    liquidity,
                    step_sqrt_ratio_limit,
                    amount_remaining,
                    params.is_token1,
                    config.fee,
                )
            } else {
                no_op_swap_result(sqrt_ratio)
            };

            if (active) {
                amount_remaining -= swap.consumed_amount;
            }

            let exact_output = params.amount.sign;
            let amount_in = if (exact_output) {
                swap.calculated_amount
            } else {
                swap.consumed_amount.mag
            };
            let amount_out = if (exact_output) {
                swap.consumed_amount.mag
            } else {
                swap.calculated_amount
            };

            let step_liquidity_net = if (is_initialized) {
                core.get_pool_tick_liquidity_delta(pool_key, next_tick)
            } else {
                u256 { low: 0, high: 0 }
            };

            if (swap.fee_amount != 0) & liquidity.is_non_zero() {
                let numerator = u256 { low: 0, high: swap.fee_amount };
                let denom = u256 { low: liquidity, high: 0 }.try_into().unwrap();
                let (fee_inc, _remainder) = DivRem::div_rem(numerator, denom);
                if (increasing) {
                    fee_growth_global_1 = fee_growth_global_1 + fee_inc;
                } else {
                    fee_growth_global_0 = fee_growth_global_0 + fee_inc;
                }
            }

            steps.append(
                SwapStepQuote {
                    sqrt_price_next: swap.sqrt_ratio_next,
                    sqrt_price_limit: step_sqrt_ratio_limit,
                    tick_next: i129_to_i32(next_tick),
                    liquidity_net: step_liquidity_net,
                    fee_growth_global_0: fee_growth_global_0,
                    fee_growth_global_1: fee_growth_global_1,
                    amount_in,
                    amount_out,
                    fee_amount: swap.fee_amount,
                }
            );

            if (active) {
                if (swap.sqrt_ratio_next == next_tick_sqrt_ratio) {
                    sqrt_ratio = swap.sqrt_ratio_next;
                    tick_i129 = if (increasing) {
                        next_tick
                    } else {
                        next_tick - i129 { mag: 1, sign: false }
                    };
                    tick_i32 = i129_to_i32(tick_i129);

                    if (is_initialized) {
                        let delta = signed_u256_to_i129(step_liquidity_net);
                        if (increasing) {
                            liquidity = liquidity.add(delta);
                        } else {
                            liquidity = liquidity.sub(delta);
                        }
                    }
                } else if (sqrt_ratio != swap.sqrt_ratio_next) {
                    sqrt_ratio = swap.sqrt_ratio_next;
                    tick_i129 = sqrt_ratio_to_tick(sqrt_ratio);
                    tick_i32 = i129_to_i32(tick_i129);
                }
            }
            step_idx += 1;
        }

        let sqrt_price_end = sqrt_ratio;
        let mut limited_hit = false;
        let zero_for_one = !increasing;
        let mut idx: usize = 0;
        while idx < steps.len() {
            let step = *steps.at(idx);
            let step_limit = if zero_for_one {
                if sqrt_price_end > step.sqrt_price_limit { sqrt_price_end } else { step.sqrt_price_limit }
            } else {
                if sqrt_price_end < step.sqrt_price_limit { sqrt_price_end } else { step.sqrt_price_limit }
            };
            if step.sqrt_price_next == step_limit {
                limited_hit = true;
            }
            idx += 1;
        }

        SwapStepsQuote {
            sqrt_price_start: sqrt_price_start,
            sqrt_price_end: sqrt_price_end,
            tick_start: tick_start,
            tick_end: tick_i32,
            liquidity_start: liquidity_start,
            liquidity_end: liquidity,
            fee_growth_global_0_before,
            fee_growth_global_1_before,
            fee_growth_global_0_after: fee_growth_global_0,
            fee_growth_global_1_after: fee_growth_global_1,
            is_limited: limited_hit,
            steps,
        }
    }

    fn get_pool_state(self: @ContractState) -> PoolState {
        let adapter = IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() };
        let sqrt_price = adapter.get_sqrt_price();
        let tick = adapter.get_tick();
        let liquidity = adapter.get_liquidity();
        let (fee_growth_global_0, fee_growth_global_1) = adapter.get_fee_growth_global();
        PoolState { sqrt_price, tick, liquidity, fee_growth_global_0, fee_growth_global_1 }
    }

    fn get_pool_config(self: @ContractState) -> PoolConfig {
        self.pool_config.read()
    }

    fn get_sqrt_price(self: @ContractState) -> u256 {
        IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() }.get_sqrt_price()
    }

    fn get_tick(self: @ContractState) -> i32 {
        IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() }.get_tick()
    }

    fn get_liquidity(self: @ContractState) -> u128 {
        IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() }.get_liquidity()
    }

    fn get_fee_growth_global(self: @ContractState) -> (u256, u256) {
        IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() }
            .get_fee_growth_global()
    }

    fn get_sqrt_ratio_at_tick(self: @ContractState, tick: i32) -> u256 {
        let tick_i128: i128 = tick.try_into().expect('TICK_RANGE');
        tick_to_sqrt_ratio(tick_i128.into())
    }

    fn get_fee_growth_inside(self: @ContractState, tick_lower: i32, tick_upper: i32) -> (u256, u256) {
        let config = self.pool_config.read();
        let core = ICoreDispatcher { contract_address: self.core_address.read() };
        let bounds = bounds_from_ticks(tick_lower, tick_upper);
        let fees = core.get_pool_fees_per_liquidity_inside(pool_key_from_config(config), bounds);
        (fees.value0, fees.value1)
    }

    fn withdraw_protocol_fees(
        ref self: ContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
    ) {
        assert(get_caller_address() == self.owner.read(), 'OWNER_ONLY');
        let config = self.pool_config.read();
        assert((token == config.token0) | (token == config.token1), 'TOKEN_NOT_ALLOWED');
        let notes =
            ShieldedNotesExternalDispatcher { contract_address: self.shielded_notes.read() };
        notes.withdraw_protocol_fees(token, recipient, amount);
        let adapter = IPoolAdapterDispatcher { contract_address: self.pool_adapter.read() };
        adapter.apply_protocol_fee_withdraw(token, amount);
    }

    fn get_protocol_fee_totals(self: @ContractState) -> (u128, u128) {
        let notes =
            ShieldedNotesExternalDispatcher { contract_address: self.shielded_notes.read() };
        notes.get_protocol_fee_totals()
    }

}

const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;
const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

fn pool_key_from_config(config: PoolConfig) -> PoolKey {
    let extension: ContractAddress = 0.try_into().expect('ADDRESS_RANGE');
    PoolKey {
        token0: config.token0,
        token1: config.token1,
        fee: config.fee,
        tick_spacing: config.tick_spacing,
        extension,
    }
}

fn bounds_from_ticks(tick_lower: i32, tick_upper: i32) -> Bounds {
    let lower_i128: i128 = tick_lower.try_into().expect('TICK_RANGE');
    let upper_i128: i128 = tick_upper.try_into().expect('TICK_RANGE');
    Bounds {
        lower: lower_i128.into(),
        upper: upper_i128.into(),
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
