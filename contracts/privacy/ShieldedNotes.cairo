// shielded note registry storing commitments while only tracking Merkle roots on-chain.
// this avoids leaking tree structure and access patterns (no sparse node storage). delegates nullifier tracking and root history to dedicated components, commitments are fully caller-supplied.
use starknet::ContractAddress;
use core::poseidon::hades_permutation;
use starknet::{get_block_timestamp, get_contract_address};
use crate::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use crate::constants::generated as generated_constants;

#[derive(Copy, Drop, Serde)]
pub struct MerkleProof {
    // for insertions, commitment must be ZERO_LEAF_HASH and root must be the current root
    pub root: felt252,
    pub commitment: felt252,
    pub leaf_index: u64,
    pub path: Span<felt252>,
    pub indices: Span<bool>,
}

const MERKLE_HEIGHT: usize = generated_constants::TREE_HEIGHT.into();
const ROOT_BATCH_SIZE: u64 = 100;
const ROOT_BATCH_DELAY_SECS: u64 = 300;

fn zero_leaf_hash() -> felt252 {
    generated_constants::ZERO_LEAF_HASH
}

fn max_leaves() -> u64 {
    let mut leaves: u64 = 1;
    let mut level: usize = 0;
    while level < MERKLE_HEIGHT {
        leaves = leaves * 2;
        level += 1;
    }
    leaves
}

fn poseidon_hash_pair(left: felt252, right: felt252) -> felt252 {
    let (s0, _, _) = hades_permutation(left, right, 2);
    s0
}

fn assert_zero_leaf_hash() {
    let derived = poseidon_hash_pair(0, 0);
    assert(derived == zero_leaf_hash(), 'ZERO_LEAF_HASH_MISMATCH');
}

fn is_authorized(pool: ContractAddress) -> bool {
    let caller = starknet::get_caller_address();
    caller == pool
}

#[starknet::interface]
pub trait ShieldedNotesExternal<TContractState> {
    fn deposit_token0(
        ref self: TContractState, calldata: Span<felt252>, proof: MerkleProof
    ) -> felt252;
    fn deposit_token1(
        ref self: TContractState, calldata: Span<felt252>, proof: MerkleProof
    ) -> felt252;
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
    fn accrue_protocol_fees(ref self: TContractState, token: ContractAddress, amount: u128);
    fn withdraw_protocol_fees(
        ref self: TContractState,
        token: ContractAddress,
        recipient: ContractAddress,
        amount: u128,
    );
    fn get_protocol_fee_totals(self: @TContractState) -> (u128, u128);
    fn verify_membership(
        self: @TContractState, token: ContractAddress, proof: MerkleProof
    ) -> bool;
    fn verify_position_membership(self: @TContractState, proof: MerkleProof) -> bool;
    fn withdraw_token0(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof: MerkleProof,
    );
    fn withdraw_token1(
        ref self: TContractState,
        calldata: Span<felt252>,
        proof: MerkleProof,
    );
    fn is_known_root(self: @TContractState, token: ContractAddress, root: felt252) -> bool;
    fn is_known_position_root(self: @TContractState, root: felt252) -> bool;
    fn is_nullifier_used(self: @TContractState, nullifier: felt252) -> bool;
    fn flush_pending_roots(ref self: TContractState);
    fn get_token0(self: @TContractState) -> ContractAddress;
    fn get_token1(self: @TContractState) -> ContractAddress;
    fn get_authorized_pool(self: @TContractState) -> ContractAddress;
}

#[starknet::interface]
pub trait ShieldedNotesAdmin<TContractState> {
    fn set_authorized_pool(ref self: TContractState, authorized_pool: ContractAddress);
    fn get_owner(self: @TContractState) -> ContractAddress;
}

