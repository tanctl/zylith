pragma circom 2.2.3;

include "./poseidon.circom";
include "./constants/generated.circom";

// bn254 note commitments with stark field range checks

template EnforceNonzeroCommitment() {
    signal input commitment;

    // mirror ShieldedNotes.cairo insertion checks to avoid proof-valid/tx-revert mismatches
    // must equal Starknet poseidon_hash(0,0), changing breaks verifier
    component zero_hash = ZeroLeafHash();

    component eq_zero = IsEqual();
    eq_zero.in[0] <== commitment;
    eq_zero.in[1] <== 0;
    eq_zero.out === 0;

    component eq_zero_hash = IsEqual();
    eq_zero_hash.in[0] <== commitment;
    eq_zero_hash.in[1] <== zero_hash.out;
    eq_zero_hash.out === 0;
}

template StarkFieldRangeCheck() {
    signal input value;

    component bits = Num2Bits(256);
    bits.in <== value;

    component limb0 = Bits2Num(64);
    component limb1 = Bits2Num(64);
    component limb2 = Bits2Num(64);
    component limb3 = Bits2Num(64);
    for (var k = 0; k < 64; k++) {
        limb0.in[k] <== bits.out[k];
        limb1.in[k] <== bits.out[64 + k];
        limb2.in[k] <== bits.out[128 + k];
        limb3.in[k] <== bits.out[192 + k];
    }

    signal limbs[4];
    limbs[0] <== limb0.out;
    limbs[1] <== limb1.out;
    limbs[2] <== limb2.out;
    limbs[3] <== limb3.out;

    // starknet felt252 modulus p = 2^251 + 17*2^192 + 1 (little-endian u64 limbs)
    var p0 = 0x1;
    var p1 = 0x0;
    var p2 = 0x0;
    var p3 = 0x800000000000011;

    component cmp = U256Cmp();
    for (var i = 0; i < 4; i++) {
        cmp.a[i] <== limbs[i];
    }
    cmp.b[0] <== p0;
    cmp.b[1] <== p1;
    cmp.b[2] <== p2;
    cmp.b[3] <== p3;
    cmp.lt === 1;
}

template SplitU256ToU128() {
    signal input value;
    signal output low;
    signal output high;

    component bits = Num2Bits(256);
    bits.in <== value;
    component limb0 = Bits2Num(64);
    component limb1 = Bits2Num(64);
    component limb2 = Bits2Num(64);
    component limb3 = Bits2Num(64);
    for (var k = 0; k < 64; k++) {
        limb0.in[k] <== bits.out[k];
        limb1.in[k] <== bits.out[64 + k];
        limb2.in[k] <== bits.out[128 + k];
        limb3.in[k] <== bits.out[192 + k];
    }
    low <== limb0.out + limb1.out * (1 << 64);
    high <== limb2.out + limb3.out * (1 << 64);
}

template NoteNullifier(NOTE_TYPE) {
    signal input token_id;
    signal input secret;
    signal input nullifier_seed;
    signal output nullifier;

    var DOMAIN_TAG = 0x5a594c495448; // "ZYLITH"

    component h = Poseidon(5);
    h.inputs[0] <== DOMAIN_TAG;
    h.inputs[1] <== NOTE_TYPE;
    h.inputs[2] <== token_id;
    h.inputs[3] <== secret;
    h.inputs[4] <== nullifier_seed;
    nullifier <== h.out;

    component nz = IsEqual();
    nz.in[0] <== nullifier;
    nz.in[1] <== 0;
    nz.out === 0;

    component rc = StarkFieldRangeCheck();
    rc.value <== nullifier;
}

template TokenNote() {
    signal input token_id;
    signal input amount;
    signal input secret;
    signal input nullifier_seed;
    signal output commitment;
    signal output nullifier;

    var DOMAIN_TAG = 0x5a594c495448; // "ZYLITH"
    var NOTE_TYPE = 1;

    component n = NoteNullifier(NOTE_TYPE);
    n.token_id <== token_id;
    n.secret <== secret;
    n.nullifier_seed <== nullifier_seed;
    nullifier <== n.nullifier;

    component h = Poseidon(6);
    h.inputs[0] <== DOMAIN_TAG;
    h.inputs[1] <== NOTE_TYPE;
    h.inputs[2] <== token_id;
    h.inputs[3] <== amount;
    h.inputs[4] <== secret;
    h.inputs[5] <== nullifier;
    commitment <== h.out;

    component nonzero = EnforceNonzeroCommitment();
    nonzero.commitment <== commitment;

    component rc = StarkFieldRangeCheck();
    rc.value <== commitment;
}

template PositionNote() {
    signal input token_id;
    signal input tick_lower;
    signal input tick_upper;
    signal input liquidity;
    signal input fee_growth_inside_0;
    signal input fee_growth_inside_1;
    signal input secret;
    signal input nullifier_seed;
    signal output commitment;
    signal output nullifier;

    var DOMAIN_TAG = 0x5a594c495448; // "ZYLITH"
    var NOTE_TYPE = 2;

    component n = NoteNullifier(NOTE_TYPE);
    n.token_id <== token_id;
    n.secret <== secret;
    n.nullifier_seed <== nullifier_seed;
    nullifier <== n.nullifier;

    component split0 = SplitU256ToU128();
    split0.value <== fee_growth_inside_0;
    component split1 = SplitU256ToU128();
    split1.value <== fee_growth_inside_1;

    component h = Poseidon(12);
    h.inputs[0] <== DOMAIN_TAG;
    h.inputs[1] <== NOTE_TYPE;
    h.inputs[2] <== token_id;
    h.inputs[3] <== tick_lower;
    h.inputs[4] <== tick_upper;
    h.inputs[5] <== liquidity;
    h.inputs[6] <== split0.low;
    h.inputs[7] <== split0.high;
    h.inputs[8] <== split1.low;
    h.inputs[9] <== split1.high;
    h.inputs[10] <== secret;
    h.inputs[11] <== nullifier;
    commitment <== h.out;

    component nonzero = EnforceNonzeroCommitment();
    nonzero.commitment <== commitment;

    component rc = StarkFieldRangeCheck();
    rc.value <== commitment;
}
