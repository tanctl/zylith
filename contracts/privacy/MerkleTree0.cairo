// Poseidon merkle tree component (height 32, 2^32 leaves)
// sparse storage: only nonzero hashes are stored, zero hashes derived from precomputation
// zero value: poseidon_hash(0, 0), higher level zeros are poseidon_hash(z_i, z_i)
#[starknet::component]
pub mod MerkleTree0 {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use core::poseidon::hades_permutation;
    use core::array::SpanTrait;
    use crate::constants::generated as generated_constants;

    const HEIGHT: u8 = generated_constants::TREE_HEIGHT;
    const HEIGHT_USIZE: usize = generated_constants::TREE_HEIGHT.into();
    const ZERO_LEAF_HASH: felt252 = generated_constants::ZERO_LEAF_HASH;

    #[storage]
    pub struct Storage {
        // level -> index -> hash; sparse by default.
        pub levels: Map<(u8, u64), felt252>,
        pub levels_present: Map<(u8, u64), bool>,
        pub next_leaf_index: u64,
        pub root: felt252,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[generate_trait]
    pub impl MerkleTreeImpl<
        TContractState, +HasComponent<TContractState>,
    > of MerkleTreeTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>) {
            let zeros = precomputed_zero_hashes();
            self.next_leaf_index.write(0);
            let top = *zeros.at((HEIGHT - 1).into());
            self.root.write(poseidon_hash_pair(top, top));
        }

        fn insert(ref self: ComponentState<TContractState>, leaf: felt252) -> (u64, felt252) {
            let zeros = precomputed_zero_hashes();
            let leaf_index = self.next_leaf_index.read();
            assert(leaf_index < max_leaves(), 'TREE_FULL');
            let mut hash_ = leaf;
            let mut index = leaf_index;

            let mut level: u8 = 0;
            while level < HEIGHT {
                let zero_hash = *zeros.at(level.into());

                if hash_ != zero_hash {
                    self.levels.write((level, index), hash_);
                    self.levels_present.write((level, index), true);
                } else {
                    self.levels.write((level, index), 0);
                    self.levels_present.write((level, index), false);
                }

                let is_right = (index % 2) == 1;
                let sibling_index = if is_right { index - 1 } else { index + 1 };
                let sibling = {
                    if self.levels_present.read((level, sibling_index)) {
                        self.levels.read((level, sibling_index))
                    } else {
                        zero_hash
                    }
                };

                let (left, right) = if is_right {
                    (sibling, hash_)
                } else {
                    (hash_, sibling)
                };

                hash_ = poseidon_hash_pair(left, right);
                index /= 2;
                level = level + 1;
            };

            self.root.write(hash_);
            self.next_leaf_index.write(leaf_index + 1);

            (leaf_index, hash_)
        }

        fn get_root(self: @ComponentState<TContractState>) -> felt252 {
            self.root.read()
        }

        fn verify_proof(
            self: @ComponentState<TContractState>,
            leaf: felt252,
            index: u64,
            path: Span<felt252>,
            indices: Span<bool>,
        ) -> bool {
            self.compute_root_from_path(leaf, index, path, indices) == self.get_root()
        }

        fn compute_root_from_path(
            self: @ComponentState<TContractState>,
            leaf: felt252,
            mut index: u64,
            path: Span<felt252>,
            indices: Span<bool>,
        ) -> felt252 {
            assert(path.len() == indices.len(), 'PROOF_LENGTH');
            assert(path.len() == HEIGHT_USIZE, 'INVALID_PROOF_DEPTH');
            let mut hash_ = leaf;

            let mut level: u8 = 0;
            while level < HEIGHT {
                let sibling = *path.at(level.into());
                let is_right = *indices.at(level.into());
                assert(((index % 2) == 1) == is_right, 'PATH_DIR_MISMATCH');

                let (left, right) = if is_right {
                    (sibling, hash_)
                } else {
                    (hash_, sibling)
                };

                hash_ = poseidon_hash_pair(left, right);
                index /= 2;
                level = level + 1;
            };

            hash_
        }

        fn hash_pair(self: @ComponentState<TContractState>, left: felt252, right: felt252) -> felt252 {
            poseidon_hash_pair(left, right)
        }
    }

    fn poseidon_hash_pair(left: felt252, right: felt252) -> felt252 {
        let (s0, _, _) = hades_permutation(left, right, 2);
        s0
    }

    fn max_leaves() -> u64 {
        let mut leaves: u64 = 1;
        let mut level: u8 = 0;
        while level < HEIGHT {
            leaves = leaves * 2;
            level = level + 1;
        }
        leaves
    }

    // precompute zero hashes for all levels (0-based)
    fn precomputed_zero_hashes() -> Array<felt252> {
        let mut zeros: Array<felt252> = array![];
        let mut level: u8 = 0;

        let base = ZERO_LEAF_HASH;
        zeros.append(base);

        level = 1;
        while level < HEIGHT {
            let prev = *zeros.at((level - 1).into());
            zeros.append(poseidon_hash_pair(prev, prev));
            level = level + 1;
        }

        zeros
    }
}
