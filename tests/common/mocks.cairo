use starknet::{ContractAddress, get_caller_address};
use starknet::storage::{
    Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
    StoragePointerWriteAccess,
};
use zylith::interfaces::IERC20::IERC20;
use zylith::core::PoolAdapter::IPoolAdapter;
use zylith::clmm::components::owned::IOwned;
use zylith::clmm::types::fees_per_liquidity::FeesPerLiquidity;
use zylith::privacy::ShieldedNotes::MerkleProof;

const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;
const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;

#[starknet::contract]
pub mod MockERC20 {
    use super::{ContractAddress, IERC20, Map, StorageMapReadAccess, StorageMapWriteAccess};
    use super::{StoragePointerReadAccess, StoragePointerWriteAccess, get_caller_address};
    use core::num::traits::Zero;

    #[storage]
    struct Storage {
        name: felt252,
        symbol: felt252,
        balances: Map<ContractAddress, u128>,
        allowances: Map<(ContractAddress, ContractAddress), u128>,
        total_supply: u128,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        starting_balance: u128,
        name: felt252,
        symbol: felt252,
    ) {
        self.name.write(name);
        self.symbol.write(symbol);
        self.total_supply.write(starting_balance);
        self.balances.write(owner, starting_balance);
    }

    #[abi(embed_v0)]
    impl ERC20Impl of IERC20<ContractState> {
        fn name(self: @ContractState) -> felt252 {
            self.name.read()
        }

        fn symbol(self: @ContractState) -> felt252 {
            self.symbol.read()
        }

        fn decimals(self: @ContractState) -> u8 {
            18
        }

        fn total_supply(self: @ContractState) -> u256 {
            self.total_supply.read().into()
        }

        fn balance_of(self: @ContractState, owner: ContractAddress) -> u256 {
            self.balances.read(owner).into()
        }

        fn allowance(self: @ContractState, owner: ContractAddress, spender: ContractAddress) -> u256 {
            self.allowances.read((owner, spender)).into()
        }

        fn transfer(ref self: ContractState, recipient: ContractAddress, amount: u256) -> bool {
            assert(amount.high.is_zero(), 'amount overflow');
            let sender = get_caller_address();
            let balance = self.balances.read(sender);
            assert(balance >= amount.low, 'insufficient balance');
            self.balances.write(sender, balance - amount.low);
            self.balances.write(recipient, self.balances.read(recipient) + amount.low);
            true
        }

        fn transfer_from(
            ref self: ContractState,
            sender: ContractAddress,
            recipient: ContractAddress,
            amount: u256,
        ) -> bool {
            assert(amount.high.is_zero(), 'amount overflow');
            let key = (sender, get_caller_address());
            let allowance = self.allowances.read(key);
            assert(allowance >= amount.low, 'insufficient allowance');
            let balance = self.balances.read(sender);
            assert(balance >= amount.low, 'insufficient balance');
            self.allowances.write(key, allowance - amount.low);
            self.balances.write(sender, balance - amount.low);
            self.balances.write(recipient, self.balances.read(recipient) + amount.low);
            true
        }

        fn approve(ref self: ContractState, spender: ContractAddress, amount: u256) -> bool {
            assert(amount.high.is_zero(), 'amount overflow');
            let owner = get_caller_address();
            self.allowances.write((owner, spender), amount.low);
            true
        }
    }

    #[abi(embed_v0)]
    impl MockImpl of MockERC20External<ContractState> {
        fn set_balance(ref self: ContractState, owner: ContractAddress, amount: u128) {
            self.balances.write(owner, amount);
        }

        fn mint(ref self: ContractState, owner: ContractAddress, amount: u128) {
            self.balances.write(owner, self.balances.read(owner) + amount);
            self.total_supply.write(self.total_supply.read() + amount);
        }
    }

    #[starknet::interface]
    pub trait MockERC20External<TContractState> {
        fn set_balance(ref self: TContractState, owner: ContractAddress, amount: u128);
        fn mint(ref self: TContractState, owner: ContractAddress, amount: u128);
    }
}

#[starknet::contract]
pub mod MockCore {
    use super::{ContractAddress, FeesPerLiquidity, IOwned};
    use super::{StoragePointerReadAccess, StoragePointerWriteAccess, get_caller_address};

