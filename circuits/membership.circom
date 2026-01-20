pragma circom 2.2.3;

include "./math/bigint.circom";
include "./note_commitments.circom";

// membership circuit - proves knowledge of the note opening for commitment, merkle checks remain on-chain

template Membership() {
    var VK_MEMBERSHIP = 0x4d454d42455253484950; // "MEMBERSHIP"

    signal input tag;
    signal input merkle_root;
    signal input commitment;

    // private inputs
    signal input token_id;
    signal input amount;
    signal input secret;
    signal input nullifier_seed;

    tag === VK_MEMBERSHIP;
    token_id * (token_id - 1) === 0;
    component rc_root = StarkFieldRangeCheck();
    rc_root.value <== merkle_root;
    component rc_amount = Num2Bits(128);
    rc_amount.in <== amount;

    component note = TokenNote();
    note.token_id <== token_id;
    note.amount <== amount;
    note.secret <== secret;
    note.nullifier_seed <== nullifier_seed;
    note.commitment === commitment;

    signal output out_tag;
    signal output out_merkle_root;
    signal output out_commitment;

    out_tag <== tag;
    out_merkle_root <== merkle_root;
    out_commitment <== commitment;
}

component main { public [tag, merkle_root, commitment] } = Membership();
