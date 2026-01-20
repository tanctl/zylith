pragma circom 2.2.3;

// Big integer helpers for u256 (4 x u64 limbs, little-endian) and u512 arithmetic.

include "circomlib/circuits/bitify.circom";
include "circomlib/circuits/comparators.circom";

// Range-check a 64-bit limb
template Limb64() {
    signal input in;
    signal output out;
    component bits = Num2Bits(64);
    bits.in <== in;
    out <== in;
}

// Ensure each limb is < 2^64.
template U256RangeCheck() {
    signal input limbs[4];
    component lc[4];
    for (var i = 0; i < 4; i++) {
        lc[i] = Limb64();
        lc[i].in <== limbs[i];
    }
}

// Range check a u256 supplied as 4x64-bit limbs; also ensure optional high limbs are zero when desired.
template U128RangeCheck() {
    signal input limbs[4];
    component lc[2];
    for (var i = 0; i < 2; i++) {
        lc[i] = Limb64();
        lc[i].in <== limbs[i];
    }
    // upper limbs must be zero
    limbs[2] === 0;
    limbs[3] === 0;
}

// Decompose a 128-bit scalar into 4x64 limbs (little-endian). Upper limbs zeroed.
template U128ToU256Limbs() {
    signal input in;
    signal output limbs[4];

    component bits = Num2Bits(128);
    bits.in <== in;

    component limb0 = Bits2Num(64);
    component limb1 = Bits2Num(64);
    for (var k = 0; k < 64; k++) {
        limb0.in[k] <== bits.out[k];
        limb1.in[k] <== bits.out[64 + k];
    }
    limbs[0] <== limb0.out;
    limbs[1] <== limb1.out;
    limbs[2] <== 0;
    limbs[3] <== 0;
}

// Comparator for u256 (little-endian limbs).
// Outputs boolean lt/gt/eq such that exactly one is 1.
template U256Cmp() {
    signal input a[4];
    signal input b[4];
    signal output lt;
    signal output gt;
    signal output eq;

    component lt_i[4];
    component gt_i[4];
    signal lt_stage[5];
    signal gt_stage[5];
    signal eq_stage[5];
    signal eq_tmp[4];
    lt_stage[0] <== 0;
    gt_stage[0] <== 0;
    eq_stage[0] <== 1;
    for (var idx = 0; idx < 4; idx++) {
        var i = 3 - idx;
        lt_i[idx] = LessThan(64);
        lt_i[idx].in[0] <== a[i];
        lt_i[idx].in[1] <== b[i];

        gt_i[idx] = LessThan(64);
        gt_i[idx].in[0] <== b[i];
        gt_i[idx].in[1] <== a[i];

        lt_stage[idx + 1] <== lt_stage[idx] + eq_stage[idx] * lt_i[idx].out;
        gt_stage[idx + 1] <== gt_stage[idx] + eq_stage[idx] * gt_i[idx].out;
        eq_tmp[idx] <== eq_stage[idx] * (1 - lt_i[idx].out);
        eq_stage[idx + 1] <== eq_tmp[idx] * (1 - gt_i[idx].out);
    }

    lt <== lt_stage[4];
    gt <== gt_stage[4];
    eq <== eq_stage[4];
    lt * (1 - lt) === 0;
    gt * (1 - gt) === 0;
    eq * (1 - eq) === 0;
    lt + gt + eq === 1;
}