#[allow(starknet::colliding_storage_paths)]
#[allow(starknet::colliding_storage_paths)]
#[starknet::contract]
pub mod ShieldedNotes {
    use super::{
        ContractAddress, MerkleProof, ShieldedNotesExternal, ShieldedNotesAdmin, IERC20Dispatcher,
        IERC20DispatcherTrait, MERKLE_HEIGHT, ROOT_BATCH_DELAY_SECS, ROOT_BATCH_SIZE,
        get_block_timestamp, get_contract_address, is_authorized, poseidon_hash_pair,
        zero_leaf_hash, max_leaves, assert_zero_leaf_hash,
    };
    use core::array::SpanTrait;
    use core::num::traits::Zero;
    use core::option::Option;
    use crate::privacy::HistoricalRoots0::HistoricalRoots0 as HistoricalRootsComponent0;
    use crate::privacy::HistoricalRoots1::HistoricalRoots1 as HistoricalRootsComponent1;
    use crate::privacy::HistoricalRootsPosition::HistoricalRootsPosition as HistoricalRootsComponentPosition;
    use crate::privacy::NullifierRegistry::NullifierRegistry as NullifierRegistryComponent;
    use crate::privacy::ZylithVerifier::{
        DepositPublicOutputs, IZylithVerifierDispatcher, IZylithVerifierDispatcherTrait,
        WithdrawPublicOutputs,
    };
    use crate::clmm::math::fee::accumulate_fee_amount;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    component!(path: NullifierRegistryComponent, storage: nullifier_registry, event: NullifierEvent);
    impl Nullifiers = NullifierRegistryComponent::NullifierRegistryImpl<ContractState>;

    component!(path: HistoricalRootsComponent0, storage: historical_roots0, event: HistoricalRootsEvent0);
    impl Roots0 = HistoricalRootsComponent0::HistoricalRootsImpl<ContractState>;

    component!(path: HistoricalRootsComponent1, storage: historical_roots1, event: HistoricalRootsEvent1);
    impl Roots1 = HistoricalRootsComponent1::HistoricalRootsImpl<ContractState>;

    component!(path: HistoricalRootsComponentPosition, storage: historical_roots_position, event: HistoricalRootsEventPosition);
    impl RootsPosition = HistoricalRootsComponentPosition::HistoricalRootsImpl<ContractState>;

    #[storage]
    #[allow(starknet::colliding_storage_paths)]
    struct Storage {
        #[substorage(v0)]
        nullifier_registry: NullifierRegistryComponent::Storage,
        #[substorage(v0)]
        historical_roots0: HistoricalRootsComponent0::Storage,
        #[allow(starknet::colliding_storage_paths)]
        #[substorage(v0)]
        historical_roots1: HistoricalRootsComponent1::Storage,
        #[allow(starknet::colliding_storage_paths)]
        #[substorage(v0)]
        historical_roots_position: HistoricalRootsComponentPosition::Storage,
        // root-only storage: the tree is maintained off-chain (ASP).
        root0: felt252,
        root1: felt252,
        root_position: felt252,
        next_index0: u64,
        next_index1: u64,
        next_index_position: u64,
        pending_roots0: Map<u64, felt252>,
        pending_roots1: Map<u64, felt252>,
        pending_roots_position: Map<u64, felt252>,
        pending_root0_index: u64,
        pending_root1_index: u64,
        pending_root_position_index: u64,
        pending_root0_count: u64,
        pending_root1_count: u64,
        pending_root_position_count: u64,
        pending_root0_since: u64,
        pending_root1_since: u64,
        pending_root_position_since: u64,
        owner: ContractAddress,
        token0: ContractAddress,
        token1: ContractAddress,
        authorized_pool: ContractAddress,
        verifier: ContractAddress,
        reentrancy_lock: bool,
        // protocol fee balances remain in ShieldedNotes and are withdrawn via the pool.
        protocol_fee_total_0: u128,
        protocol_fee_total_1: u128,
    }

