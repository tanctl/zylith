//! Merkle tree utilities for ASP storage.
//! Mirrors ShieldedNotes.cairo poseidon parameters and tree depth.

use std::collections::HashMap;
use std::sync::OnceLock;

use starknet::core::types::FieldElement as Felt;
use starknet_crypto::poseidon_hash;

use crate::generated_constants;

static TREE_HEIGHT: OnceLock<usize> = OnceLock::new();
static ZERO_LEAF_HASH: OnceLock<Felt> = OnceLock::new();

#[derive(Debug, Clone)]
pub struct MerkleTree {
    height: usize,
    zero_hashes: Vec<Felt>,
    nodes: HashMap<(usize, u64), Felt>,
    next_index: u64,
    root: Felt,
}

#[derive(Debug)]
pub enum MerkleError {
    IndexGap { expected: u64, got: u64 },
    LeafMismatch { index: u64 },
    TreeFull { max: u64 },
    InvalidLeaf { reason: &'static str },
}

impl MerkleTree {
    pub fn new(height: usize) -> Self {
        let zero_leaf = zero_leaf_hash();
        let mut zero_hashes = Vec::with_capacity(height);
        zero_hashes.push(zero_leaf);
        for i in 1..height {
            let prev = zero_hashes[i - 1];
            zero_hashes.push(poseidon_hash(prev, prev));
        }
        let root = poseidon_hash(zero_hashes[height - 1], zero_hashes[height - 1]);
        Self {
            height,
            zero_hashes,
            nodes: HashMap::new(),
            next_index: 0,
            root,
        }
    }

    pub fn default_height() -> usize {
        tree_height()
    }

    #[cfg(test)]
    pub fn insert(&mut self, leaf: Felt) -> Result<(u64, Felt), MerkleError> {
        let index = self.next_index;
        self.insert_at(index, leaf)
    }

    pub fn insert_at(&mut self, index: u64, leaf: Felt) -> Result<(u64, Felt), MerkleError> {
        if leaf == Felt::ZERO {
            return Err(MerkleError::InvalidLeaf { reason: "commitment_zero" });
        }
        if leaf == self.zero_hashes[0] {
            return Err(MerkleError::InvalidLeaf {
                reason: "commitment_zero_hash",
            });
        }
        let max_leaves = max_leaves(self.height)?;
        if index >= max_leaves {
            return Err(MerkleError::TreeFull { max: max_leaves });
        }
        if self.next_index >= max_leaves {
            return Err(MerkleError::TreeFull { max: max_leaves });
        }
        if index < self.next_index {
            let existing = self
                .nodes
                .get(&(0, index))
                .copied()
                .unwrap_or(self.zero_hashes[0]);
            if existing != leaf {
                return Err(MerkleError::LeafMismatch { index });
            }
            return Ok((index, self.root));
        }
        if index != self.next_index {
            return Err(MerkleError::IndexGap {
                expected: self.next_index,
                got: index,
            });
        }

        self.next_index = self
            .next_index
            .checked_add(1)
            .ok_or(MerkleError::TreeFull { max: max_leaves })?;
        let mut current = leaf;
        let mut idx = index;
        for level in 0..self.height {
            let zero = self.zero_hashes[level];
            if current == zero {
                self.nodes.remove(&(level, idx));
            } else {
                self.nodes.insert((level, idx), current);
            }

            let is_right = (idx % 2) == 1;
            let sibling_index = if is_right { idx - 1 } else { idx + 1 };
            let sibling = self
                .nodes
                .get(&(level, sibling_index))
                .copied()
                .unwrap_or(zero);
            let (left, right) = if is_right {
                (sibling, current)
            } else {
                (current, sibling)
            };
            current = poseidon_hash(left, right);
            idx /= 2;
        }

        self.root = current;
        Ok((index, self.root))
    }

    pub fn root(&self) -> Felt {
        self.root
    }

    pub fn next_index(&self) -> u64 {
        self.next_index
    }

    #[cfg(test)]
    pub fn get_path(&self, leaf_index: u64) -> Option<(Vec<Felt>, Vec<bool>)> {
        self.get_path_at(leaf_index, self.next_index)
    }

