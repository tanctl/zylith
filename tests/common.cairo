#[feature("deprecated_legacy_map")]
use core::byte_array::ByteArray;
use core::poseidon::hades_permutation;
use core::array::SpanTrait;
use core::result::ResultTrait;
use core::traits::TryInto;
use starknet::{ContractAddress, SyscallResultTrait};
use snforge_std::{declare, ContractClassTrait, DeclareResultTrait};

use zylith::constants::generated as generated_constants;
use zylith::privacy::ShieldedNotes::MerkleProof;

const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

pub mod mocks;
pub mod mock_proof_generator;

pub fn declare_contract(name: ByteArray) -> @snforge_std::ContractClass {
    let result = declare(name).unwrap();
    result.contract_class()
}

pub fn deploy_contract(name: ByteArray, calldata: Array<felt252>) -> ContractAddress {
    let class = declare_contract(name);
    let (address, _) = class.deploy(@calldata).unwrap_syscall();
    address
}

pub fn deploy_contract_at(
    name: ByteArray, calldata: Array<felt252>, address: ContractAddress,
) -> ContractAddress {
    let class = declare_contract(name);
    let (deployed, _) = class.deploy_at(@calldata, address).unwrap_syscall();
    deployed
}

pub fn u256_from_u128(value: u128) -> u256 {
    u256 { low: value, high: 0 }
}

pub fn u256_from_felt(value: felt252) -> u256 {
    value.into()
}

pub fn u256_from_bool(value: bool) -> u256 {
    if value {
        u256 { low: 1, high: 0 }
    } else {
        u256 { low: 0, high: 0 }
    }
}

pub fn encode_i32_signed(value: i32) -> u256 {
    if value >= 0 {
        u256_from_u128(value.try_into().unwrap())
    } else {
        let mag: u128 = (-value).try_into().unwrap();
        let twos = (MAX_U128 - mag) + 1;
        u256 { low: twos, high: 0 }
    }
}

pub fn neg_u256_from_mag(mag: u128) -> u256 {
    assert(mag > 0, 'mag zero');
    let low = (MAX_U128 - (mag - 1));
    u256 { low, high: 0 }
}

pub fn merkle_proof_for_single_leaf(root: felt252, commitment: felt252) -> MerkleProof {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let (path, indices) = zero_merkle_path(height);
    MerkleProof { root, commitment, leaf_index: 0, path: path.span(), indices: indices.span() }
}

pub fn empty_root() -> felt252 {
    let mut hash_ = generated_constants::ZERO_LEAF_HASH;
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let mut level: usize = 0;
    while level < height {
        hash_ = poseidon_hash_pair(hash_, hash_);
        level += 1;
    }
    hash_
}

pub fn merkle_root_for_single_leaf(commitment: felt252) -> felt252 {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let (path, indices) = zero_merkle_path(height);
    merkle_root_from_path(commitment, 0, path.span(), indices.span())
}

pub fn insertion_proof_for_empty_leaf() -> MerkleProof {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let (path, indices) = zero_merkle_path(height);
    MerkleProof {
        root: empty_root(),
        commitment: generated_constants::ZERO_LEAF_HASH,
        leaf_index: 0,
        path: path.span(),
        indices: indices.span(),
    }
}

pub fn insertion_proof_for_second_leaf(first_commitment: felt252) -> MerkleProof {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let mut path: Array<felt252> = array![];
    let mut indices: Array<bool> = array![];
    let mut zero_hash = generated_constants::ZERO_LEAF_HASH;
    let mut level: usize = 0;
    while level < height {
        if level == 0 {
            path.append(first_commitment);
            indices.append(true);
        } else {
            zero_hash = poseidon_hash_pair(zero_hash, zero_hash);
            path.append(zero_hash);
            indices.append(false);
        }
        level += 1;
    }
    MerkleProof {
        root: merkle_root_for_single_leaf(first_commitment),
        commitment: generated_constants::ZERO_LEAF_HASH,
        leaf_index: 1,
        path: path.span(),
        indices: indices.span(),
    }
}

pub fn merkle_root_for_two_leaves(leaf0: felt252, leaf1: felt252) -> felt252 {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let mut path: Array<felt252> = array![];
    let mut indices: Array<bool> = array![];
    path.append(leaf0);
    indices.append(true);
    let mut current = generated_constants::ZERO_LEAF_HASH;
    let mut level: usize = 1;
    while level < height {
        current = poseidon_hash_pair(current, current);
        path.append(current);
        indices.append(false);
        level += 1;
    }
    merkle_root_from_path(leaf1, 1, path.span(), indices.span())
}

pub fn merkle_proof_for_two_leaves(
    root: felt252,
    commitment: felt252,
    leaf_index: u64,
    sibling: felt252,
) -> MerkleProof {
    let height: usize = generated_constants::TREE_HEIGHT.into();
    let mut path: Array<felt252> = array![];
    let mut indices: Array<bool> = array![];
    path.append(sibling);
    indices.append(leaf_index == 1);
    let mut current = generated_constants::ZERO_LEAF_HASH;
    let mut level: usize = 1;
    while level < height {
        current = poseidon_hash_pair(current, current);
        path.append(current);
        indices.append(false);
        level += 1;
    }
    MerkleProof { root, commitment, leaf_index, path: path.span(), indices: indices.span() }
}

fn poseidon_hash_pair(left: felt252, right: felt252) -> felt252 {
    let (s0, _, _) = hades_permutation(left, right, 2);
    s0
}

pub fn merkle_root_from_path(
    leaf: felt252,
    mut index: u64,
    path: Span<felt252>,
    indices: Span<bool>,
) -> felt252 {
    let mut hash_ = leaf;
    let mut i: usize = 0;
    while i < path.len() {
        let sibling = *path.at(i);
        let is_right = *indices.at(i);
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

fn zero_merkle_path(height: usize) -> (Array<felt252>, Array<bool>) {
    let mut path: Array<felt252> = array![];
    let mut indices: Array<bool> = array![];
    let mut current = generated_constants::ZERO_LEAF_HASH;
    let mut level: usize = 0;
    while level < height {
        path.append(current);
        indices.append(false);
        current = poseidon_hash_pair(current, current);
        level += 1;
    }
    (path, indices)
}

pub fn test_address_const() -> ContractAddress {
    0x12345.try_into().expect('ADDRESS_RANGE')
}