// Comparator for u512 (8 limbs, little-endian).
template U512Cmp() {
    signal input a[8];
    signal input b[8];
    signal output lt;
    signal output gt;
    signal output eq;

    component lt_i[8];
    component gt_i[8];
    signal lt_stage[9];
    signal gt_stage[9];
    signal eq_stage[9];
    signal eq_tmp[8];
    lt_stage[0] <== 0;
    gt_stage[0] <== 0;
    eq_stage[0] <== 1;
    for (var idx = 0; idx < 8; idx++) {
        var i = 7 - idx;
        lt_i[idx] = LessThan(64);
        lt_i[idx].in[0] <== a[i];
        lt_i[idx].in[1] <== b[i];

        gt_i[idx] = LessThan(64);
        gt_i[idx].in[0] <== b[i];
        gt_i[idx].in[1] <== a[i];

        lt_stage[idx + 1] <== lt_stage[idx] + eq_stage[idx] * lt_i[idx].out;
        gt_stage[idx + 1] <== gt_stage[idx] + eq_stage[idx] * gt_i[idx].out;
        eq_tmp[idx] <== eq_stage[idx] * (1 - lt_i[idx].out);
        eq_stage[idx + 1] <== eq_tmp[idx] * (1 - gt_i[idx].out);
    }

    lt <== lt_stage[8];
    gt <== gt_stage[8];
    eq <== eq_stage[8];
    lt * (1 - lt) === 0;
    gt * (1 - gt) === 0;
    eq * (1 - eq) === 0;
    lt + gt + eq === 1;
}

// Addition: out = a + b, returns carry (0 or 1) if overflow.
template U256Add() {
    signal input a[4];
    signal input b[4];
    signal output out[4];
    signal output carry;

    signal carry_stage[5];
    carry_stage[0] <== 0;
    component bits[4];
    signal sum[4];
    component low_num[4];
    for (var i = 0; i < 4; i++) {
        sum[i] <== a[i] + b[i] + carry_stage[i];
        bits[i] = Num2Bits(65);
        bits[i].in <== sum[i];
        low_num[i] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i].in[k] <== bits[i].out[k];
        }
        out[i] <== low_num[i].out;
        carry_stage[i + 1] <== bits[i].out[64];
    }
    carry <== carry_stage[4];
}

// Add constant 1: out = a + 1.
template U256AddConst1() {
    signal input a[4];
    signal output out[4];
    signal output carry;

    signal one[4];
    one[0] <== 1;
    one[1] <== 0;
    one[2] <== 0;
    one[3] <== 0;

    component add = U256Add();
    for (var i = 0; i < 4; i++) {
        add.a[i] <== a[i];
        add.b[i] <== one[i];
    }
    for (var i2 = 0; i2 < 4; i2++) {
        out[i2] <== add.out[i2];
    }
    carry <== add.carry;
}

// Subtraction: out = a - b, requires a >= b.
template U256Sub() {
    signal input a[4];
    signal input b[4];
    signal output out[4];

    component cmp = U256Cmp();
    for (var i = 0; i < 4; i++) {
        cmp.a[i] <== a[i];
        cmp.b[i] <== b[i];
    }
    cmp.lt === 0;

    signal borrow_stage[5];
    borrow_stage[0] <== 0;
    component bits[4];
    signal diff[4];
    component low_num[4];
    signal is_non_negative[4];
    for (var i = 0; i < 4; i++) {
        diff[i] <== a[i] - b[i] - borrow_stage[i] + (1 << 64);
        bits[i] = Num2Bits(65);
        bits[i].in <== diff[i];
        low_num[i] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i].in[k] <== bits[i].out[k];
        }
        is_non_negative[i] <== bits[i].out[64];
        borrow_stage[i + 1] <== 1 - is_non_negative[i];
        out[i] <== low_num[i].out;
    }
    borrow_stage[4] === 0;
}

// Subtract constant 1: out = a - 1, requires a > 0.
template U256SubConst1() {
    signal input a[4];
    signal output out[4];

    signal one[4];
    one[0] <== 1;
    one[1] <== 0;
    one[2] <== 0;
    one[3] <== 0;

    component sub = U256Sub();
    for (var i = 0; i < 4; i++) {
        sub.a[i] <== a[i];
        sub.b[i] <== one[i];
        out[i] <== sub.out[i];
    }
}