    #[storage]
    struct Storage {
        owner: ContractAddress,
        authorized_adapter: ContractAddress,
        fee_inside_0: u256,
        fee_inside_1: u256,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        authorized_adapter: ContractAddress,
    ) {
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        assert(authorized_adapter.is_non_zero(), 'ADAPTER_ZERO');
        self.owner.write(owner);
        self.authorized_adapter.write(authorized_adapter);
        self.fee_inside_0.write(u256 { low: 0, high: 0 });
        self.fee_inside_1.write(u256 { low: 0, high: 0 });
    }

    #[abi(embed_v0)]
    impl OwnedImpl of IOwned<ContractState> {
        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }

        fn transfer_ownership(ref self: ContractState, new_owner: ContractAddress) {
            let caller = get_caller_address();
            assert(caller == self.owner.read(), 'owner only');
            self.owner.write(new_owner);
        }
    }

    #[abi(embed_v0)]
    impl CoreImpl of MockCoreExternal<ContractState> {
        fn get_authorized_adapter(self: @ContractState) -> ContractAddress {
            self.authorized_adapter.read()
        }

        fn set_fee_inside(ref self: ContractState, value0: u256, value1: u256) {
            self.fee_inside_0.write(value0);
            self.fee_inside_1.write(value1);
        }

        fn get_pool_fees_per_liquidity_inside(
            self: @ContractState,
            pool_key: zylith::clmm::types::keys::PoolKey,
            bounds: zylith::clmm::types::bounds::Bounds,
        ) -> FeesPerLiquidity {
            let _ = pool_key;
            let _ = bounds;
            FeesPerLiquidity { value0: self.fee_inside_0.read(), value1: self.fee_inside_1.read() }
        }
    }

    #[starknet::interface]
    pub trait MockCoreExternal<TContractState> {
        fn get_authorized_adapter(self: @TContractState) -> ContractAddress;
        fn set_fee_inside(ref self: TContractState, value0: u256, value1: u256);
        fn get_pool_fees_per_liquidity_inside(
            self: @TContractState,
            pool_key: zylith::clmm::types::keys::PoolKey,
            bounds: zylith::clmm::types::bounds::Bounds,
        ) -> FeesPerLiquidity;
    }
}

#[starknet::contract]
pub mod MockPoolAdapter {
    use super::{ContractAddress, HIGH_BIT_U128, IPoolAdapter, MAX_U128};
    use super::{StoragePointerReadAccess, StoragePointerWriteAccess, get_caller_address};
    use core::array::SpanTrait;
    use zylith::constants::generated as generated_constants;

    #[storage]
    struct Storage {
        core_address: ContractAddress,
        authorized_pool: ContractAddress,
        sqrt_price: u256,
        tick: i32,
        liquidity: u128,
        fee_growth_global_0: u256,
        fee_growth_global_1: u256,
        next_tick: i32,
        last_tick_spacing: u128,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        core_address: ContractAddress,
        authorized_pool: ContractAddress,
    ) {
        assert(authorized_pool.is_non_zero(), 'POOL_ZERO');
        self.core_address.write(core_address);
        self.authorized_pool.write(authorized_pool);
        self.sqrt_price.write(u256 { low: 0, high: 0 });
        self.tick.write(0);
        self.liquidity.write(0);
        self.fee_growth_global_0.write(u256 { low: 0, high: 0 });
        self.fee_growth_global_1.write(u256 { low: 0, high: 0 });
        self.next_tick.write(0);
        self.last_tick_spacing.write(0);
    }

    #[abi(embed_v0)]
    impl AdapterImpl of IPoolAdapter<ContractState> {
        fn get_core_address(self: @ContractState) -> ContractAddress {
            self.core_address.read()
        }

        fn get_authorized_pool(self: @ContractState) -> ContractAddress {
            self.authorized_pool.read()
        }

        fn get_sqrt_price(self: @ContractState) -> u256 {
            self.sqrt_price.read()
        }

        fn get_tick(self: @ContractState) -> i32 {
            self.tick.read()
        }

        fn get_liquidity(self: @ContractState) -> u128 {
            self.liquidity.read()
        }