    pub fn get_path_at(&self, leaf_index: u64, leaf_count: u64) -> Option<(Vec<Felt>, Vec<bool>)> {
        if leaf_index >= leaf_count || leaf_count > self.next_index {
            return None;
        }
        let mut path = Vec::with_capacity(self.height);
        let mut indices = Vec::with_capacity(self.height);
        let mut idx = leaf_index;
        for level in 0..self.height {
            let is_right = (idx % 2) == 1;
            let sibling_index = if is_right { idx - 1 } else { idx + 1 };
            let sibling = self.hash_subtree_at(level, sibling_index, leaf_count);
            path.push(sibling);
            indices.push(is_right);
            idx /= 2;
        }
        Some((path, indices))
    }

    #[cfg(test)]
    pub fn insertion_path(&self) -> Option<(u64, Vec<Felt>, Vec<bool>)> {
        let leaf_index = self.next_index;
        let max = 1u64.checked_shl(self.height as u32)?;
        if leaf_index >= max {
            return None;
        }
        let mut path = Vec::with_capacity(self.height);
        let mut indices = Vec::with_capacity(self.height);
        let mut idx = leaf_index;
        for level in 0..self.height {
            let is_right = (idx % 2) == 1;
            let sibling_index = if is_right { idx - 1 } else { idx + 1 };
            let sibling = self.hash_subtree_at(level, sibling_index, self.next_index);
            path.push(sibling);
            indices.push(is_right);
            idx /= 2;
        }
        Some((leaf_index, path, indices))
    }

    pub fn insertion_path_at(&self, leaf_count: u64) -> Option<(u64, Vec<Felt>, Vec<bool>)> {
        let leaf_index = leaf_count;
        let max = 1u64.checked_shl(self.height as u32)?;
        if leaf_index >= max || leaf_index > self.next_index {
            return None;
        }
        let mut path = Vec::with_capacity(self.height);
        let mut indices = Vec::with_capacity(self.height);
        let mut idx = leaf_index;
        for level in 0..self.height {
            let is_right = (idx % 2) == 1;
            let sibling_index = if is_right { idx - 1 } else { idx + 1 };
            let sibling = self.hash_subtree_at(level, sibling_index, leaf_count);
            path.push(sibling);
            indices.push(is_right);
            idx /= 2;
        }
        Some((leaf_index, path, indices))
    }

    pub fn root_at(&self, leaf_count: u64) -> Option<Felt> {
        if leaf_count > self.next_index {
            return None;
        }
        if leaf_count == 0 {
            return Some(empty_root(self.height, &self.zero_hashes));
        }
        let left = self.hash_subtree_at(self.height - 1, 0, leaf_count);
        let right = self.hash_subtree_at(self.height - 1, 1, leaf_count);
        Some(poseidon_hash(left, right))
    }

    fn hash_subtree_at(&self, level: usize, index: u64, leaf_count: u64) -> Felt {
        let subtree_size = 1u64 << level;
        let start = index.saturating_mul(subtree_size);
        let end = start.saturating_add(subtree_size);
        if leaf_count <= start {
            return self.zero_hashes[level];
        }
        if leaf_count >= end {
            return self
                .nodes
                .get(&(level, index))
                .copied()
                .unwrap_or(self.zero_hashes[level]);
        }
        if level == 0 {
            return self
                .nodes
                .get(&(0, index))
                .copied()
                .unwrap_or(self.zero_hashes[0]);
        }
        let left = self.hash_subtree_at(level - 1, index * 2, leaf_count);
        let right = self.hash_subtree_at(level - 1, index * 2 + 1, leaf_count);
        poseidon_hash(left, right)
    }
}

fn tree_height() -> usize {
    *TREE_HEIGHT.get_or_init(|| generated_constants::TREE_HEIGHT)
}

fn max_leaves(height: usize) -> Result<u64, MerkleError> {
    let max = 1u64
        .checked_shl(height as u32)
        .ok_or(MerkleError::TreeFull { max: 0 })?;
    Ok(max)
}

fn empty_root(height: usize, zero_hashes: &[Felt]) -> Felt {
    let top = zero_hashes[height.saturating_sub(1)];
    poseidon_hash(top, top)
}

pub fn zero_leaf_hash() -> Felt {
    ZERO_LEAF_HASH
        .get_or_init(|| {
            Felt::from_hex_be(generated_constants::ZERO_LEAF_HASH_HEX)
                .expect("ZERO_LEAF_HASH invalid")
        })
        .clone()
}

#[cfg(test)]
mod tests_extra {
    use super::{empty_root, zero_leaf_hash, MerkleTree};
    use starknet::core::types::FieldElement as Felt;
    use starknet_crypto::poseidon_hash;