// Conditional subtract 1: if enable == 1, out = a - 1 (requires a > 0); if enable == 0, out = 0.
template U256SubConst1Maybe() {
    signal input enable; // boolean
    signal input a[4];
    signal output out[4];
    signal output borrow_out; // 0 if no underflow when enabled

    enable * (enable - 1) === 0;

    signal borrow_stage[5];
    borrow_stage[0] <== enable;
    component bits[4];
    signal diff[4];
    component low_num[4];
    signal is_non_negative[4];
    for (var i = 0; i < 4; i++) {
        // diff = a[i] - borrow (only if enable == 1)
        diff[i] <== a[i] - borrow_stage[i] + (1 << 64);
        bits[i] = Num2Bits(65);
        bits[i].in <== diff[i];

        low_num[i] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i].in[k] <== bits[i].out[k];
        }
        out[i] <== a[i] + enable * (low_num[i].out - a[i]);

        // if borrow == 1 and a[i] == 0 => bits[64] == 0 => borrow persists
        is_non_negative[i] <== bits[i].out[64];
        borrow_stage[i + 1] <== borrow_stage[i] * (1 - is_non_negative[i]);
    }
    borrow_out <== borrow_stage[4];
}

// Subtraction on u512 limbs: out = a - b, requires a >= b.
template U512Sub() {
    signal input a[8];
    signal input b[8];
    signal output out[8];

    component cmp = U512Cmp();
    for (var i = 0; i < 8; i++) {
        cmp.a[i] <== a[i];
        cmp.b[i] <== b[i];
    }
    cmp.lt === 0;

    signal borrow_stage[9];
    borrow_stage[0] <== 0;
    component bits[8];
    signal diff[8];
    component low_num[8];
    signal is_non_negative[8];
    for (var i2 = 0; i2 < 8; i2++) {
        diff[i2] <== a[i2] - b[i2] - borrow_stage[i2] + (1 << 64);
        bits[i2] = Num2Bits(65);
        bits[i2].in <== diff[i2];
        low_num[i2] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i2].in[k] <== bits[i2].out[k];
        }
        is_non_negative[i2] <== bits[i2].out[64];
        borrow_stage[i2 + 1] <== 1 - is_non_negative[i2];
        out[i2] <== low_num[i2].out;
    }
    borrow_stage[8] === 0;
}

// Addition on u128 (2 limbs).
template U128Add() {
    signal input a[2];
    signal input b[2];
    signal output out[2];
    signal output carry;

    signal carry_stage[3];
    carry_stage[0] <== 0;
    component bits[2];
    signal sum[2];
    component low_num[2];
    for (var i = 0; i < 2; i++) {
        sum[i] <== a[i] + b[i] + carry_stage[i];
        bits[i] = Num2Bits(65);
        bits[i].in <== sum[i];
        low_num[i] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i].in[k] <== bits[i].out[k];
        }
        out[i] <== low_num[i].out;
        carry_stage[i + 1] <== bits[i].out[64];
    }
    carry <== carry_stage[2];
}

// Subtraction on u128 (2 limbs): out = a - b, requires a >= b.
template U128Sub() {
    signal input a[2];
    signal input b[2];
    signal output out[2];

    component cmp = U256Cmp();
    for (var i = 0; i < 2; i++) {
        cmp.a[i] <== a[i];
        cmp.b[i] <== b[i];
    }
    cmp.a[2] <== 0;
    cmp.a[3] <== 0;
    cmp.b[2] <== 0;
    cmp.b[3] <== 0;
    cmp.lt === 0;

    signal borrow_stage[3];
    borrow_stage[0] <== 0;
    component bits[2];
    signal diff[2];
    component low_num[2];
    signal is_non_negative[2];
    for (var i2 = 0; i2 < 2; i2++) {
        diff[i2] <== a[i2] - b[i2] - borrow_stage[i2] + (1 << 64);
        bits[i2] = Num2Bits(65);
        bits[i2].in <== diff[i2];
        low_num[i2] = Bits2Num(64);
        for (var k = 0; k < 64; k++) {
            low_num[i2].in[k] <== bits[i2].out[k];
        }
        is_non_negative[i2] <== bits[i2].out[64];
        borrow_stage[i2 + 1] <== 1 - is_non_negative[i2];
        out[i2] <== low_num[i2].out;
    }
    borrow_stage[2] === 0;
}

