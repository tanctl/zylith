use core::poseidon::hades_permutation;
use crate::constants::generated::ZERO_LEAF_HASH;

fn poseidon_hash_two(x: felt252, y: felt252) -> felt252 {
    let (s0, _, _) = hades_permutation(x, y, 2);
    s0
}

#[test]
fn zero_leaf_hash_matches_poseidon() {
    assert(poseidon_hash_two(0, 0) == ZERO_LEAF_HASH, 'ZERO_LEAF_HASH_MISMATCH');
}