    fn compute_root_from_path(
        leaf: Felt,
        mut index: u64,
        path: &[Felt],
        indices: &[bool],
    ) -> Felt {
        let mut hash = leaf;
        for (sibling, is_right) in path.iter().zip(indices.iter()) {
            let (left, right) = if *is_right { (*sibling, hash) } else { (hash, *sibling) };
            hash = poseidon_hash(left, right);
            index /= 2;
        }
        let _ = index;
        hash
    }

    #[test]
    fn root_at_matches_historical_state() {
        let mut tree = MerkleTree::new(4);
        let leaf0 = Felt::from(11u8);
        let leaf1 = Felt::from(22u8);
        tree.insert(leaf0).expect("insert leaf0");
        let root_after_first = tree.root();
        tree.insert(leaf1).expect("insert leaf1");
        let root_at_one = tree.root_at(1).expect("root_at");
        assert_eq!(root_at_one, root_after_first);
    }

    #[test]
    fn get_path_at_verifies_historical_root() {
        let mut tree = MerkleTree::new(4);
        let leaf0 = Felt::from(33u8);
        tree.insert(leaf0).expect("insert leaf0");
        tree.insert(Felt::from(44u8)).expect("insert leaf1");
        let (path, indices) = tree.get_path_at(0, 1).expect("path");
        let root = compute_root_from_path(leaf0, 0, &path, &indices);
        let expected = tree.root_at(1).expect("root_at");
        assert_eq!(root, expected);
    }

    #[test]
    fn get_path_matches_current_root() {
        let mut tree = MerkleTree::new(4);
        let leaf0 = Felt::from(55u8);
        tree.insert(leaf0).expect("insert leaf0");
        tree.insert(Felt::from(66u8)).expect("insert leaf1");
        let (path, indices) = tree.get_path(0).expect("path");
        let root = compute_root_from_path(leaf0, 0, &path, &indices);
        assert_eq!(root, tree.root());
    }

    #[test]
    fn empty_root_matches_zero_hashes() {
        let zero = zero_leaf_hash();
        let mut zeros = Vec::new();
        zeros.push(zero);
        for i in 1..4 {
            let prev = zeros[i - 1];
            zeros.push(poseidon_hash(prev, prev));
        }
        let root = empty_root(4, &zeros);
        let tree = MerkleTree::new(4);
        assert_eq!(tree.root_at(0).expect("root_at"), root);
    }
}

#[cfg(test)]
mod tests {
    use super::{MerkleError, MerkleTree};
    use starknet::core::types::FieldElement as Felt;

    #[test]
    fn root_at_zero_is_empty_root_after_inserts() {
        let mut tree = MerkleTree::new(3);
        let empty_root = tree.root();
        tree.insert(Felt::from(1u8)).unwrap();
        tree.insert(Felt::from(2u8)).unwrap();
        assert_eq!(tree.root_at(0).unwrap(), empty_root);
    }

    #[test]
    fn root_at_matches_prefix_tree() {
        let mut tree = MerkleTree::new(3);
        tree.insert(Felt::from(11u8)).unwrap();
        tree.insert(Felt::from(22u8)).unwrap();
        tree.insert(Felt::from(33u8)).unwrap();

        let mut prefix = MerkleTree::new(3);
        prefix.insert(Felt::from(11u8)).unwrap();
        let expected = prefix.root();
        assert_eq!(tree.root_at(1).unwrap(), expected);
    }

    #[test]
    fn insert_rejects_when_full() {
        let mut tree = MerkleTree::new(2);
        tree.insert(Felt::from(1u8)).unwrap();
        tree.insert(Felt::from(2u8)).unwrap();
        tree.insert(Felt::from(3u8)).unwrap();
        tree.insert(Felt::from(4u8)).unwrap();

        let err = tree.insert(Felt::from(5u8)).unwrap_err();
        assert!(matches!(err, MerkleError::TreeFull { .. }));
        let err = tree.insert_at(4, Felt::from(6u8)).unwrap_err();
        assert!(matches!(err, MerkleError::TreeFull { .. }));
    }

    #[test]
    fn insertion_path_matches_at() {
        let mut tree = MerkleTree::new(3);
        tree.insert(Felt::from(11u8)).unwrap();
        let (idx, path, indices) = tree.insertion_path().expect("path");
        let (idx_at, path_at, indices_at) =
            tree.insertion_path_at(tree.next_index()).expect("path_at");
        assert_eq!(idx, idx_at);
        assert_eq!(path, path_at);
        assert_eq!(indices, indices_at);
    }
}