// Multiplication: out = a * b producing u512 (8 limbs).
template U256Mul() {
    signal input a[4];
    signal input b[4];
    signal output out[8];

    signal carry_stage[8];
    carry_stage[0] <== 0;
    component bits[7];
    signal sum[7];
    signal term0[7];
    signal term1[7];
    signal term2[7];
    signal term3[7];
    component low_num[7];
    component high_num[7];
    for (var k = 0; k < 7; k++) {
        // Only valid (i, j) pairs where j = k - i and 0 <= j < 4 contribute.
        if ((k - 0 >= 0) && (k - 0 < 4)) {
            term0[k] <== a[0] * b[k - 0];
        } else {
            term0[k] <== 0;
        }
        if ((k - 1 >= 0) && (k - 1 < 4)) {
            term1[k] <== a[1] * b[k - 1];
        } else {
            term1[k] <== 0;
        }
        if ((k - 2 >= 0) && (k - 2 < 4)) {
            term2[k] <== a[2] * b[k - 2];
        } else {
            term2[k] <== 0;
        }
        if ((k - 3 >= 0) && (k - 3 < 4)) {
            term3[k] <== a[3] * b[k - 3];
        } else {
            term3[k] <== 0;
        }
        sum[k] <== carry_stage[k] + term0[k] + term1[k] + term2[k] + term3[k];
        // sum upper bound ~2^131; use 196 bits for safety
        bits[k] = Num2Bits(196);
        bits[k].in <== sum[k];
        low_num[k] = Bits2Num(64);
        for (var t = 0; t < 64; t++) {
            low_num[k].in[t] <== bits[k].out[t];
        }
        out[k] <== low_num[k].out;

        high_num[k] = Bits2Num(132);
        for (var t2 = 64; t2 < 196; t2++) {
            high_num[k].in[t2 - 64] <== bits[k].out[t2];
        }
        carry_stage[k + 1] <== high_num[k].out;
    }
    out[7] <== carry_stage[7];
    component carry_bits = Num2Bits(64);
    carry_bits.in <== carry_stage[7];
}

// Shift right by 128 bits on u512 -> u256. Requires high limbs (6,7) to be zero.
template U512ShiftRight128() {
    signal input in[8];
    signal output out[4];

    out[0] <== in[2];
    out[1] <== in[3];
    out[2] <== in[4];
    out[3] <== in[5];

    in[6] === 0;
    in[7] === 0;
}

// Select between two u256 values: out = sel ? a : b
template U256Select() {
    signal input sel; // boolean
    signal input a[4];
    signal input b[4];
    signal output out[4];

    sel * (sel - 1) === 0;
    for (var i = 0; i < 4; i++) {
        out[i] <== b[i] + sel * (a[i] - b[i]);
    }
}

// Floor division constraint: q = floor(num / den).
// Enforces q*den <= num < (q+1)*den.
template DivFloorConstraint() {
    signal input num[8]; // u512
    signal input den[4]; // u256
    signal input q_val[4]; // witness-provided quotient
    signal output q[4];    // exposed copy

    component rc = U256RangeCheck();
    for (var i = 0; i < 4; i++) rc.limbs[i] <== q_val[i];

    component prod = U256Mul();
    for (var i2 = 0; i2 < 4; i2++) {
        prod.a[i2] <== q_val[i2];
        prod.b[i2] <== den[i2];
    }

    component q_plus_1 = U256AddConst1();
    for (var i3 = 0; i3 < 4; i3++) {
        q_plus_1.a[i3] <== q_val[i3];
    }
    // overflow not allowed: carry must be 0
    q_plus_1.carry === 0;

    component prod_next = U256Mul();
    for (var i4 = 0; i4 < 4; i4++) {
        prod_next.a[i4] <== q_plus_1.out[i4];
        prod_next.b[i4] <== den[i4];
    }

    // prod <= num
    component cmp_low = U512Cmp();
    for (var j = 0; j < 8; j++) {
        cmp_low.a[j] <== prod.out[j];
        cmp_low.b[j] <== num[j];
    }
    cmp_low.gt === 0;

    // num < prod_next
    component cmp_high = U512Cmp();
    for (var j2 = 0; j2 < 8; j2++) {
        cmp_high.a[j2] <== num[j2];
        cmp_high.b[j2] <== prod_next.out[j2];
    }
    cmp_high.lt === 1;

    for (var qo = 0; qo < 4; qo++) {
        q[qo] <== q_val[qo];
    }
}

