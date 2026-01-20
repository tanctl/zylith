// private withdraw circuit.
pragma circom 2.2.3;

include "./math/bigint.circom";
include "./note_commitments.circom";

template PrivateWithdraw() {
    var VK_WITHDRAW = 0x5749544844524157; // "WITHDRAW"

    // public inputs
    signal input tag;
    signal input commitment;
    signal input nullifier;
    signal input amount;
    signal input token_id;
    signal input recipient;

    // private inputs
    signal input secret;
    signal input nullifier_seed;

    tag === VK_WITHDRAW;
    token_id * (token_id - 1) === 0;

    component rc_amount = Num2Bits(128);
    rc_amount.in <== amount;
    component amount_zero = IsEqual();
    amount_zero.in[0] <== amount;
    amount_zero.in[1] <== 0;
    amount_zero.out === 0;
    component rc_recipient = StarkFieldRangeCheck();
    rc_recipient.value <== recipient;

    component note = TokenNote();
    note.token_id <== token_id;
    note.amount <== amount;
    note.secret <== secret;
    note.nullifier_seed <== nullifier_seed;
    note.commitment === commitment;
    note.nullifier === nullifier;
}

component main { public [tag, commitment, nullifier, amount, token_id, recipient] } = PrivateWithdraw();