    #[derive(Drop, starknet::Event)]
    pub struct Deposit {
        pub commitment: felt252,
        pub leaf_index: u64,
        pub token: ContractAddress,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct RootUpdated {
        pub old_root: felt252,
        pub new_root: felt252,
        pub root_index: u64,
        pub token: ContractAddress,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PositionCommitmentInserted {
        pub commitment: felt252,
        pub leaf_index: u64,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct PositionRootUpdated {
        pub old_root: felt252,
        pub new_root: felt252,
        pub root_index: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NullifierMarked {
        pub nullifier: felt252,
        pub timestamp: u64,
    }

    #[derive(Drop, starknet::Event)]
    pub struct AuthorizedPoolUpdated {
        pub old_pool: ContractAddress,
        pub new_pool: ContractAddress,
        pub timestamp: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        Deposit: Deposit,
        RootUpdated: RootUpdated,
        PositionCommitmentInserted: PositionCommitmentInserted,
        PositionRootUpdated: PositionRootUpdated,
        NullifierMarked: NullifierMarked,
        AuthorizedPoolUpdated: AuthorizedPoolUpdated,
        #[flat]
        NullifierEvent: NullifierRegistryComponent::Event,
        #[flat]
        HistoricalRootsEvent0: HistoricalRootsComponent0::Event,
        #[flat]
        HistoricalRootsEvent1: HistoricalRootsComponent1::Event,
        #[flat]
        HistoricalRootsEventPosition: HistoricalRootsComponentPosition::Event,
    }

    fn empty_root() -> felt252 {
        let mut hash_ = zero_leaf_hash();
        let mut level: usize = 0;
        while level < MERKLE_HEIGHT {
            hash_ = poseidon_hash_pair(hash_, hash_);
            level += 1;
        }
        hash_
    }

    fn compute_root_from_path(
        leaf: felt252,
        mut index: u64,
        path: Span<felt252>,
        indices: Span<bool>,
    ) -> felt252 {
        assert(path.len() == indices.len(), 'PROOF_LENGTH');
        assert(path.len() == MERKLE_HEIGHT, 'INVALID_PROOF_DEPTH');
        let mut hash_ = leaf;
        let mut i: usize = 0;
        while i < path.len() {
            let sibling = *path.at(i);
            let is_right = *indices.at(i);
            assert(((index % 2) == 1) == is_right, 'PATH_DIR_MISMATCH');
            hash_ = if is_right {
                poseidon_hash_pair(sibling, hash_)
            } else {
                poseidon_hash_pair(hash_, sibling)
            };
            index /= 2;
            i += 1;
        }
        hash_
    }

    fn try_compute_root_from_path(
        leaf: felt252,
        mut index: u64,
        path: Span<felt252>,
        indices: Span<bool>,
    ) -> Option<felt252> {
        if path.len() != indices.len() {
            return Option::None;
        }
        if path.len() != MERKLE_HEIGHT {
            return Option::None;
        }
        let mut hash_ = leaf;
        let mut i: usize = 0;
        while i < path.len() {
            let sibling = *path.at(i);
            let is_right = *indices.at(i);
            if ((index % 2) == 1) != is_right {
                return Option::None;
            }
            hash_ = if is_right {
                poseidon_hash_pair(sibling, hash_)
            } else {
                poseidon_hash_pair(hash_, sibling)
            };
            index /= 2;
            i += 1;
        }
        Option::Some(hash_)
    }


    #[constructor]
    fn constructor(
        ref self: ContractState,
        token0: ContractAddress,
        token1: ContractAddress,
        authorized_pool: ContractAddress,
        verifier: ContractAddress,
        owner: ContractAddress,
    ) {
        assert_zero_leaf_hash();
        self.nullifier_registry.nullifier_count.write(0);
        self.historical_roots0.initializer();
        self.historical_roots1.initializer();
        self.historical_roots_position.initializer();

        assert(token0.is_non_zero(), 'TOKEN0_ZERO');
        assert(token1.is_non_zero(), 'TOKEN1_ZERO');
        assert(token0 < token1, 'TOKEN_ORDER');
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        self.owner.write(owner);
        assert(verifier.is_non_zero(), 'VERIFIER_ZERO');
        self.token0.write(token0);
        self.token1.write(token1);
        self.authorized_pool.write(authorized_pool);
        self.verifier.write(verifier);
        self.reentrancy_lock.write(false);

        // seed root history with initial empty roots
        let initial_root0 = empty_root();
        self.root0.write(initial_root0);
        self.next_index0.write(0);
        let idx0 = self.historical_roots0.add_root(initial_root0);
        self.emit(
            RootUpdated {
                old_root: 0, new_root: initial_root0, root_index: idx0, token: token0,
            },
        );
        let initial_root1 = initial_root0;
        self.root1.write(initial_root1);
        self.next_index1.write(0);
        let idx1 = self.historical_roots1.add_root(initial_root1);
        self.emit(
            RootUpdated {
                old_root: 0, new_root: initial_root1, root_index: idx1, token: token1,
            },
        );

        let initial_root_position = initial_root0;
        self.root_position.write(initial_root_position);
        self.next_index_position.write(0);
        let idx_position = self.historical_roots_position.add_root(initial_root_position);
        self.emit(
            PositionRootUpdated {
                old_root: 0, new_root: initial_root_position, root_index: idx_position,
            },
        );
    }

    // Inserts commitment into the token-specific tree, returns leaf index, batches root history updates.
    // The caller supplies a Merkle proof for the empty leaf at next_index so we can update roots without storing internal nodes on-chain.
    fn insert_token_commitment(
        ref self: ContractState,
        commitment: felt252,
        token: ContractAddress,
        proof: MerkleProof,
    ) -> u64 {
        assert(commitment != 0, 'COMMITMENT_ZERO');
        assert(commitment != zero_leaf_hash(), 'COMMITMENT_ZERO_HASH');
        let token0 = self.token0.read();
        let token1 = self.token1.read();
        assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
        assert(proof.commitment == zero_leaf_hash(), 'EXPECTED_ZERO_LEAF');
        let (leaf_index, current_root) = if token == token0 {
            (self.next_index0.read(), self.root0.read())
        } else {
            (self.next_index1.read(), self.root1.read())
        };
        assert(leaf_index < max_leaves(), 'TREE_FULL');
        assert(proof.leaf_index == leaf_index, 'LEAF_INDEX_MISMATCH');
        assert(proof.root == current_root, 'ROOT_MISMATCH');
        let old_root =
            compute_root_from_path(zero_leaf_hash(), proof.leaf_index, proof.path, proof.indices);
        assert(old_root == current_root, 'PROOF_INVALID');
        let new_root =
            compute_root_from_path(commitment, proof.leaf_index, proof.path, proof.indices);
        if token == token0 {
            self.root0.write(new_root);
            self.next_index0.write(leaf_index + 1);
        } else {
            self.root1.write(new_root);
            self.next_index1.write(leaf_index + 1);
        }
        record_root_batch_token(ref self, token, new_root);

        self.emit(
            Deposit {
                commitment,
                leaf_index,
                token,
                timestamp: get_block_timestamp(),
            },
        );

        leaf_index
    }

    fn insert_position_commitment(
        ref self: ContractState,
        commitment: felt252,
        proof: MerkleProof,
    ) -> u64 {
        assert(commitment != 0, 'COMMITMENT_ZERO');
        assert(commitment != zero_leaf_hash(), 'COMMITMENT_ZERO_HASH');
        assert(proof.commitment == zero_leaf_hash(), 'EXPECTED_ZERO_LEAF');
        let leaf_index = self.next_index_position.read();
        let current_root = self.root_position.read();
        assert(leaf_index < max_leaves(), 'TREE_FULL');
        assert(proof.leaf_index == leaf_index, 'LEAF_INDEX_MISMATCH');
        assert(proof.root == current_root, 'ROOT_MISMATCH');
        let old_root =
            compute_root_from_path(zero_leaf_hash(), proof.leaf_index, proof.path, proof.indices);
        assert(old_root == current_root, 'PROOF_INVALID');
        let new_root =
            compute_root_from_path(commitment, proof.leaf_index, proof.path, proof.indices);
        self.root_position.write(new_root);
        self.next_index_position.write(leaf_index + 1);
        record_root_batch_position(ref self, new_root);

        self.emit(
            PositionCommitmentInserted {
                commitment,
                leaf_index,
                timestamp: get_block_timestamp(),
            },
        );

        leaf_index
    }

    // maintain a rolling buffer of the last ROOT_HISTORY roots via HistoricalRoots component
    fn update_root_history(
        ref self: ContractState, old_root: felt252, new_root: felt252, root_index: u64, token: ContractAddress
    ) {
        self.emit(RootUpdated { old_root, new_root, root_index, token });
    }

    fn update_position_root_history(
        ref self: ContractState, old_root: felt252, new_root: felt252, root_index: u64
    ) {
        self.emit(PositionRootUpdated { old_root, new_root, root_index });
    }

    fn record_root_batch_token(
        ref self: ContractState,
        token: ContractAddress,
        new_root: felt252,
    ) {
        let now = get_block_timestamp();
        let token0 = self.token0.read();
        let token1 = self.token1.read();
        assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
        if token == token0 {
            let mut count = self.pending_root0_count.read();
            let mut since = self.pending_root0_since.read();
            let mut index = self.pending_root0_index.read();
            if count == 0 {
                since = now;
                self.pending_root0_since.write(now);
            }
            self.pending_roots0.write(index, new_root);
            index = (index + 1) % ROOT_BATCH_SIZE;
            self.pending_root0_index.write(index);
            if count < ROOT_BATCH_SIZE {
                count = count + 1;
            } else {
                count = ROOT_BATCH_SIZE;
            }
            self.pending_root0_count.write(count);
            if should_flush_roots(count, since, now) {
                flush_pending_roots0(ref self);
            }
        } else {
            let mut count = self.pending_root1_count.read();
            let mut since = self.pending_root1_since.read();
            let mut index = self.pending_root1_index.read();
            if count == 0 {
                since = now;
                self.pending_root1_since.write(now);
            }
            self.pending_roots1.write(index, new_root);
            index = (index + 1) % ROOT_BATCH_SIZE;
            self.pending_root1_index.write(index);
            if count < ROOT_BATCH_SIZE {
                count = count + 1;
            } else {
                count = ROOT_BATCH_SIZE;
            }
            self.pending_root1_count.write(count);
            if should_flush_roots(count, since, now) {
                flush_pending_roots1(ref self);
            }
        }
    }

    fn record_root_batch_position(ref self: ContractState, new_root: felt252) {
        let now = get_block_timestamp();
        let mut count = self.pending_root_position_count.read();
        let mut since = self.pending_root_position_since.read();
        let mut index = self.pending_root_position_index.read();
        if count == 0 {
            since = now;
            self.pending_root_position_since.write(now);
        }
        self.pending_roots_position.write(index, new_root);
        index = (index + 1) % ROOT_BATCH_SIZE;
        self.pending_root_position_index.write(index);
        if count < ROOT_BATCH_SIZE {
            count = count + 1;
        } else {
            count = ROOT_BATCH_SIZE;
        }
        self.pending_root_position_count.write(count);
        if should_flush_roots(count, since, now) {
            flush_pending_roots_position(ref self);
        }
    }

    fn flush_pending_roots0(ref self: ContractState) {
        let count = self.pending_root0_count.read();
        if count == 0 {
            return ();
        }
        let mut start = self.pending_root0_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let token = self.token0.read();
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            let root = self.pending_roots0.read(idx);
            let old_root = self.historical_roots0.get_current_root();
            let root_index = self.historical_roots0.add_root(root);
            update_root_history(ref self, old_root, root, root_index, token);
            i += 1;
        }
        self.pending_root0_count.write(0);
        self.pending_root0_since.write(0);
    }

    fn flush_pending_roots1(ref self: ContractState) {
        let count = self.pending_root1_count.read();
        if count == 0 {
            return ();
        }
        let mut start = self.pending_root1_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let token = self.token1.read();
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            let root = self.pending_roots1.read(idx);
            let old_root = self.historical_roots1.get_current_root();
            let root_index = self.historical_roots1.add_root(root);
            update_root_history(ref self, old_root, root, root_index, token);
            i += 1;
        }
        self.pending_root1_count.write(0);
        self.pending_root1_since.write(0);
    }

    fn flush_pending_roots_position(ref self: ContractState) {
        let count = self.pending_root_position_count.read();
        if count == 0 {
            return ();
        }
        let mut start = self.pending_root_position_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            let root = self.pending_roots_position.read(idx);
            let old_root = self.historical_roots_position.get_current_root();
            let root_index = self.historical_roots_position.add_root(root);
            update_position_root_history(ref self, old_root, root, root_index);
            i += 1;
        }
        self.pending_root_position_count.write(0);
        self.pending_root_position_since.write(0);
    }