        fn get_fee_growth_global(self: @ContractState) -> (u256, u256) {
            (self.fee_growth_global_0.read(), self.fee_growth_global_1.read())
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
            assert(get_caller_address() == self.authorized_pool.read(), 'not authorized');
            self.last_tick_spacing.write(tick_spacing);
            self.sqrt_price.write(sqrt_price);
            self.tick.write(tick);
            self.liquidity.write(liquidity);
            self.fee_growth_global_0.write(fee_growth_global_0);
            self.fee_growth_global_1.write(fee_growth_global_1);
        }

        fn apply_swap_state(ref self: ContractState, public_inputs: Span<u256>) {
            assert(get_caller_address() == self.authorized_pool.read(), 'not authorized');
            let sqrt_price_end = *public_inputs.at(4);
            let liquidity_before: u256 = *public_inputs.at(5);
            let max_steps: usize = generated_constants::MAX_SWAP_STEPS;
            let fee_growth_0_start: usize = 13 + (max_steps * 4);
            let fee_growth_1_start: usize = fee_growth_0_start + max_steps;
            let fee_growth_0_after = *public_inputs.at(fee_growth_0_start + (max_steps - 1));
            let fee_growth_1_after = *public_inputs.at(fee_growth_1_start + (max_steps - 1));

            self.sqrt_price.write(sqrt_price_end);
            self.liquidity.write(liquidity_before.low);
            self.fee_growth_global_0.write(fee_growth_0_after);
            self.fee_growth_global_1.write(fee_growth_1_after);
            self.tick.write(self.next_tick.read());
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
            let _ = tick_lower;
            let _ = tick_upper;
            let _ = fee;
            let _ = tick_spacing;
            let _ = protocol_fee_0;
            let _ = protocol_fee_1;
            let _ = token0;
            let _ = token1;
            assert(get_caller_address() == self.authorized_pool.read(), 'not authorized');
            let current = self.liquidity.read();
            let (sign, mag) = parse_liquidity_delta(liquidity_delta);
            let updated = if sign { current - mag } else { current + mag };
            self.liquidity.write(updated);
            self.fee_growth_global_0.write(fee_growth_global_0);
            self.fee_growth_global_1.write(fee_growth_global_1);
        }

        fn apply_protocol_fee_withdraw(
            ref self: ContractState,
            token: ContractAddress,
            amount: u128,
        ) {
            let _ = token;
            let _ = amount;
            assert(get_caller_address() == self.authorized_pool.read(), 'not authorized');
        }
    }

    #[abi(embed_v0)]
    impl MockImpl of MockPoolAdapterExternal<ContractState> {
        fn set_next_tick(ref self: ContractState, tick: i32) {
            self.next_tick.write(tick);
        }

        fn get_last_tick_spacing(self: @ContractState) -> u128 {
            self.last_tick_spacing.read()
        }
    }

    #[starknet::interface]
    pub trait MockPoolAdapterExternal<TContractState> {
        fn set_next_tick(ref self: TContractState, tick: i32);
        fn get_last_tick_spacing(self: @TContractState) -> u128;
    }

    fn parse_liquidity_delta(delta: u256) -> (bool, u128) {
        assert(delta.high == 0, 'LIQ_DELTA_HIGH');
        if delta.low < HIGH_BIT_U128 {
            (false, delta.low)
        } else {
            let mag = if delta.low == HIGH_BIT_U128 {
                HIGH_BIT_U128
            } else {
                (MAX_U128 - delta.low) + 1
            };
            (true, mag)
        }
    }
}

#[starknet::contract]
pub mod MockShieldedNotes {
    use super::{
        ContractAddress, Map, StorageMapReadAccess, StorageMapWriteAccess, MerkleProof,
        StoragePointerReadAccess, StoragePointerWriteAccess,
    };
    use core::array::SpanTrait;

