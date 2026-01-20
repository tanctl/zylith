#[feature("deprecated_legacy_map")]
use zylith::privacy::MerkleTree0::MerkleTree0 as MerkleTreeComponent;
use zylith::constants::generated as generated_constants;

use crate::common::{deploy_contract, merkle_proof_for_single_leaf, empty_root};
use MerkleTreeTester::{MerkleTreeTesterExternalDispatcher, MerkleTreeTesterExternalDispatcherTrait};

#[starknet::contract]
pub mod MerkleTreeTester {
    use super::MerkleTreeComponent;
    use super::MerkleTreeComponent::MerkleTreeTrait;

    component!(path: MerkleTreeComponent, storage: merkle, event: MerkleEvent);

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        MerkleEvent: MerkleTreeComponent::Event,
    }

    #[starknet::interface]
    pub trait MerkleTreeTesterExternal<TContractState> {
        fn get_root(self: @TContractState) -> felt252;
        fn insert(ref self: TContractState, leaf: felt252) -> (u64, felt252);
        fn verify_proof(
            self: @TContractState,
            leaf: felt252,
            index: u64,
            path: Span<felt252>,
            indices: Span<bool>,
        ) -> bool;
    }

    #[abi(embed_v0)]
    impl ExternalImpl of MerkleTreeTesterExternal<ContractState> {
        fn get_root(self: @ContractState) -> felt252 {
            self.merkle.get_root()
        }

        fn insert(ref self: ContractState, leaf: felt252) -> (u64, felt252) {
            self.merkle.insert(leaf)
        }

        fn verify_proof(
            self: @ContractState,
            leaf: felt252,
            index: u64,
            path: Span<felt252>,
            indices: Span<bool>,
        ) -> bool {
            self.merkle.verify_proof(leaf, index, path, indices)
        }
    }

    #[storage]
    struct Storage {
        #[substorage(v0)]
        merkle: MerkleTreeComponent::Storage,
    }

    #[constructor]
    fn constructor(ref self: ContractState) {
        self.merkle.initializer();
    }
}

#[test]
fn test_insert_leaf_updates_root() {
    let address = deploy_contract("MerkleTreeTester", array![]);
    let tree = MerkleTreeTesterExternalDispatcher { contract_address: address };
    let root0 = tree.get_root();
    let (_idx, root1) = tree.insert(123);
    assert(root1 != root0, 'root unchanged');
    assert(tree.get_root() == root1, 'root mismatch');
}

#[test]
fn test_verify_valid_proof() {
    let address = deploy_contract("MerkleTreeTester", array![]);
    let tree = MerkleTreeTesterExternalDispatcher { contract_address: address };
    let (idx, _) = tree.insert(456);
    let root = tree.get_root();
    let proof = merkle_proof_for_single_leaf(root, 456);
    let valid = tree.verify_proof(456, idx, proof.path, proof.indices);
    assert(valid, 'proof invalid');
}

#[test]
fn test_reject_invalid_proof() {
    let address = deploy_contract("MerkleTreeTester", array![]);
    let tree = MerkleTreeTesterExternalDispatcher { contract_address: address };
    let (idx, _) = tree.insert(789);
    let root = tree.get_root();
    let proof = merkle_proof_for_single_leaf(root, 789);
    let valid = tree.verify_proof(790, idx, proof.path, proof.indices);
    assert(!valid, 'proof accepted');
}

#[test]
fn test_tree_height_25_capacity() {
    assert(generated_constants::TREE_HEIGHT >= 25, 'tree height');
}

#[test]
fn test_zero_hash_precomputation() {
    let address = deploy_contract("MerkleTreeTester", array![]);
    let tree = MerkleTreeTesterExternalDispatcher { contract_address: address };
    let zero = empty_root();
    assert(tree.get_root() == zero, 'zero root');
}

#[fuzzer(runs: 16)]
#[test]
fn test_verify_random_leaf(leaf: felt252) {
    let address = deploy_contract("MerkleTreeTester", array![]);
    let tree = MerkleTreeTesterExternalDispatcher { contract_address: address };
    let (idx, _) = tree.insert(leaf);
    let root = tree.get_root();
    let proof = merkle_proof_for_single_leaf(root, leaf);
    let valid = tree.verify_proof(leaf, idx, proof.path, proof.indices);
    assert(valid, 'fuzz proof invalid');
}