    fn pending_contains_root0(self: @ContractState, root: felt252) -> bool {
        let count = self.pending_root0_count.read();
        if count == 0 {
            return false;
        }
        let mut start = self.pending_root0_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            if self.pending_roots0.read(idx) == root {
                return true;
            }
            i += 1;
        }
        false
    }

    fn pending_contains_root1(self: @ContractState, root: felt252) -> bool {
        let count = self.pending_root1_count.read();
        if count == 0 {
            return false;
        }
        let mut start = self.pending_root1_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            if self.pending_roots1.read(idx) == root {
                return true;
            }
            i += 1;
        }
        false
    }

    fn pending_contains_root_position(self: @ContractState, root: felt252) -> bool {
        let count = self.pending_root_position_count.read();
        if count == 0 {
            return false;
        }
        let mut start = self.pending_root_position_index.read();
        if count < ROOT_BATCH_SIZE {
            start = (start + ROOT_BATCH_SIZE - count) % ROOT_BATCH_SIZE;
        }
        let mut i: u64 = 0;
        while i < count {
            let idx = (start + i) % ROOT_BATCH_SIZE;
            if self.pending_roots_position.read(idx) == root {
                return true;
            }
            i += 1;
        }
        false
    }

    fn is_known_root_internal(
        self: @ContractState, token: ContractAddress, root: felt252
    ) -> bool {
        let token0 = self.token0.read();
        let token1 = self.token1.read();
        assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
        let live = if token == token0 {
            self.root0.read()
        } else {
            self.root1.read()
        };
        if root == live {
            return true;
        }
        if token == token0 {
            if pending_contains_root0(self, root) {
                return true;
            }
            self.historical_roots0.is_known_root(root)
        } else {
            if pending_contains_root1(self, root) {
                return true;
            }
            self.historical_roots1.is_known_root(root)
        }
    }

    fn is_known_position_root_internal(self: @ContractState, root: felt252) -> bool {
        let live = self.root_position.read();
        if root == live {
            return true;
        }
        if pending_contains_root_position(self, root) {
            return true;
        }
        self.historical_roots_position.is_known_root(root)
    }

    fn should_flush_roots(count: u64, since: u64, now: u64) -> bool {
        if count >= ROOT_BATCH_SIZE {
            return true;
        }
        if now < since {
            return true;
        }
        (now - since) >= ROOT_BATCH_DELAY_SECS
    }

    fn enter_non_reentrant(ref self: ContractState) {
        assert(!self.reentrancy_lock.read(), 'REENTRANCY');
        self.reentrancy_lock.write(true);
    }

    fn exit_non_reentrant(ref self: ContractState) {
        self.reentrancy_lock.write(false);
    }

    fn require_initialized(self: @ContractState) {
        assert(self.authorized_pool.read().is_non_zero(), 'NOT_INITIALIZED');
    }

    fn verify_membership_proof(
        self: @ContractState, token: ContractAddress, proof: MerkleProof
    ) -> bool {
        let token0 = self.token0.read();
        let token1 = self.token1.read();
        if (token != token0) & (token != token1) {
            return false;
        }
        if (proof.commitment == 0) | (proof.commitment == zero_leaf_hash()) {
            return false;
        }
        let next_index = if token == token0 {
            self.next_index0.read()
        } else {
            self.next_index1.read()
        };
        if proof.leaf_index >= next_index {
            return false;
        }
        if proof.leaf_index >= max_leaves() {
            return false;
        }
        let current = match try_compute_root_from_path(
            proof.commitment, proof.leaf_index, proof.path, proof.indices
        ) {
            Option::Some(root) => root,
            Option::None => {
                return false;
            },
        };
        if current != proof.root {
            return false;
        }
        is_known_root_internal(self, token, current)
    }

    fn verify_position_membership_proof(
        self: @ContractState, proof: MerkleProof
    ) -> bool {
        if (proof.commitment == 0) | (proof.commitment == zero_leaf_hash()) {
            return false;
        }
        let next_index = self.next_index_position.read();
        if proof.leaf_index >= next_index {
            return false;
        }
        if proof.leaf_index >= max_leaves() {
            return false;
        }
        let current = match try_compute_root_from_path(
            proof.commitment, proof.leaf_index, proof.path, proof.indices
        ) {
            Option::Some(root) => root,
            Option::None => {
                return false;
            },
        };
        if current != proof.root {
            return false;
        }
        is_known_position_root_internal(self, current)
    }

    #[abi(embed_v0)]
    impl ExternalImpl of ShieldedNotesExternal<ContractState> {
        fn deposit_token0(
            ref self: ContractState, calldata: Span<felt252>, proof: MerkleProof
        ) -> felt252 {
            self.flush_pending_roots();
            let token = self.token0.read();
            self.handle_deposit(calldata, proof, token, 0)
        }

        fn deposit_token1(
            ref self: ContractState, calldata: Span<felt252>, proof: MerkleProof
        ) -> felt252 {
            self.flush_pending_roots();
            let token = self.token1.read();
            self.handle_deposit(calldata, proof, token, 1)
        }

        fn append_commitment(
            ref self: ContractState,
            commitment: felt252,
            token: ContractAddress,
            proof: MerkleProof,
        ) -> u64 {
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            let token0 = self.token0.read();
            let token1 = self.token1.read();
            assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
            insert_token_commitment(ref self, commitment, token, proof)
        }

        fn append_position_commitment(
            ref self: ContractState, commitment: felt252, proof: MerkleProof
        ) -> u64 {
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            insert_position_commitment(ref self, commitment, proof)
        }

        fn mark_nullifier_used(ref self: ContractState, nullifier: felt252) {
            // nullifier freshness is global state, must be enforced on-chain
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            self.nullifier_registry.mark_used(nullifier);
            self.emit(NullifierMarked { nullifier, timestamp: get_block_timestamp() });
        }

        fn mark_nullifiers_used(ref self: ContractState, nullifiers: Span<felt252>) {
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            let mut idx: usize = 0;
            while idx < nullifiers.len() {
                let nullifier = *nullifiers.at(idx);
                self.nullifier_registry.mark_used(nullifier);
                self.emit(NullifierMarked { nullifier, timestamp: get_block_timestamp() });
                idx += 1;
            }
        }

        fn accrue_protocol_fees(
            ref self: ContractState,
            token: ContractAddress,
            amount: u128,
        ) {
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            let token0 = self.token0.read();
            let token1 = self.token1.read();
            assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
            if amount == 0 {
                return ();
            }
            if token == token0 {
                let current = self.protocol_fee_total_0.read();
                self.protocol_fee_total_0.write(accumulate_fee_amount(current, amount));
            } else {
                let current = self.protocol_fee_total_1.read();
                self.protocol_fee_total_1.write(accumulate_fee_amount(current, amount));
            }
        }

        fn withdraw_protocol_fees(
            ref self: ContractState,
            token: ContractAddress,
            recipient: ContractAddress,
            amount: u128,
        ) {
            assert(is_authorized(self.authorized_pool.read()), 'NOT_AUTHORIZED');
            let token0 = self.token0.read();
            let token1 = self.token1.read();
            assert((token == token0) | (token == token1), 'TOKEN_NOT_ALLOWED');
            assert(recipient.is_non_zero(), 'RECIPIENT_ZERO');
            if amount == 0 {
                return ();
            }
            enter_non_reentrant(ref self);
            if token == token0 {
                let current = self.protocol_fee_total_0.read();
                assert(current >= amount, 'FEE_BALANCE_LOW');
                self.protocol_fee_total_0.write(current - amount);
            } else {
                let current = self.protocol_fee_total_1.read();
                assert(current >= amount, 'FEE_BALANCE_LOW');
                self.protocol_fee_total_1.write(current - amount);
            }
            assert(
                IERC20Dispatcher { contract_address: token }.transfer(recipient, amount.into()),
                'TRANSFER_FAILED',
            );
            exit_non_reentrant(ref self);
        }

        fn verify_membership(
            self: @ContractState, token: ContractAddress, proof: MerkleProof
        ) -> bool {
            verify_membership_proof(self, token, proof)
        }

        fn verify_position_membership(self: @ContractState, proof: MerkleProof) -> bool {
            verify_position_membership_proof(self, proof)
        }

        fn withdraw_token0(
            ref self: ContractState,
            calldata: Span<felt252>,
            proof: MerkleProof,
        ) {
            self.flush_pending_roots();
            let token = self.token0.read();
            self.handle_withdraw(calldata, proof, token, 0);
        }

        fn withdraw_token1(
            ref self: ContractState,
            calldata: Span<felt252>,
            proof: MerkleProof,
        ) {
            self.flush_pending_roots();
            let token = self.token1.read();
            self.handle_withdraw(calldata, proof, token, 1);
        }

        fn is_known_root(self: @ContractState, token: ContractAddress, root: felt252) -> bool {
            is_known_root_internal(self, token, root)
        }

        fn is_known_position_root(self: @ContractState, root: felt252) -> bool {
            is_known_position_root_internal(self, root)
        }

        fn is_nullifier_used(self: @ContractState, nullifier: felt252) -> bool {
            self.nullifier_registry.is_used(nullifier)
        }

        fn flush_pending_roots(ref self: ContractState) {
            let now = get_block_timestamp();
            let count0 = self.pending_root0_count.read();
            if count0 != 0 {
                let since0 = self.pending_root0_since.read();
                if should_flush_roots(count0, since0, now) {
                    flush_pending_roots0(ref self);
                }
            }
            let count1 = self.pending_root1_count.read();
            if count1 != 0 {
                let since1 = self.pending_root1_since.read();
                if should_flush_roots(count1, since1, now) {
                    flush_pending_roots1(ref self);
                }
            }
            let count_pos = self.pending_root_position_count.read();
            if count_pos != 0 {
                let since_pos = self.pending_root_position_since.read();
                if should_flush_roots(count_pos, since_pos, now) {
                    flush_pending_roots_position(ref self);
                }
            }
        }

        fn get_token0(self: @ContractState) -> ContractAddress {
            self.token0.read()
        }

        fn get_token1(self: @ContractState) -> ContractAddress {
            self.token1.read()
        }

        fn get_authorized_pool(self: @ContractState) -> ContractAddress {
            self.authorized_pool.read()
        }

        fn get_protocol_fee_totals(self: @ContractState) -> (u128, u128) {
            (self.protocol_fee_total_0.read(), self.protocol_fee_total_1.read())
        }
    }

    #[abi(embed_v0)]
    impl AdminImpl of ShieldedNotesAdmin<ContractState> {
        fn set_authorized_pool(ref self: ContractState, authorized_pool: ContractAddress) {
            assert(starknet::get_caller_address() == self.owner.read(), 'OWNER_ONLY');
            assert(authorized_pool.is_non_zero(), 'AUTHORIZED_POOL_ZERO');
            assert(self.authorized_pool.read().is_zero(), 'POOL_ALREADY_SET');
            let old_pool = self.authorized_pool.read();
            assert(authorized_pool != old_pool, 'POOL_NO_CHANGE');
            self.authorized_pool.write(authorized_pool);
            self.emit(
                AuthorizedPoolUpdated {
                    old_pool,
                    new_pool: authorized_pool,
                    timestamp: get_block_timestamp(),
                },
            );
        }

        fn get_owner(self: @ContractState) -> ContractAddress {
            self.owner.read()
        }
    }

    #[generate_trait]
    impl ShieldedNotesHelpersImpl of ShieldedNotesHelpers {
        fn handle_deposit(
            ref self: ContractState,
            calldata: Span<felt252>,
            proof: MerkleProof,
            token: ContractAddress,
            expected_token_id: felt252,
        ) -> felt252 {
            require_initialized(@self);
            enter_non_reentrant(ref self);
            let verifier = IZylithVerifierDispatcher { contract_address: self.verifier.read() };
            let verified = verifier.verify_deposit(calldata);
            let outputs: DepositPublicOutputs = verified.expect('PROOF_INVALID');

            assert(outputs.token_id == expected_token_id, 'TOKEN_ID_MISMATCH');
            assert((outputs.amount.low != 0) | (outputs.amount.high != 0), 'AMOUNT_ZERO');

            insert_token_commitment(ref self, outputs.commitment, token, proof);

            assert(
                IERC20Dispatcher { contract_address: token }.transfer_from(
                    starknet::get_caller_address(), get_contract_address(), outputs.amount
                ),
                'TRANSFER_FAILED',
            );
            exit_non_reentrant(ref self);
            outputs.commitment
        }

        fn handle_withdraw(
            ref self: ContractState,
            calldata: Span<felt252>,
            proof: MerkleProof,
            token: ContractAddress,
            expected_token_id: felt252,
        ) {
            require_initialized(@self);
            enter_non_reentrant(ref self);
            let verifier = IZylithVerifierDispatcher { contract_address: self.verifier.read() };
            let verified = verifier.verify_withdraw(calldata);
            let outputs: WithdrawPublicOutputs = verified.expect('PROOF_INVALID');

            assert(outputs.token_id == expected_token_id, 'TOKEN_ID_MISMATCH');
            assert(outputs.commitment == proof.commitment, 'COMMITMENT_MISMATCH');
            assert((outputs.amount.low != 0) | (outputs.amount.high != 0), 'AMOUNT_ZERO');
            assert(outputs.nullifier != 0, 'NULLIFIER_ZERO');
            assert(!self.nullifier_registry.is_used(outputs.nullifier), 'NULLIFIER_USED');
            // Recipient is a public input, enforce it on-chain to bind the proof to the payout.
            assert(outputs.recipient.is_non_zero(), 'RECIPIENT_ZERO');

            let valid = verify_membership_proof(@self, token, proof);
            assert(valid, 'INVALID_PROOF');

            self.nullifier_registry.mark_used(outputs.nullifier);

            assert(
                IERC20Dispatcher { contract_address: token }.transfer(outputs.recipient, outputs.amount),
                'TRANSFER_FAILED',
            );

            exit_non_reentrant(ref self);
        }
    }
}