    #[storage]
    struct Storage {
        token0: ContractAddress,
        token1: ContractAddress,
        authorized_pool: ContractAddress,
        root0: felt252,
        root1: felt252,
        root_position: felt252,
        nullifiers: Map<felt252, bool>,
        next_index0: u64,
        next_index1: u64,
        next_index_position: u64,
        protocol_fee_total_0: u128,
        protocol_fee_total_1: u128,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(
        ref self: ContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        authorized_pool: ContractAddress,
        root0: felt252,
        root1: felt252,
        root_position: felt252,
    ) {
        self.token0.write(token0);
        self.token1.write(token1);
        assert(authorized_pool.is_non_zero(), 'POOL_ZERO');
        self.authorized_pool.write(authorized_pool);
        self.root0.write(root0);
        self.root1.write(root1);
        self.root_position.write(root_position);
        self.next_index0.write(0);
        self.next_index1.write(0);
        self.next_index_position.write(0);
        self.protocol_fee_total_0.write(0);
        self.protocol_fee_total_1.write(0);
    }

    #[abi(embed_v0)]
    impl ExternalImpl of MockShieldedNotesExternal<ContractState> {
        fn get_token0(self: @ContractState) -> ContractAddress {
            self.token0.read()
        }

        fn get_token1(self: @ContractState) -> ContractAddress {
            self.token1.read()
        }

        fn get_authorized_pool(self: @ContractState) -> ContractAddress {
            self.authorized_pool.read()
        }
    }

    #[abi(embed_v0)]
    impl NotesImpl of MockShieldedNotesCore<ContractState> {
        fn is_nullifier_used(self: @ContractState, nullifier: felt252) -> bool {
            self.nullifiers.read(nullifier)
        }

        fn verify_membership(self: @ContractState, token: ContractAddress, proof: MerkleProof) -> bool {
            let _ = token;
            let _ = proof;
            true
        }

        fn verify_position_membership(self: @ContractState, proof: MerkleProof) -> bool {
            let _ = proof;
            true
        }

        fn is_known_root(self: @ContractState, token: ContractAddress, root: felt252) -> bool {
            if token == self.token0.read() { root == self.root0.read() } else { root == self.root1.read() }
        }

        fn is_known_position_root(self: @ContractState, root: felt252) -> bool {
            root == self.root_position.read()
        }

        fn append_commitment(
            ref self: ContractState,
            commitment: felt252,
            token: ContractAddress,
            proof: MerkleProof,
        ) -> u64 {
            let _ = commitment;
            let _ = proof;
            if token == self.token0.read() {
                let idx = self.next_index0.read();
                self.next_index0.write(idx + 1);
                idx
            } else {
                let idx = self.next_index1.read();
                self.next_index1.write(idx + 1);
                idx
            }
        }

        fn append_position_commitment(
            ref self: ContractState, commitment: felt252, proof: MerkleProof
        ) -> u64 {
            let _ = commitment;
            let _ = proof;
            let idx = self.next_index_position.read();
            self.next_index_position.write(idx + 1);
            idx
        }

        fn mark_nullifier_used(ref self: ContractState, nullifier: felt252) {
            self.nullifiers.write(nullifier, true);
        }

        fn mark_nullifiers_used(ref self: ContractState, nullifiers: Span<felt252>) {
            let mut idx: usize = 0;
            while idx < nullifiers.len() {
                let value = *nullifiers.at(idx);
                self.nullifiers.write(value, true);
                idx += 1;
            }
        }

        fn accrue_protocol_fees(
            ref self: ContractState,
            token: ContractAddress,
            amount: u128,
        ) {
            if token == self.token0.read() {
                self.protocol_fee_total_0.write(self.protocol_fee_total_0.read() + amount);
            } else {
                self.protocol_fee_total_1.write(self.protocol_fee_total_1.read() + amount);
            }
        }

        fn withdraw_protocol_fees(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u128,
        ) {
            let _ = recipient;
            if token == self.token0.read() {
                let current = self.protocol_fee_total_0.read();
                self.protocol_fee_total_0.write(current - amount);
            } else {
                let current = self.protocol_fee_total_1.read();
                self.protocol_fee_total_1.write(current - amount);
            }
        }

        fn flush_pending_roots(ref self: ContractState) {
            let _ = 0;
        }
    }

    #[abi(embed_v0)]
    impl MockImpl of MockShieldedNotesAdmin<ContractState> {
        fn set_roots(
            ref self: ContractState, root0: felt252, root1: felt252, root_position: felt252
        ) {
            self.root0.write(root0);
            self.root1.write(root1);
            self.root_position.write(root_position);
        }