// Ceil division constraint: q = ceil(num / den).
// Enforces (q == 0 -> num == 0) else (q-1)*den < num <= q*den.
template DivCeilConstraint() {
    signal input num[8]; // u512
    signal input den[4]; // u256
    signal input q_val[4]; // witness-provided quotient
    signal output q[4];  // u256

    component rc = U256RangeCheck();
    for (var i = 0; i < 4; i++) rc.limbs[i] <== q_val[i];

    // q_zero derived from q
    signal q_zero;
    // q_zero = 1 iff all limbs are zero
    signal sum_q;
    sum_q <== q_val[0] + q_val[1] + q_val[2] + q_val[3];
    component q_zero_check = IsEqual();
    q_zero_check.in[0] <== sum_q;
    q_zero_check.in[1] <== 0;
    q_zero <== q_zero_check.out;
    // Booleanize q_zero and tie to sum_q
    q_zero * (q_zero - 1) === 0;
    sum_q * q_zero === 0; // if q_zero=1 then sum_q must be 0
    // if sum_q == 0 then q_zero can be 0 or 1; caller doesn’t need the reverse implication.

    component prod = U256Mul();
    for (var i3 = 0; i3 < 4; i3++) {
        prod.a[i3] <== q_val[i3];
        prod.b[i3] <== den[i3];
    }

    // num <= prod
    component cmp_upper = U512Cmp();
    for (var j = 0; j < 8; j++) {
        cmp_upper.a[j] <== num[j];
        cmp_upper.b[j] <== prod.out[j];
    }
    cmp_upper.gt === 0;

    // if q == 0, enforce num == 0
    for (var k = 0; k < 8; k++) {
        num[k] * q_zero === 0;
    }

    // if q > 0, enforce (q-1)*den < num
    signal one_minus_qz;
    one_minus_qz <== 1 - q_zero;

    component qm1 = U256SubConst1Maybe();
    qm1.enable <== one_minus_qz;
    for (var t = 0; t < 4; t++) {
        qm1.a[t] <== q_val[t];
    }
    // when enabled, must not underflow (borrow_out == 0)
    qm1.borrow_out * one_minus_qz === 0;

    component prod_prev = U256Mul();
    for (var t2 = 0; t2 < 4; t2++) {
        prod_prev.a[t2] <== qm1.out[t2];
        prod_prev.b[t2] <== den[t2];
    }

    component cmp_lower = U512Cmp();
    for (var p = 0; p < 8; p++) {
    cmp_lower.a[p] <== prod_prev.out[p];
    cmp_lower.b[p] <== num[p];
    }
    cmp_lower.lt * one_minus_qz === one_minus_qz;

    for (var qo = 0; qo < 4; qo++) {
        q[qo] <== q_val[qo];
    }
}

// Divide a u512 numerator by a u256 denominator with floor rounding.
template U256DivFloor() {
    signal input num[8];
    signal input den[4];
    signal input q_val[4];
    signal output out[4];

    component div = DivFloorConstraint();
    for (var i = 0; i < 8; i++) {
        div.num[i] <== num[i];
    }
    for (var j = 0; j < 4; j++) {
        div.den[j] <== den[j];
        div.q_val[j] <== q_val[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        out[j2] <== div.q[j2];
    }
}

// Divide a u512 numerator by a u256 denominator with ceil rounding.
template U256DivCeil() {
    signal input num[8];
    signal input den[4];
    signal input q_val[4];
    signal output out[4];

    component div = DivCeilConstraint();
    for (var i = 0; i < 8; i++) {
        div.num[i] <== num[i];
    }
    for (var j = 0; j < 4; j++) {
        div.den[j] <== den[j];
        div.q_val[j] <== q_val[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        out[j2] <== div.q[j2];
    }
}
