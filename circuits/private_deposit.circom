// private deposit circuit.
pragma circom 2.2.3;

include "./math/bigint.circom";
include "./note_commitments.circom";

template PrivateDeposit() {
    var VK_DEPOSIT = 0x4445504f534954; // "DEPOSIT"

    // public inputs
    signal input tag;
    signal input commitment;
    signal input amount;
    signal input token_id;

    // private inputs
    signal input secret;
    signal input nullifier_seed;

    tag === VK_DEPOSIT;
    token_id * (token_id - 1) === 0;

    component rc_amount = Num2Bits(128);
    rc_amount.in <== amount;
    component amount_zero = IsEqual();
    amount_zero.in[0] <== amount;
    amount_zero.in[1] <== 0;
    amount_zero.out === 0;

    component note = TokenNote();
    note.token_id <== token_id;
    note.amount <== amount;
    note.secret <== secret;
    note.nullifier_seed <== nullifier_seed;
    note.commitment === commitment;
}

component main { public [tag, commitment, amount, token_id] } = PrivateDeposit();