        fn get_commitment_counts(self: @ContractState) -> (u64, u64, u64) {
            (
                self.next_index0.read(),
                self.next_index1.read(),
                self.next_index_position.read(),
            )
        }

        fn get_protocol_fee_totals(self: @ContractState) -> (u128, u128) {
            (self.protocol_fee_total_0.read(), self.protocol_fee_total_1.read())
        }
    }

    #[starknet::interface]
    pub trait MockShieldedNotesExternal<TContractState> {
        fn get_token0(self: @TContractState) -> ContractAddress;
        fn get_token1(self: @TContractState) -> ContractAddress;
        fn get_authorized_pool(self: @TContractState) -> ContractAddress;
    }

    #[starknet::interface]
    pub trait MockShieldedNotesCore<TContractState> {
        fn is_nullifier_used(self: @TContractState, nullifier: felt252) -> bool;
        fn verify_membership(
            self: @TContractState, token: ContractAddress, proof: MerkleProof
        ) -> bool;
        fn verify_position_membership(self: @TContractState, proof: MerkleProof) -> bool;
        fn is_known_root(self: @TContractState, token: ContractAddress, root: felt252) -> bool;
        fn is_known_position_root(self: @TContractState, root: felt252) -> bool;
        fn append_commitment(
            ref self: TContractState,
            commitment: felt252,
            token: ContractAddress,
            proof: MerkleProof,
        ) -> u64;
        fn append_position_commitment(
            ref self: TContractState, commitment: felt252, proof: MerkleProof
        ) -> u64;
        fn mark_nullifier_used(ref self: TContractState, nullifier: felt252);
        fn mark_nullifiers_used(ref self: TContractState, nullifiers: Span<felt252>);
        fn accrue_protocol_fees(
            ref self: TContractState, token: ContractAddress, amount: u128
        );
        fn withdraw_protocol_fees(
            ref self: TContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u128,
        );
        fn flush_pending_roots(ref self: TContractState);
    }

    #[starknet::interface]
    pub trait MockShieldedNotesAdmin<TContractState> {
        fn set_roots(
            ref self: TContractState, root0: felt252, root1: felt252, root_position: felt252
        );
        fn get_commitment_counts(self: @TContractState) -> (u64, u64, u64);
        fn get_protocol_fee_totals(self: @TContractState) -> (u128, u128);
    }
}

#[starknet::contract]
pub mod MockGaragaVerifier {
    use core::array::{ArrayTrait, SpanTrait};
    use core::option::{Option, OptionTrait};
    use core::traits::TryInto;
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use zylith::privacy::ZylithVerifier::IGaragaVerifier;

    #[storage]
    struct Storage {
        outputs_len: u32,
        outputs: Map<u32, u256>,
        should_verify: bool,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {}

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.should_verify.write(true);
    }

    #[abi(embed_v0)]
    impl MockImpl of MockGaragaVerifierExternal<ContractState> {
        fn set_outputs(ref self: ContractState, outputs: Span<u256>) {
            self.outputs_len.write(outputs.len().try_into().unwrap());
            let mut idx: usize = 0;
            while idx < outputs.len() {
                let key: u32 = idx.try_into().unwrap();
                self.outputs.write(key, *outputs.at(idx));
                idx += 1;
            }
        }

        fn set_should_verify(ref self: ContractState, value: bool) {
            self.should_verify.write(value);
        }
    }

    #[starknet::interface]
    pub trait MockGaragaVerifierExternal<TContractState> {
        fn set_outputs(ref self: TContractState, outputs: Span<u256>);
        fn set_should_verify(ref self: TContractState, value: bool);
    }

    #[abi(embed_v0)]
    impl GaragaImpl of IGaragaVerifier<ContractState> {
        fn verify_groth16_proof_bn254(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let _ = calldata;
            if !self.should_verify.read() {
                return Option::None;
            }
            let mut outputs: Array<u256> = array![];
            let len: usize = self.outputs_len.read().try_into().unwrap();
            let mut idx: usize = 0;
            while idx < len {
                let key: u32 = idx.try_into().unwrap();
                outputs.append(self.outputs.read(key));
                idx += 1;
            }
            Option::Some(outputs.span())
        }
    }
}
