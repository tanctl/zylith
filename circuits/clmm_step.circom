pragma circom 2.2.3;

// swap step arithmetic for exact-input swaps (ekubo semantics)
// only exact-input swaps are supported in this version

include "./math/bigint.circom";
include "./constants/generated.circom";

template DecomposeU256ToLimbs() {
    signal input value;
    signal output limbs[4];
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
    limbs[0] <== limb0.out;
    limbs[1] <== limb1.out;
    limbs[2] <== limb2.out;
    limbs[3] <== limb3.out;
}

template TickSpacingCheck() {
    signal input tick_spacing;

    component spacing_bits = Num2Bits(128);
    spacing_bits.in <== tick_spacing;

    component spacing_zero = IsEqual();
    spacing_zero.in[0] <== tick_spacing;
    spacing_zero.in[1] <== 0;
    spacing_zero.out === 0;

    component spacing_lt = LessThan(128);
    spacing_lt.in[0] <== tick_spacing;
    spacing_lt.in[1] <== MAX_TICK_SPACING() + 1;
    spacing_lt.out === 1;
}

template DecodeSignedI128Checked() {
    signal input value;
    signal output sign;
    signal output mag;

    component dec = DecomposeU256ToLimbs();
    dec.value <== value;
    dec.limbs[2] === 0;
    dec.limbs[3] === 0;

    signal low_u128;
    low_u128 <== dec.limbs[0] + dec.limbs[1] * (1 << 64);
    component low_bits = Num2Bits(128);
    low_bits.in <== low_u128;
    component low_l0 = Bits2Num(64);
    component low_l1 = Bits2Num(64);
    for (var i = 0; i < 64; i++) {
        low_l0.in[i] <== low_bits.out[i];
        low_l1.in[i] <== low_bits.out[64 + i];
    }
    low_l0.out === dec.limbs[0];
    low_l1.out === dec.limbs[1];

    sign <== low_bits.out[127];
    sign * (sign - 1) === 0;

    signal mag_pos;
    mag_pos <== low_u128;

    component inv = U128Sub();
    component low_limbs = U128ToU256Limbs();
    low_limbs.in <== low_u128;
    signal max_limbs[2];
    max_limbs[0] <== 0xffffffffffffffff;
    max_limbs[1] <== 0xffffffffffffffff;
    inv.a[0] <== max_limbs[0];
    inv.a[1] <== max_limbs[1];
    inv.b[0] <== low_limbs.limbs[0];
    inv.b[1] <== low_limbs.limbs[1];

    signal one_limbs[2];
    one_limbs[0] <== 1;
    one_limbs[1] <== 0;
    component neg_add = U128Add();
    neg_add.a[0] <== inv.out[0];
    neg_add.a[1] <== inv.out[1];
    neg_add.b[0] <== one_limbs[0];
    neg_add.b[1] <== one_limbs[1];
    neg_add.carry * sign === 0;

    signal mag_neg;
    mag_neg <== neg_add.out[0] + neg_add.out[1] * (1 << 64);

    signal mag_sel_neg;
    signal mag_sel_pos;
    mag_sel_neg <== sign * mag_neg;
    mag_sel_pos <== (1 - sign) * mag_pos;
    mag <== mag_sel_neg + mag_sel_pos;

    component mag_bits = Num2Bits(128);
    mag_bits.in <== mag;
    mag_bits.out[127] === 0;
}

// decode a signed i128 embedded in u256 (two's-complement, sign-extended)
template DecodeSignedI256ToU128() {
    signal input value;
    signal output sign;
    signal output mag;

    component dec = DecomposeU256ToLimbs();
    dec.value <== value;

    signal low_u128;
    low_u128 <== dec.limbs[0] + dec.limbs[1] * (1 << 64);
    signal high_u128;
    high_u128 <== dec.limbs[2] + dec.limbs[3] * (1 << 64);

    component low_bits = Num2Bits(128);
    low_bits.in <== low_u128;
    signal low_sign_bit;
    low_sign_bit <== low_bits.out[127];
    sign <== low_sign_bit;
    sign * (sign - 1) === 0;
    component high_zero = IsEqual();
    high_zero.in[0] <== high_u128;
    high_zero.in[1] <== 0;
    high_zero.out === 1;
    component low_eq_min = IsEqual();
    low_eq_min.in[0] <== low_u128;
    low_eq_min.in[1] <== (1 << 127);

    component inv = U128Sub();
    signal max_limbs[2];
    max_limbs[0] <== 0xffffffffffffffff;
    max_limbs[1] <== 0xffffffffffffffff;
    component low_limbs = U128ToU256Limbs();
    low_limbs.in <== low_u128;
    inv.a[0] <== max_limbs[0];
    inv.a[1] <== max_limbs[1];
    inv.b[0] <== low_limbs.limbs[0];
    inv.b[1] <== low_limbs.limbs[1];

    signal one_limbs[2];
    one_limbs[0] <== 1;
    one_limbs[1] <== 0;
    component neg_add = U128Add();
    neg_add.a[0] <== inv.out[0];
    neg_add.a[1] <== inv.out[1];
    neg_add.b[0] <== one_limbs[0];
    neg_add.b[1] <== one_limbs[1];
    neg_add.carry * sign === 0;

    signal mag_neg;
    mag_neg <== neg_add.out[0] + neg_add.out[1] * (1 << 64);

    component low_zero = IsEqual();
    low_zero.in[0] <== low_u128;
    low_zero.in[1] <== 0;
    sign * low_zero.out === 0;

    signal mag_sel_neg;
    signal mag_sel_pos;
    mag_sel_neg <== sign * mag_neg;
    mag_sel_pos <== (1 - sign) * low_u128;
    mag <== mag_sel_neg + mag_sel_pos;

    component mag_bits = Num2Bits(128);
    mag_bits.in <== mag;
    signal is_min;
    is_min <== sign * low_eq_min.out;
    mag_bits.out[127] === is_min;
}

// unsafe_mul_shift: out = (ratio * mul_const) >> 128, using the low 256 bits of the product
template UnsafeMulShift(mul_const) {
    signal input ratio;
    signal output out;

    component ratio_limbs = DecomposeU256ToLimbs();
    ratio_limbs.value <== ratio;

    component mul_limbs = U128ToU256Limbs();
    mul_limbs.in <== mul_const;

    component prod = U256Mul();
    for (var i = 0; i < 4; i++) {
        prod.a[i] <== ratio_limbs.limbs[i];
        prod.b[i] <== mul_limbs.limbs[i];
    }

    out <== prod.out[2] + prod.out[3] * (1 << 64);
    component out_limbs = U128ToU256Limbs();
    out_limbs.in <== out;
    out_limbs.limbs[0] === prod.out[2];
    out_limbs.limbs[1] === prod.out[3];
    out_limbs.limbs[2] === 0;
    out_limbs.limbs[3] === 0;
}

// computes sqrt(1.000001)^tick as a Q128.128 u256, matching cairo tick_to_sqrt_ratio
template TickToSqrtRatio() {
    signal input tick;
    signal input inv_div_q[4];
    signal output sqrt_ratio;

    var MAX_TICK_MAGNITUDE = 88722883;
    var BASE_RATIO = 0x100000000000000000000000000000000;

    component dec = DecodeSignedI128Checked();
    dec.value <== tick;

    component mag_lt = LessThan(128);
    mag_lt.in[0] <== dec.mag;
    mag_lt.in[1] <== MAX_TICK_MAGNITUDE + 1;
    mag_lt.out === 1;

    component mag_bits = Num2Bits(128);
    mag_bits.in <== dec.mag;

    signal ratio_chain[28];
    ratio_chain[0] <== BASE_RATIO;

    var mul_consts[27];
    mul_consts[0] = 0xfffff79c8499329c7cbb2510d893283b;
    mul_consts[1] = 0xffffef390978c398134b4ff3764fe410;
    mul_consts[2] = 0xffffde72140b00a354bd3dc828e976c9;
    mul_consts[3] = 0xffffbce42c7be6c998ad6318193c0b18;
    mul_consts[4] = 0xffff79c86a8f6150a32d9778eceef97c;
    mul_consts[5] = 0xfffef3911b7cff24ba1b3dbb5f8f5974;
    mul_consts[6] = 0xfffde72350725cc4ea8feece3b5f13c8;
    mul_consts[7] = 0xfffbce4b06c196e9247ac87695d53c60;
    mul_consts[8] = 0xfff79ca7a4d1bf1ee8556cea23cdbaa5;
    mul_consts[9] = 0xffef3995a5b6a6267530f207142a5764;
    mul_consts[10] = 0xffde7444b28145508125d10077ba83b8;
    mul_consts[11] = 0xffbceceeb791747f10df216f2e53ec57;
    mul_consts[12] = 0xff79eb706b9a64c6431d76e63531e929;
    mul_consts[13] = 0xfef41d1a5f2ae3a20676bec6f7f9459a;
    mul_consts[14] = 0xfde95287d26d81bea159c37073122c73;
    mul_consts[15] = 0xfbd701c7cbc4c8a6bb81efd232d1e4e7;
    mul_consts[16] = 0xf7bf5211c72f5185f372aeb1d48f937e;
    mul_consts[17] = 0xefc2bf59df33ecc28125cf78ec4f167f;
    mul_consts[18] = 0xe08d35706200796273f0b3a981d90cfd;
    mul_consts[19] = 0xc4f76b68947482dc198a48a54348c4ed;
    mul_consts[20] = 0x978bcb9894317807e5fa4498eee7c0fa;
    mul_consts[21] = 0x59b63684b86e9f486ec54727371ba6ca;
    mul_consts[22] = 0x1f703399d88f6aa83a28b22d4a1f56e3;
    mul_consts[23] = 0x3dc5dac7376e20fc8679758d1bcdcfc;
    mul_consts[24] = 0xee7e32d61fdb0a5e622b820f681d0;
    mul_consts[25] = 0xde2ee4bc381afa7089aa84bb66;
    mul_consts[26] = 0xc0d55d4d7152c25fb139;

    component mul_shift[27];
    component ratio_sel[27];
    component ratio_limbs[28];
    component mul_limbs[27];

    ratio_limbs[0] = DecomposeU256ToLimbs();
    ratio_limbs[0].value <== ratio_chain[0];

    for (var i = 0; i < 27; i++) {
        mul_shift[i] = UnsafeMulShift(mul_consts[i]);
        mul_shift[i].ratio <== ratio_chain[i];

        mul_limbs[i] = DecomposeU256ToLimbs();
        mul_limbs[i].value <== mul_shift[i].out;

        ratio_sel[i] = U256Select();
        ratio_sel[i].sel <== mag_bits.out[i];
        for (var l = 0; l < 4; l++) {
            ratio_sel[i].a[l] <== mul_limbs[i].limbs[l];
            ratio_sel[i].b[l] <== ratio_limbs[i].limbs[l];
        }
        ratio_chain[i + 1] <== ratio_sel[i].out[0]
            + ratio_sel[i].out[1] * (1 << 64)
            + ratio_sel[i].out[2] * (1 << 128)
            + ratio_sel[i].out[3] * (1 << 192);
        ratio_limbs[i + 1] = DecomposeU256ToLimbs();
        ratio_limbs[i + 1].value <== ratio_chain[i + 1];
        for (var l2 = 0; l2 < 4; l2++) {
            ratio_limbs[i + 1].limbs[l2] === ratio_sel[i].out[l2];
        }
    }

    signal ratio_raw;
    ratio_raw <== ratio_chain[27];
    component ratio_raw_limbs = DecomposeU256ToLimbs();
    ratio_raw_limbs.value <== ratio_raw;

    component mag_zero = IsEqual();
    mag_zero.in[0] <== dec.mag;
    mag_zero.in[1] <== 0;
    signal invert;
    invert <== (1 - dec.sign) * (1 - mag_zero.out);
    invert * (invert - 1) === 0;

    component inv = U256DivFloor();
    inv.num[0] <== 0xffffffffffffffff;
    inv.num[1] <== 0xffffffffffffffff;
    inv.num[2] <== 0xffffffffffffffff;
    inv.num[3] <== 0xffffffffffffffff;
    inv.num[4] <== 0;
    inv.num[5] <== 0;
    inv.num[6] <== 0;
    inv.num[7] <== 0;
    for (var d = 0; d < 4; d++) {
        inv.den[d] <== ratio_raw_limbs.limbs[d];
        inv.q_val[d] <== inv_div_q[d];
    }

    component inv_sel = U256Select();
    inv_sel.sel <== invert;
    for (var l3 = 0; l3 < 4; l3++) {
        inv_sel.a[l3] <== inv.out[l3];
        inv_sel.b[l3] <== ratio_raw_limbs.limbs[l3];
    }
    sqrt_ratio <== inv_sel.out[0]
        + inv_sel.out[1] * (1 << 64)
        + inv_sel.out[2] * (1 << 128)
        + inv_sel.out[3] * (1 << 192);
    component sqrt_limbs = DecomposeU256ToLimbs();
    sqrt_limbs.value <== sqrt_ratio;
    for (var l4 = 0; l4 < 4; l4++) {
        sqrt_limbs.limbs[l4] === inv_sel.out[l4];
    }
}

template TickRangeCheck() {
    signal input tick;
    signal output sign;
    signal output mag;
    var MAX_TICK_MAGNITUDE = 88722883;

    component dec = DecodeSignedI128Checked();
    dec.value <== tick;
    sign <== dec.sign;
    mag <== dec.mag;

    component mag_lt = LessThan(128);
    mag_lt.in[0] <== mag;
    mag_lt.in[1] <== MAX_TICK_MAGNITUDE + 1;
    mag_lt.out === 1;
}

template TickRangeCheckAllowMinMinusOne() {
    signal input tick;
    signal output sign;
    // allow min_tick - 1 for pool tick (ekubo boundary behavior)
    signal output mag;
    var MAX_TICK_MAGNITUDE = 88722883;

    component dec = DecodeSignedI128Checked();
    dec.value <== tick;
    sign <== dec.sign;
    mag <== dec.mag;

    component mag_lt_max = LessThan(128);
    mag_lt_max.in[0] <== mag;
    mag_lt_max.in[1] <== MAX_TICK_MAGNITUDE + 1;

    component mag_lt_max_plus = LessThan(128);
    mag_lt_max_plus.in[0] <== mag;
    mag_lt_max_plus.in[1] <== MAX_TICK_MAGNITUDE + 2;

    (1 - sign) * (1 - mag_lt_max.out) === 0;
    sign * (1 - mag_lt_max_plus.out) === 0;
}

template TickAlignmentCheck() {
    signal input mag;
    signal input tick_spacing;

    signal tick_quotient;
    tick_quotient <-- mag / tick_spacing;
    component q_bits = Num2Bits(128);
    q_bits.in <== tick_quotient;

    mag === tick_spacing * tick_quotient;
}

template U256Eq() {
    signal input a[4];
    signal input b[4];
    signal output eq;
    component cmp = U256Cmp();
    for (var i = 0; i < 4; i++) {
        cmp.a[i] <== a[i];
        cmp.b[i] <== b[i];
    }
    eq <== cmp.eq;
}

template U256IsZero() {
    signal input limbs[4];
    signal output out;
    component eq0 = IsEqual();
    component eq1 = IsEqual();
    component eq2 = IsEqual();
    component eq3 = IsEqual();
    eq0.in[0] <== limbs[0];
    eq0.in[1] <== 0;
    eq1.in[0] <== limbs[1];
    eq1.in[1] <== 0;
    eq2.in[0] <== limbs[2];
    eq2.in[1] <== 0;
    eq3.in[0] <== limbs[3];
    eq3.in[1] <== 0;
    signal eq01;
    signal eq23;
    eq01 <== eq0.out * eq1.out;
    eq23 <== eq2.out * eq3.out;
    out <== eq01 * eq23;
}

template U128IsZero() {
    signal input limbs[2];
    signal output out;
    component eq0 = IsEqual();
    component eq1 = IsEqual();
    eq0.in[0] <== limbs[0];
    eq0.in[1] <== 0;
    eq1.in[0] <== limbs[1];
    eq1.in[1] <== 0;
    out <== eq0.out * eq1.out;
}

// ceil(amount * fee / 2^128)
template ComputeFee() {
    signal input amount;
    signal input fee;
    signal output fee_amount;

    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount;
    component fee_limbs = U128ToU256Limbs();
    fee_limbs.in <== fee;

    component mul = U256Mul();
    for (var i = 0; i < 4; i++) {
        mul.a[i] <== amt_limbs.limbs[i];
        mul.b[i] <== fee_limbs.limbs[i];
    }
    // product fits in u256
    for (var i2 = 4; i2 < 8; i2++) {
        mul.out[i2] === 0;
    }

    component low_zero = IsEqual();
    low_zero.in[0] <== mul.out[0] + mul.out[1];
    low_zero.in[1] <== 0;
    signal add_one;
    add_one <== 1 - low_zero.out;

    signal high_limbs[2];
    high_limbs[0] <== mul.out[2];
    high_limbs[1] <== mul.out[3];

    signal add_one_limbs[2];
    add_one_limbs[0] <== add_one;
    add_one_limbs[1] <== 0;

    component add = U128Add();
    for (var i3 = 0; i3 < 2; i3++) {
        add.a[i3] <== high_limbs[i3];
        add.b[i3] <== add_one_limbs[i3];
    }
    add.carry === 0;

    fee_amount <== add.out[0] + add.out[1] * (1 << 64);
}

// ceil(after_fee * 2^128 / (2^128 - fee))
template AmountBeforeFee() {
    signal input after_fee;
    signal input fee;
    signal input div_q[4];
    signal output before_fee;

    component after_limbs = U128ToU256Limbs();
    after_limbs.in <== after_fee;

    // numerator = after_fee << 128
    signal numerator_u256[4];
    numerator_u256[0] <== 0;
    numerator_u256[1] <== 0;
    numerator_u256[2] <== after_limbs.limbs[0];
    numerator_u256[3] <== after_limbs.limbs[1];

    // denominator = 2^128 - fee
    signal denom_base[4];
    denom_base[0] <== 0;
    denom_base[1] <== 0;
    denom_base[2] <== 1;
    denom_base[3] <== 0;

    component fee_limbs = U128ToU256Limbs();
    fee_limbs.in <== fee;

    component denom_sub = U256Sub();
    for (var i = 0; i < 4; i++) {
        denom_sub.a[i] <== denom_base[i];
        denom_sub.b[i] <== fee_limbs.limbs[i];
    }

    // div floor
    signal numerator_u512[8];
    for (var j = 0; j < 4; j++) {
        numerator_u512[j] <== numerator_u256[j];
    }
    for (var j2 = 4; j2 < 8; j2++) {
        numerator_u512[j2] <== 0;
    }

    component div = U256DivFloor();
    for (var k = 0; k < 8; k++) {
        div.num[k] <== numerator_u512[k];
    }
    for (var k2 = 0; k2 < 4; k2++) {
        div.den[k2] <== denom_sub.out[k2];
        div.q_val[k2] <== div_q[k2];
    }

    // remainder = numerator - q*den
    component prod = U256Mul();
    for (var m = 0; m < 4; m++) {
        prod.a[m] <== div.out[m];
        prod.b[m] <== denom_sub.out[m];
    }
    component rem = U512Sub();
    for (var n = 0; n < 8; n++) {
        rem.a[n] <== numerator_u512[n];
        rem.b[n] <== prod.out[n];
    }

    component rem_zero = IsEqual();
    signal rem_sum;
    rem_sum <== rem.out[0] + rem.out[1] + rem.out[2] + rem.out[3] + rem.out[4] + rem.out[5] + rem.out[6] + rem.out[7];
    rem_zero.in[0] <== rem_sum;
    rem_zero.in[1] <== 0;
    signal add_one;
    add_one <== 1 - rem_zero.out;

    // quotient must fit u128
    div.out[2] === 0;
    div.out[3] === 0;

    signal add_one_limbs[2];
    add_one_limbs[0] <== add_one;
    add_one_limbs[1] <== 0;

    component add = U128Add();
    add.a[0] <== div.out[0];
    add.a[1] <== div.out[1];
    add.b[0] <== add_one_limbs[0];
    add.b[1] <== add_one_limbs[1];
    add.carry === 0;

    before_fee <== add.out[0] + add.out[1] * (1 << 64);
    component out = U128ToU256Limbs();
    out.in <== before_fee;
    out.limbs[0] === add.out[0];
    out.limbs[1] === add.out[1];
    out.limbs[2] === 0;
    out.limbs[3] === 0;
}

// amount0_delta with rounding
template Amount0Delta() {
    signal input sqrt_ratio_a;
    signal input sqrt_ratio_b;
    signal input liquidity;
    signal input round_up;
    signal input div_q[4][4];
    signal output amount0;

    round_up * (round_up - 1) === 0;

    component dec_a = DecomposeU256ToLimbs();
    component dec_b = DecomposeU256ToLimbs();
    dec_a.value <== sqrt_ratio_a;
    dec_b.value <== sqrt_ratio_b;

    component cmp = U256Cmp();
    for (var i = 0; i < 4; i++) {
        cmp.a[i] <== dec_a.limbs[i];
        cmp.b[i] <== dec_b.limbs[i];
    }

    component lower_sel = U256Select();
    component upper_sel = U256Select();
    lower_sel.sel <== cmp.lt;
    upper_sel.sel <== cmp.lt;
    for (var i2 = 0; i2 < 4; i2++) {
        lower_sel.a[i2] <== dec_a.limbs[i2];
        lower_sel.b[i2] <== dec_b.limbs[i2];
        upper_sel.a[i2] <== dec_b.limbs[i2];
        upper_sel.b[i2] <== dec_a.limbs[i2];
    }

    component delta = U256Sub();
    for (var i3 = 0; i3 < 4; i3++) {
        delta.a[i3] <== upper_sel.out[i3];
        delta.b[i3] <== lower_sel.out[i3];
    }

    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;

    // numerator1 = liquidity << 128
    signal numerator1[4];
    numerator1[0] <== 0;
    numerator1[1] <== 0;
    numerator1[2] <== liq_limbs.limbs[0];
    numerator1[3] <== liq_limbs.limbs[1];

    // muldiv numerator1 * delta / upper
    component mul = U256Mul();
    for (var i4 = 0; i4 < 4; i4++) {
        mul.a[i4] <== numerator1[i4];
        mul.b[i4] <== delta.out[i4];
    }

    component div_floor = U256DivFloor();
    component div_ceil = U256DivCeil();
    for (var j = 0; j < 8; j++) {
        div_floor.num[j] <== mul.out[j];
        div_ceil.num[j] <== mul.out[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        div_floor.den[j2] <== upper_sel.out[j2];
        div_ceil.den[j2] <== upper_sel.out[j2];
        div_floor.q_val[j2] <== div_q[0][j2];
        div_ceil.q_val[j2] <== div_q[1][j2];
    }

    component mid_sel = U256Select();
    mid_sel.sel <== round_up;
    for (var j3 = 0; j3 < 4; j3++) {
        mid_sel.a[j3] <== div_ceil.out[j3];
        mid_sel.b[j3] <== div_floor.out[j3];
    }

    // div mid / lower
    signal mid_u512[8];
    for (var k = 0; k < 4; k++) {
        mid_u512[k] <== mid_sel.out[k];
    }
    for (var k2 = 4; k2 < 8; k2++) {
        mid_u512[k2] <== 0;
    }

    component div2_floor = U256DivFloor();
    component div2_ceil = U256DivCeil();
    for (var m = 0; m < 8; m++) {
        div2_floor.num[m] <== mid_u512[m];
        div2_ceil.num[m] <== mid_u512[m];
    }
    for (var m2 = 0; m2 < 4; m2++) {
        div2_floor.den[m2] <== lower_sel.out[m2];
        div2_ceil.den[m2] <== lower_sel.out[m2];
        div2_floor.q_val[m2] <== div_q[2][m2];
        div2_ceil.q_val[m2] <== div_q[3][m2];
    }

    component out_sel = U256Select();
    out_sel.sel <== round_up;
    for (var n = 0; n < 4; n++) {
        out_sel.a[n] <== div2_ceil.out[n];
        out_sel.b[n] <== div2_floor.out[n];
    }

    out_sel.out[2] === 0;
    out_sel.out[3] === 0;

    amount0 <== out_sel.out[0] + out_sel.out[1] * (1 << 64);
    component out = U128ToU256Limbs();
    out.in <== amount0;
    out.limbs[0] === out_sel.out[0];
    out.limbs[1] === out_sel.out[1];
    out.limbs[2] === 0;
    out.limbs[3] === 0;
}

// amount1_delta with rounding
template Amount1Delta() {
    signal input sqrt_ratio_a;
    signal input sqrt_ratio_b;
    signal input liquidity;
    signal input round_up;
    signal output amount1;

    round_up * (round_up - 1) === 0;

    component dec_a = DecomposeU256ToLimbs();
    component dec_b = DecomposeU256ToLimbs();
    dec_a.value <== sqrt_ratio_a;
    dec_b.value <== sqrt_ratio_b;

    component cmp = U256Cmp();
    for (var i = 0; i < 4; i++) {
        cmp.a[i] <== dec_a.limbs[i];
        cmp.b[i] <== dec_b.limbs[i];
    }

    component lower_sel = U256Select();
    component upper_sel = U256Select();
    lower_sel.sel <== cmp.lt;
    upper_sel.sel <== cmp.lt;
    for (var i2 = 0; i2 < 4; i2++) {
        lower_sel.a[i2] <== dec_a.limbs[i2];
        lower_sel.b[i2] <== dec_b.limbs[i2];
        upper_sel.a[i2] <== dec_b.limbs[i2];
        upper_sel.b[i2] <== dec_a.limbs[i2];
    }

    component delta = U256Sub();
    for (var i3 = 0; i3 < 4; i3++) {
        delta.a[i3] <== upper_sel.out[i3];
        delta.b[i3] <== lower_sel.out[i3];
    }

    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;

    component mul = U256Mul();
    for (var i4 = 0; i4 < 4; i4++) {
        mul.a[i4] <== delta.out[i4];
        mul.b[i4] <== liq_limbs.limbs[i4];
    }
    for (var i5 = 4; i5 < 8; i5++) {
        mul.out[i5] === 0;
    }

    signal high_limbs[2];
    high_limbs[0] <== mul.out[2];
    high_limbs[1] <== mul.out[3];
    signal low_sum;
    low_sum <== mul.out[0] + mul.out[1];
    component low_zero = IsEqual();
    low_zero.in[0] <== low_sum;
    low_zero.in[1] <== 0;
    signal add_one;
    add_one <== round_up * (1 - low_zero.out);

    signal add_one_limbs[2];
    add_one_limbs[0] <== add_one;
    add_one_limbs[1] <== 0;

    component add = U128Add();
    for (var j = 0; j < 2; j++) {
        add.a[j] <== high_limbs[j];
        add.b[j] <== add_one_limbs[j];
    }
    add.carry === 0;

    amount1 <== add.out[0] + add.out[1] * (1 << 64);
    component out = U128ToU256Limbs();
    out.in <== amount1;
    out.limbs[0] === add.out[0];
    out.limbs[1] === add.out[1];
    out.limbs[2] === 0;
    out.limbs[3] === 0;
}

// next sqrt ratio for token0 exact input
template NextSqrtRatioFromAmount0() {
    signal input sqrt_ratio;
    signal input liquidity;
    signal input amount;
    signal input div_floor_q[4];
    signal input div_ceil_q[4];
    signal output sqrt_ratio_next;
    signal output overflow;

    component sqrt_limbs = DecomposeU256ToLimbs();
    sqrt_limbs.value <== sqrt_ratio;
    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;
    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== amt_limbs.limbs[0];
    amt_zero.limbs[1] <== amt_limbs.limbs[1];

    // numerator1 = liquidity << 128
    signal numerator1[4];
    numerator1[0] <== 0;
    numerator1[1] <== 0;
    numerator1[2] <== liq_limbs.limbs[0];
    numerator1[3] <== liq_limbs.limbs[1];

    // denom_p1 = floor(numerator1 / sqrt_ratio)
    signal numerator_u512[8];
    for (var i = 0; i < 4; i++) {
        numerator_u512[i] <== numerator1[i];
    }
    for (var i2 = 4; i2 < 8; i2++) {
        numerator_u512[i2] <== 0;
    }

    component div = U256DivFloor();
    for (var j = 0; j < 8; j++) {
        div.num[j] <== numerator_u512[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        div.den[j2] <== sqrt_limbs.limbs[j2];
        div.q_val[j2] <== div_floor_q[j2];
    }

    // denominator = denom_p1 + amount + (amount_zero ? 1 : 0)
    signal add_one;
    add_one <== amt_zero.out;
    signal add_one_limbs[4];
    add_one_limbs[0] <== add_one;
    add_one_limbs[1] <== 0;
    add_one_limbs[2] <== 0;
    add_one_limbs[3] <== 0;

    component denom_add = U256Add();
    for (var k = 0; k < 4; k++) {
        denom_add.a[k] <== div.out[k];
        denom_add.b[k] <== amt_limbs.limbs[k];
    }
    component denom_add2 = U256Add();
    for (var k2 = 0; k2 < 4; k2++) {
        denom_add2.a[k2] <== denom_add.out[k2];
        denom_add2.b[k2] <== add_one_limbs[k2];
    }
    signal overflow_raw;
    overflow_raw <== denom_add.carry + denom_add2.carry - denom_add.carry * denom_add2.carry;
    overflow_raw * (overflow_raw - 1) === 0;
    overflow <== overflow_raw * (1 - amt_zero.out);
    overflow * (overflow - 1) === 0;

    component div2 = U256DivCeil();
    for (var m = 0; m < 8; m++) {
        div2.num[m] <== numerator_u512[m];
    }
    for (var m2 = 0; m2 < 4; m2++) {
        div2.den[m2] <== denom_add2.out[m2];
        div2.q_val[m2] <== div_ceil_q[m2];
    }

    component out_sel = U256Select();
    out_sel.sel <== amt_zero.out;
    for (var n = 0; n < 4; n++) {
        out_sel.a[n] <== sqrt_limbs.limbs[n];
        out_sel.b[n] <== div2.out[n];
    }

    sqrt_ratio_next <== out_sel.out[0]
        + out_sel.out[1] * (1 << 64)
        + out_sel.out[2] * (1 << 128)
        + out_sel.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_ratio_next;
    for (var o = 0; o < 4; o++) {
        out.limbs[o] === out_sel.out[o];
    }
}

// next sqrt ratio for token1 exact input
template NextSqrtRatioFromAmount1() {
    signal input sqrt_ratio;
    signal input liquidity;
    signal input amount;
    signal input div_floor_q[4];
    signal output sqrt_ratio_next;
    signal output overflow;

    component sqrt_limbs = DecomposeU256ToLimbs();
    sqrt_limbs.value <== sqrt_ratio;
    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;
    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== amt_limbs.limbs[0];
    amt_zero.limbs[1] <== amt_limbs.limbs[1];

    // numerator = amount << 128
    signal numerator_u256[4];
    numerator_u256[0] <== 0;
    numerator_u256[1] <== 0;
    numerator_u256[2] <== amt_limbs.limbs[0];
    numerator_u256[3] <== amt_limbs.limbs[1];

    signal numerator_u512[8];
    for (var i = 0; i < 4; i++) {
        numerator_u512[i] <== numerator_u256[i];
    }
    for (var i2 = 4; i2 < 8; i2++) {
        numerator_u512[i2] <== 0;
    }

    // safe liquidity to avoid div by zero
    component liq_zero = U128IsZero();
    liq_zero.limbs[0] <== liq_limbs.limbs[0];
    liq_zero.limbs[1] <== liq_limbs.limbs[1];
    signal add_one;
    add_one <== liq_zero.out;
    signal safe_liq[4];
    safe_liq[0] <== liq_limbs.limbs[0] + add_one;
    safe_liq[1] <== liq_limbs.limbs[1];
    safe_liq[2] <== 0;
    safe_liq[3] <== 0;

    component div = U256DivFloor();
    for (var j = 0; j < 8; j++) {
        div.num[j] <== numerator_u512[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        div.den[j2] <== safe_liq[j2];
        div.q_val[j2] <== div_floor_q[j2];
    }

    component sum = U256Add();
    for (var k = 0; k < 4; k++) {
        sum.a[k] <== sqrt_limbs.limbs[k];
        sum.b[k] <== div.out[k];
    }
    overflow <== sum.carry * (1 - amt_zero.out);
    overflow * (overflow - 1) === 0;

    component out_sel = U256Select();
    out_sel.sel <== amt_zero.out;
    for (var n = 0; n < 4; n++) {
        out_sel.a[n] <== sqrt_limbs.limbs[n];
        out_sel.b[n] <== sum.out[n];
    }

    sqrt_ratio_next <== out_sel.out[0]
        + out_sel.out[1] * (1 << 64)
        + out_sel.out[2] * (1 << 128)
        + out_sel.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_ratio_next;
    for (var o = 0; o < 4; o++) {
        out.limbs[o] === out_sel.out[o];
    }
}

// next sqrt ratio for token0 exact output
template NextSqrtRatioFromAmount0ExactOut() {
    signal input sqrt_ratio;
    signal input liquidity;
    signal input amount;
    signal input div_ceil_q[4];
    signal output sqrt_ratio_next;
    signal output overflow;

    component sqrt_limbs = DecomposeU256ToLimbs();
    sqrt_limbs.value <== sqrt_ratio;
    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;
    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== amt_limbs.limbs[0];
    amt_zero.limbs[1] <== amt_limbs.limbs[1];

    // numerator1 = liquidity << 128
    signal numerator1[4];
    numerator1[0] <== 0;
    numerator1[1] <== 0;
    numerator1[2] <== liq_limbs.limbs[0];
    numerator1[3] <== liq_limbs.limbs[1];

    component prod = U256Mul();
    for (var i = 0; i < 4; i++) {
        prod.a[i] <== amt_limbs.limbs[i];
        prod.b[i] <== sqrt_limbs.limbs[i];
    }

    component high_zero = U256IsZero();
    high_zero.limbs[0] <== prod.out[4];
    high_zero.limbs[1] <== prod.out[5];
    high_zero.limbs[2] <== prod.out[6];
    high_zero.limbs[3] <== prod.out[7];
    signal overflow_mul;
    overflow_mul <== 1 - high_zero.out;
    overflow_mul * (overflow_mul - 1) === 0;

    component cmp = U256Cmp();
    for (var j = 0; j < 4; j++) {
        cmp.a[j] <== prod.out[j];
        cmp.b[j] <== numerator1[j];
    }
    signal denom_ok;
    denom_ok <== cmp.lt * (1 - overflow_mul);
    denom_ok * (denom_ok - 1) === 0;
    signal overflow_raw;
    overflow_raw <== 1 - denom_ok;
    overflow_raw * (overflow_raw - 1) === 0;

    signal safe_a[4];
    signal safe_b[4];
    component safe_sel = U256Select();
    safe_sel.sel <== denom_ok;
    for (var k = 0; k < 4; k++) {
        safe_sel.a[k] <== numerator1[k];
        safe_sel.b[k] <== prod.out[k];
        safe_b[k] <== prod.out[k];
    }
    for (var k2 = 0; k2 < 4; k2++) {
        safe_a[k2] <== safe_sel.out[k2];
    }

    component denom_sub = U256Sub();
    for (var m = 0; m < 4; m++) {
        denom_sub.a[m] <== safe_a[m];
        denom_sub.b[m] <== safe_b[m];
    }

    signal safe_den[4];
    safe_den[0] <== denom_sub.out[0] + (1 - denom_ok);
    safe_den[1] <== denom_sub.out[1];
    safe_den[2] <== denom_sub.out[2];
    safe_den[3] <== denom_sub.out[3];

    component numerator_mul = U256Mul();
    for (var n = 0; n < 4; n++) {
        numerator_mul.a[n] <== numerator1[n];
        numerator_mul.b[n] <== sqrt_limbs.limbs[n];
    }

    component div = U256DivCeil();
    for (var p = 0; p < 8; p++) {
        div.num[p] <== numerator_mul.out[p];
    }
    for (var p2 = 0; p2 < 4; p2++) {
        div.den[p2] <== safe_den[p2];
        div.q_val[p2] <== div_ceil_q[p2];
    }

    component out_sel = U256Select();
    out_sel.sel <== amt_zero.out;
    for (var q = 0; q < 4; q++) {
        out_sel.a[q] <== sqrt_limbs.limbs[q];
        out_sel.b[q] <== div.out[q];
    }

    sqrt_ratio_next <== out_sel.out[0]
        + out_sel.out[1] * (1 << 64)
        + out_sel.out[2] * (1 << 128)
        + out_sel.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_ratio_next;
    for (var r = 0; r < 4; r++) {
        out.limbs[r] === out_sel.out[r];
    }

    overflow <== overflow_raw * (1 - amt_zero.out);
    overflow * (overflow - 1) === 0;
}

// next sqrt ratio for token1 exact output
template NextSqrtRatioFromAmount1ExactOut() {
    signal input sqrt_ratio;
    signal input liquidity;
    signal input amount;
    signal input div_floor_q[4];
    signal output sqrt_ratio_next;
    signal output overflow;

    component sqrt_limbs = DecomposeU256ToLimbs();
    sqrt_limbs.value <== sqrt_ratio;
    component liq_limbs = U128ToU256Limbs();
    liq_limbs.in <== liquidity;
    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== amt_limbs.limbs[0];
    amt_zero.limbs[1] <== amt_limbs.limbs[1];

    // numerator = amount << 128
    signal numerator_u256[4];
    numerator_u256[0] <== 0;
    numerator_u256[1] <== 0;
    numerator_u256[2] <== amt_limbs.limbs[0];
    numerator_u256[3] <== amt_limbs.limbs[1];

    signal numerator_u512[8];
    for (var i = 0; i < 4; i++) {
        numerator_u512[i] <== numerator_u256[i];
    }
    for (var i2 = 4; i2 < 8; i2++) {
        numerator_u512[i2] <== 0;
    }

    component liq_zero = U128IsZero();
    liq_zero.limbs[0] <== liq_limbs.limbs[0];
    liq_zero.limbs[1] <== liq_limbs.limbs[1];
    signal add_one;
    add_one <== liq_zero.out;
    signal safe_liq[4];
    safe_liq[0] <== liq_limbs.limbs[0] + add_one;
    safe_liq[1] <== liq_limbs.limbs[1];
    safe_liq[2] <== 0;
    safe_liq[3] <== 0;

    component div = U256DivFloor();
    for (var j = 0; j < 8; j++) {
        div.num[j] <== numerator_u512[j];
    }
    for (var j2 = 0; j2 < 4; j2++) {
        div.den[j2] <== safe_liq[j2];
        div.q_val[j2] <== div_floor_q[j2];
    }

    component prod = U256Mul();
    for (var k = 0; k < 4; k++) {
        prod.a[k] <== div.out[k];
        prod.b[k] <== safe_liq[k];
    }

    component cmp_prod = U512Cmp();
    for (var k2 = 0; k2 < 8; k2++) {
        cmp_prod.a[k2] <== prod.out[k2];
        cmp_prod.b[k2] <== numerator_u512[k2];
    }
    signal remainder_nonzero;
    remainder_nonzero <== 1 - cmp_prod.eq;
    remainder_nonzero * (remainder_nonzero - 1) === 0;

    component cmp_q = U256Cmp();
    for (var m = 0; m < 4; m++) {
        cmp_q.a[m] <== sqrt_limbs.limbs[m];
        cmp_q.b[m] <== div.out[m];
    }
    signal sub_ok;
    sub_ok <== 1 - cmp_q.lt;
    sub_ok * (sub_ok - 1) === 0;

    signal safe_a[4];
    signal safe_b[4];
    component safe_sel = U256Select();
    safe_sel.sel <== sub_ok;
    for (var n = 0; n < 4; n++) {
        safe_sel.a[n] <== sqrt_limbs.limbs[n];
        safe_sel.b[n] <== div.out[n];
        safe_b[n] <== div.out[n];
    }
    for (var n2 = 0; n2 < 4; n2++) {
        safe_a[n2] <== safe_sel.out[n2];
    }

    component sub = U256Sub();
    for (var p = 0; p < 4; p++) {
        sub.a[p] <== safe_a[p];
        sub.b[p] <== safe_b[p];
    }

    component sub1 = U256SubConst1Maybe();
    sub1.enable <== remainder_nonzero;
    for (var r = 0; r < 4; r++) {
        sub1.a[r] <== sub.out[r];
    }
    signal underflow_rem;
    underflow_rem <== remainder_nonzero * sub1.borrow_out;
    underflow_rem * (underflow_rem - 1) === 0;

    signal overflow_raw;
    overflow_raw <== cmp_q.lt + underflow_rem - cmp_q.lt * underflow_rem;
    overflow_raw * (overflow_raw - 1) === 0;

    component out_sel = U256Select();
    out_sel.sel <== amt_zero.out;
    for (var s = 0; s < 4; s++) {
        out_sel.a[s] <== sqrt_limbs.limbs[s];
        out_sel.b[s] <== sub1.out[s];
    }

    sqrt_ratio_next <== out_sel.out[0]
        + out_sel.out[1] * (1 << 64)
        + out_sel.out[2] * (1 << 128)
        + out_sel.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_ratio_next;
    for (var t = 0; t < 4; t++) {
        out.limbs[t] === out_sel.out[t];
    }

    overflow <== overflow_raw * (1 - amt_zero.out);
    overflow * (overflow - 1) === 0;
}

// ekubo swap step for exact input (token determined by zero_for_one)
template ClmmStep() {
    signal input sqrt_price_start;
    signal input sqrt_price_limit;
    signal input liquidity;
    signal input amount_remaining;
    signal input fee;
    signal input zero_for_one;
    signal input amount_before_fee_div_q[4];
    signal input amount0_limit_div_q[4][4];
    signal input amount0_calc_div_q[4][4];
    signal input amount0_out_div_q[4][4];
    signal input next0_div_floor_q[4];
    signal input next0_div_ceil_q[4];
    signal input next1_div_floor_q[4];

    signal output sqrt_price_next;
    signal output amount_in;
    signal output amount_out;
    signal output fee_amount;
    signal output is_limited;
    signal output is_overflow;

    zero_for_one * (zero_for_one - 1) === 0;

    component dec_start = DecomposeU256ToLimbs();
    component dec_limit = DecomposeU256ToLimbs();
    dec_start.value <== sqrt_price_start;
    dec_limit.value <== sqrt_price_limit;

    component dec_liq = U128ToU256Limbs();
    dec_liq.in <== liquidity;
    component dec_amt = U128ToU256Limbs();
    dec_amt.in <== amount_remaining;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== dec_amt.limbs[0];
    amt_zero.limbs[1] <== dec_amt.limbs[1];

    component liq_zero = U128IsZero();
    liq_zero.limbs[0] <== dec_liq.limbs[0];
    liq_zero.limbs[1] <== dec_liq.limbs[1];

    component limit_eq = U256Eq();
    for (var i = 0; i < 4; i++) {
        limit_eq.a[i] <== dec_start.limbs[i];
        limit_eq.b[i] <== dec_limit.limbs[i];
    }

    signal early_noop;
    early_noop <== amt_zero.out + limit_eq.eq - amt_zero.out * limit_eq.eq;
    signal liquidity_noop;
    liquidity_noop <== liq_zero.out * (1 - early_noop);
    signal normal;
    normal <== 1 - early_noop - liquidity_noop;
    normal * (normal - 1) === 0;

    // direction check when active
    signal increasing;
    increasing <== 1 - zero_for_one;

    component cmp_limit = U256Cmp();
    for (var j = 0; j < 4; j++) {
        cmp_limit.a[j] <== dec_limit.limbs[j];
        cmp_limit.b[j] <== dec_start.limbs[j];
    }
    signal dir_ok;
    dir_ok <== limit_eq.eq + cmp_limit.lt + increasing * (cmp_limit.gt - cmp_limit.lt);
    dir_ok * (1 - early_noop) === (1 - early_noop);

    // fee and price impact
    signal amount_remaining_eff;
    amount_remaining_eff <== amount_remaining;
    component fee_calc = ComputeFee();
    fee_calc.amount <== amount_remaining_eff;
    fee_calc.fee <== fee;

    component fee_limbs = U128ToU256Limbs();
    fee_limbs.in <== fee_calc.fee_amount;

    component amt_limbs = U128ToU256Limbs();
    amt_limbs.in <== amount_remaining_eff;

    component amt_sub = U128Sub();
    amt_sub.a[0] <== amt_limbs.limbs[0];
    amt_sub.a[1] <== amt_limbs.limbs[1];
    amt_sub.b[0] <== fee_limbs.limbs[0];
    amt_sub.b[1] <== fee_limbs.limbs[1];

    signal price_impact_amount;
    price_impact_amount <== amt_sub.out[0] + amt_sub.out[1] * (1 << 64);
    component price_impact = U128ToU256Limbs();
    price_impact.in <== price_impact_amount;
    price_impact.limbs[0] === amt_sub.out[0];
    price_impact.limbs[1] === amt_sub.out[1];
    price_impact.limbs[2] === 0;
    price_impact.limbs[3] === 0;

    // sqrt_ratio_next_from_amount
    signal next_from_amount;
    component next0 = NextSqrtRatioFromAmount0();
    component next1 = NextSqrtRatioFromAmount1();
    next0.sqrt_ratio <== sqrt_price_start;
    next0.liquidity <== liquidity;
    next0.amount <== price_impact_amount;
    next1.sqrt_ratio <== sqrt_price_start;
    next1.liquidity <== liquidity;
    next1.amount <== price_impact_amount;
    for (var q = 0; q < 4; q++) {
        next0.div_floor_q[q] <== next0_div_floor_q[q];
        next0.div_ceil_q[q] <== next0_div_ceil_q[q];
        next1.div_floor_q[q] <== next1_div_floor_q[q];
    }
    signal overflow_raw;
    overflow_raw <== next1.overflow + zero_for_one * (next0.overflow - next1.overflow);
    overflow_raw * (overflow_raw - 1) === 0;
    signal overflow;
    overflow <== overflow_raw * normal;
    overflow * (overflow - 1) === 0;

    // select by token direction
    component next_sel = U256Select();
    next_sel.sel <== zero_for_one;
    component dec_next0 = DecomposeU256ToLimbs();
    component dec_next1 = DecomposeU256ToLimbs();
    dec_next0.value <== next0.sqrt_ratio_next;
    dec_next1.value <== next1.sqrt_ratio_next;
    for (var k = 0; k < 4; k++) {
        next_sel.a[k] <== dec_next0.limbs[k];
        next_sel.b[k] <== dec_next1.limbs[k];
    }

    next_from_amount <== next_sel.out[0]
        + next_sel.out[1] * (1 << 64)
        + next_sel.out[2] * (1 << 128)
        + next_sel.out[3] * (1 << 192);
    component next_from_amount_limbs = DecomposeU256ToLimbs();
    next_from_amount_limbs.value <== next_from_amount;
    for (var k2 = 0; k2 < 4; k2++) {
        next_from_amount_limbs.limbs[k2] === next_sel.out[k2];
    }

    component cmp_next_limit = U256Cmp();
    for (var m = 0; m < 4; m++) {
        cmp_next_limit.a[m] <== next_from_amount_limbs.limbs[m];
        cmp_next_limit.b[m] <== dec_limit.limbs[m];
    }
    signal limited_raw;
    limited_raw <== cmp_next_limit.lt + increasing * (cmp_next_limit.gt - cmp_next_limit.lt);
    signal limited_base;
    limited_base <== limited_raw * normal;
    limited_base * (limited_base - 1) === 0;
    signal limited;
    limited <== limited_base + overflow - limited_base * overflow;
    limited * (limited - 1) === 0;

    component eq_next_start = U256Eq();
    for (var n = 0; n < 4; n++) {
        eq_next_start.a[n] <== next_from_amount_limbs.limbs[n];
        eq_next_start.b[n] <== dec_start.limbs[n];
    }
    signal noop_price;
    signal noop_base;
    noop_base <== eq_next_start.eq * normal;
    noop_price <== noop_base * (1 - limited);
    noop_price * (noop_price - 1) === 0;

    // amount deltas for limited branch
    signal specified_amount_delta;
    signal calculated_amount_delta;
    component amt0_limit = Amount0Delta();
    component amt1_limit = Amount1Delta();
    amt0_limit.sqrt_ratio_a <== sqrt_price_limit;
    amt0_limit.sqrt_ratio_b <== sqrt_price_start;
    amt0_limit.liquidity <== liquidity;
    amt0_limit.round_up <== 1;
    for (var dq0 = 0; dq0 < 4; dq0++) {
        for (var dq1 = 0; dq1 < 4; dq1++) {
            amt0_limit.div_q[dq0][dq1] <== amount0_limit_div_q[dq0][dq1];
        }
    }
    amt1_limit.sqrt_ratio_a <== sqrt_price_limit;
    amt1_limit.sqrt_ratio_b <== sqrt_price_start;
    amt1_limit.liquidity <== liquidity;
    amt1_limit.round_up <== 0;

    component amt0_calc = Amount0Delta();
    component amt1_calc = Amount1Delta();
    amt0_calc.sqrt_ratio_a <== sqrt_price_limit;
    amt0_calc.sqrt_ratio_b <== sqrt_price_start;
    amt0_calc.liquidity <== liquidity;
    amt0_calc.round_up <== 0;
    for (var dq2 = 0; dq2 < 4; dq2++) {
        for (var dq3 = 0; dq3 < 4; dq3++) {
            amt0_calc.div_q[dq2][dq3] <== amount0_calc_div_q[dq2][dq3];
        }
    }
    amt1_calc.sqrt_ratio_a <== sqrt_price_limit;
    amt1_calc.sqrt_ratio_b <== sqrt_price_start;
    amt1_calc.liquidity <== liquidity;
    amt1_calc.round_up <== 1;

    // select for direction
    signal spec_amount;
    signal calc_amount;
    spec_amount <== amt1_calc.amount1 + zero_for_one * (amt0_limit.amount0 - amt1_calc.amount1);
    calc_amount <== amt0_calc.amount0 + zero_for_one * (amt1_limit.amount1 - amt0_calc.amount0);
    specified_amount_delta <== spec_amount;
    calculated_amount_delta <== calc_amount;

    // amount before fee for limited
    component before_fee = AmountBeforeFee();
    before_fee.after_fee <== specified_amount_delta;
    before_fee.fee <== fee;
    for (var dq4 = 0; dq4 < 4; dq4++) {
        before_fee.div_q[dq4] <== amount_before_fee_div_q[dq4];
    }

    // computed outputs for branches
    signal normal_amount_in;
    signal normal_amount_out;
    signal normal_fee;

    // limited branch
    signal limited_amount_in;
    limited_amount_in <== before_fee.before_fee;
    signal limited_amount_out;
    limited_amount_out <== calculated_amount_delta;
    signal limited_fee;
    limited_fee <== before_fee.before_fee - specified_amount_delta;

    // not limited branch
    signal nl_amount_out;
    component amt0_out = Amount0Delta();
    component amt1_out = Amount1Delta();
    amt0_out.sqrt_ratio_a <== next_from_amount;
    amt0_out.sqrt_ratio_b <== sqrt_price_start;
    amt0_out.liquidity <== liquidity;
    amt0_out.round_up <== 0;
    for (var dq5 = 0; dq5 < 4; dq5++) {
        for (var dq6 = 0; dq6 < 4; dq6++) {
            amt0_out.div_q[dq5][dq6] <== amount0_out_div_q[dq5][dq6];
        }
    }
    amt1_out.sqrt_ratio_a <== next_from_amount;
    amt1_out.sqrt_ratio_b <== sqrt_price_start;
    amt1_out.liquidity <== liquidity;
    amt1_out.round_up <== 0;
    nl_amount_out <== amt0_out.amount0 + zero_for_one * (amt1_out.amount1 - amt0_out.amount0);

    signal nl_fee;
    nl_fee <== fee_calc.fee_amount;

    // select normal outputs
    normal_amount_in <== amount_remaining + limited * (limited_amount_in - amount_remaining);
    signal nl_amount_out_eff;
    nl_amount_out_eff <== nl_amount_out * (1 - noop_price);
    normal_amount_out <== nl_amount_out_eff + limited * (limited_amount_out - nl_amount_out_eff);
    signal nl_fee_noop;
    nl_fee_noop <== nl_fee * (1 - noop_price);
    signal noop_fee;
    noop_fee <== amount_remaining * noop_price;
    signal nl_fee_total;
    nl_fee_total <== nl_fee_noop + noop_fee;
    normal_fee <== nl_fee_total + limited * (limited_fee - nl_fee_total);

    // select sqrt_price_next
    component next_sel2 = U256Select();
    next_sel2.sel <== limited;
    for (var p = 0; p < 4; p++) {
        next_sel2.a[p] <== dec_limit.limbs[p];
        next_sel2.b[p] <== next_from_amount_limbs.limbs[p];
    }

    component final_sel = U256Select();
    final_sel.sel <== early_noop;
    for (var p2 = 0; p2 < 4; p2++) {
        final_sel.a[p2] <== dec_start.limbs[p2];
        final_sel.b[p2] <== next_sel2.out[p2];
    }

    component final_sel2 = U256Select();
    final_sel2.sel <== liquidity_noop;
    for (var p3 = 0; p3 < 4; p3++) {
        final_sel2.a[p3] <== dec_limit.limbs[p3];
        final_sel2.b[p3] <== final_sel.out[p3];
    }

    sqrt_price_next <== final_sel2.out[0]
        + final_sel2.out[1] * (1 << 64)
        + final_sel2.out[2] * (1 << 128)
        + final_sel2.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_price_next;
    for (var q = 0; q < 4; q++) {
        out.limbs[q] === final_sel2.out[q];
    }

    signal amount_in_calc;
    signal amount_out_calc;
    signal fee_calc_out;
    amount_in_calc <== normal * normal_amount_in;
    amount_out_calc <== normal * normal_amount_out;
    fee_calc_out <== normal * normal_fee;

    amount_in <== amount_in_calc;
    component calc_in = U128ToU256Limbs();
    calc_in.in <== amount_in_calc;
    component out_in = U128ToU256Limbs();
    out_in.in <== amount_in;
    out_in.limbs[0] === calc_in.limbs[0];
    out_in.limbs[1] === calc_in.limbs[1];
    out_in.limbs[2] === 0;
    out_in.limbs[3] === 0;

    amount_out <== amount_out_calc;
    component calc_out = U128ToU256Limbs();
    calc_out.in <== amount_out_calc;
    component out_out = U128ToU256Limbs();
    out_out.in <== amount_out;
    out_out.limbs[0] === calc_out.limbs[0];
    out_out.limbs[1] === calc_out.limbs[1];
    out_out.limbs[2] === 0;
    out_out.limbs[3] === 0;

    fee_amount <== fee_calc_out;
    component calc_fee = U128ToU256Limbs();
    calc_fee.in <== fee_calc_out;
    component out_fee = U128ToU256Limbs();
    out_fee.in <== fee_amount;
    out_fee.limbs[0] === calc_fee.limbs[0];
    out_fee.limbs[1] === calc_fee.limbs[1];
    out_fee.limbs[2] === 0;
    out_fee.limbs[3] === 0;

    overflow === 0;
    is_limited <== limited;
    is_overflow <== overflow;
}

// ekubo swap step for exact output (token determined by zero_for_one)
template ClmmStepExactOut() {
    signal input sqrt_price_start;
    signal input sqrt_price_limit;
    signal input liquidity;
    signal input amount_remaining;
    signal input fee;
    signal input zero_for_one;
    signal input amount_before_fee_div_q[4];
    signal input amount0_limit_div_q[4][4];
    signal input amount0_calc_div_q[4][4];
    signal input amount0_out_div_q[4][4];
    signal input next0_div_ceil_q[4];
    signal input next1_div_floor_q[4];

    signal output sqrt_price_next;
    signal output amount_in;
    signal output amount_out;
    signal output fee_amount;
    signal output is_limited;
    signal output is_overflow;

    zero_for_one * (zero_for_one - 1) === 0;

    component dec_start = DecomposeU256ToLimbs();
    component dec_limit = DecomposeU256ToLimbs();
    dec_start.value <== sqrt_price_start;
    dec_limit.value <== sqrt_price_limit;

    component dec_liq = U128ToU256Limbs();
    dec_liq.in <== liquidity;
    component dec_amt = U128ToU256Limbs();
    dec_amt.in <== amount_remaining;

    component amt_zero = U128IsZero();
    amt_zero.limbs[0] <== dec_amt.limbs[0];
    amt_zero.limbs[1] <== dec_amt.limbs[1];

    component liq_zero = U128IsZero();
    liq_zero.limbs[0] <== dec_liq.limbs[0];
    liq_zero.limbs[1] <== dec_liq.limbs[1];

    component limit_eq = U256Eq();
    for (var i = 0; i < 4; i++) {
        limit_eq.a[i] <== dec_start.limbs[i];
        limit_eq.b[i] <== dec_limit.limbs[i];
    }

    signal early_noop;
    early_noop <== amt_zero.out + limit_eq.eq - amt_zero.out * limit_eq.eq;
    signal liquidity_noop;
    liquidity_noop <== liq_zero.out * (1 - early_noop);
    signal normal;
    normal <== 1 - early_noop - liquidity_noop;
    normal * (normal - 1) === 0;

    // direction check when active
    signal increasing;
    increasing <== 1 - zero_for_one;

    component cmp_limit = U256Cmp();
    for (var j = 0; j < 4; j++) {
        cmp_limit.a[j] <== dec_limit.limbs[j];
        cmp_limit.b[j] <== dec_start.limbs[j];
    }
    signal dir_ok;
    dir_ok <== limit_eq.eq + cmp_limit.lt + increasing * (cmp_limit.gt - cmp_limit.lt);
    dir_ok * (1 - early_noop) === (1 - early_noop);

    // sqrt_ratio_next_from_amount (exact output)
    signal next_from_amount;
    component next0 = NextSqrtRatioFromAmount0ExactOut();
    component next1 = NextSqrtRatioFromAmount1ExactOut();
    next0.sqrt_ratio <== sqrt_price_start;
    next0.liquidity <== liquidity;
    next0.amount <== amount_remaining;
    next1.sqrt_ratio <== sqrt_price_start;
    next1.liquidity <== liquidity;
    next1.amount <== amount_remaining;
    for (var q = 0; q < 4; q++) {
        next0.div_ceil_q[q] <== next0_div_ceil_q[q];
        next1.div_floor_q[q] <== next1_div_floor_q[q];
    }
    signal overflow_raw;
    overflow_raw <== next1.overflow + zero_for_one * (next0.overflow - next1.overflow);
    overflow_raw * (overflow_raw - 1) === 0;
    signal overflow;
    overflow <== overflow_raw * normal;
    overflow * (overflow - 1) === 0;

    // select by token direction
    component next_sel = U256Select();
    next_sel.sel <== zero_for_one;
    component dec_next0 = DecomposeU256ToLimbs();
    component dec_next1 = DecomposeU256ToLimbs();
    dec_next0.value <== next0.sqrt_ratio_next;
    dec_next1.value <== next1.sqrt_ratio_next;
    for (var k = 0; k < 4; k++) {
        next_sel.a[k] <== dec_next0.limbs[k];
        next_sel.b[k] <== dec_next1.limbs[k];
    }

    next_from_amount <== next_sel.out[0]
        + next_sel.out[1] * (1 << 64)
        + next_sel.out[2] * (1 << 128)
        + next_sel.out[3] * (1 << 192);
    component next_from_amount_limbs = DecomposeU256ToLimbs();
    next_from_amount_limbs.value <== next_from_amount;
    for (var k2 = 0; k2 < 4; k2++) {
        next_from_amount_limbs.limbs[k2] === next_sel.out[k2];
    }

    component cmp_next_limit = U256Cmp();
    for (var m = 0; m < 4; m++) {
        cmp_next_limit.a[m] <== next_from_amount_limbs.limbs[m];
        cmp_next_limit.b[m] <== dec_limit.limbs[m];
    }
    signal limited_raw;
    limited_raw <== cmp_next_limit.lt + increasing * (cmp_next_limit.gt - cmp_next_limit.lt);
    signal limited_base;
    limited_base <== limited_raw * normal;
    limited_base * (limited_base - 1) === 0;
    signal limited;
    limited <== limited_base + overflow - limited_base * overflow;
    limited * (limited - 1) === 0;

    component eq_next_start = U256Eq();
    for (var n = 0; n < 4; n++) {
        eq_next_start.a[n] <== next_from_amount_limbs.limbs[n];
        eq_next_start.b[n] <== dec_start.limbs[n];
    }
    signal noop_price;
    signal noop_base;
    noop_base <== eq_next_start.eq * normal;
    noop_price <== noop_base * (1 - limited);
    noop_price * (noop_price - 1) === 0;
    noop_price === 0;

    // amount deltas for limited branch
    signal specified_amount_delta;
    signal calculated_amount_delta;
    component amt0_limit = Amount0Delta();
    component amt1_limit = Amount1Delta();
    amt0_limit.sqrt_ratio_a <== sqrt_price_limit;
    amt0_limit.sqrt_ratio_b <== sqrt_price_start;
    amt0_limit.liquidity <== liquidity;
    amt0_limit.round_up <== 0;
    for (var dq0 = 0; dq0 < 4; dq0++) {
        for (var dq1 = 0; dq1 < 4; dq1++) {
            amt0_limit.div_q[dq0][dq1] <== amount0_calc_div_q[dq0][dq1];
        }
    }
    amt1_limit.sqrt_ratio_a <== sqrt_price_limit;
    amt1_limit.sqrt_ratio_b <== sqrt_price_start;
    amt1_limit.liquidity <== liquidity;
    amt1_limit.round_up <== 0;

    component amt0_calc = Amount0Delta();
    component amt1_calc = Amount1Delta();
    amt0_calc.sqrt_ratio_a <== sqrt_price_limit;
    amt0_calc.sqrt_ratio_b <== sqrt_price_start;
    amt0_calc.liquidity <== liquidity;
    amt0_calc.round_up <== 1;
    for (var dq2 = 0; dq2 < 4; dq2++) {
        for (var dq3 = 0; dq3 < 4; dq3++) {
            amt0_calc.div_q[dq2][dq3] <== amount0_limit_div_q[dq2][dq3];
        }
    }
    amt1_calc.sqrt_ratio_a <== sqrt_price_limit;
    amt1_calc.sqrt_ratio_b <== sqrt_price_start;
    amt1_calc.liquidity <== liquidity;
    amt1_calc.round_up <== 1;

    signal spec_amount;
    signal calc_amount;
    spec_amount <== amt1_limit.amount1 + (1 - zero_for_one) * (amt0_limit.amount0 - amt1_limit.amount1);
    calc_amount <== amt0_calc.amount0 + (1 - zero_for_one) * (amt1_calc.amount1 - amt0_calc.amount0);
    specified_amount_delta <== spec_amount;
    calculated_amount_delta <== calc_amount;

    // non-limited input amount (without fee)
    component amt0_in = Amount0Delta();
    component amt1_in = Amount1Delta();
    amt0_in.sqrt_ratio_a <== next_from_amount;
    amt0_in.sqrt_ratio_b <== sqrt_price_start;
    amt0_in.liquidity <== liquidity;
    amt0_in.round_up <== 1;
    for (var dq4 = 0; dq4 < 4; dq4++) {
        for (var dq5 = 0; dq5 < 4; dq5++) {
            amt0_in.div_q[dq4][dq5] <== amount0_out_div_q[dq4][dq5];
        }
    }
    amt1_in.sqrt_ratio_a <== next_from_amount;
    amt1_in.sqrt_ratio_b <== sqrt_price_start;
    amt1_in.liquidity <== liquidity;
    amt1_in.round_up <== 1;
    signal nl_amount_in_wo_fee;
    nl_amount_in_wo_fee <== amt0_in.amount0 + (1 - zero_for_one) * (amt1_in.amount1 - amt0_in.amount0);

    signal calc_amount_for_fee;
    calc_amount_for_fee <== nl_amount_in_wo_fee + limited * (calculated_amount_delta - nl_amount_in_wo_fee);

    component before_fee = AmountBeforeFee();
    before_fee.after_fee <== calc_amount_for_fee;
    before_fee.fee <== fee;
    for (var dq6 = 0; dq6 < 4; dq6++) {
        before_fee.div_q[dq6] <== amount_before_fee_div_q[dq6];
    }

    component fee_sub = U128Sub();
    component calc_fee_limbs = U128ToU256Limbs();
    component before_fee_limbs = U128ToU256Limbs();
    calc_fee_limbs.in <== calc_amount_for_fee;
    before_fee_limbs.in <== before_fee.before_fee;
    fee_sub.a[0] <== before_fee_limbs.limbs[0];
    fee_sub.a[1] <== before_fee_limbs.limbs[1];
    fee_sub.b[0] <== calc_fee_limbs.limbs[0];
    fee_sub.b[1] <== calc_fee_limbs.limbs[1];
    signal normal_fee;
    normal_fee <== fee_sub.out[0] + fee_sub.out[1] * (1 << 64);

    // computed outputs for branches
    signal normal_amount_in;
    signal normal_amount_out;
    normal_amount_in <== before_fee.before_fee;
    normal_amount_out <== amount_remaining + limited * (specified_amount_delta - amount_remaining);

    // select sqrt_price_next
    component next_sel2 = U256Select();
    next_sel2.sel <== limited;
    for (var p = 0; p < 4; p++) {
        next_sel2.a[p] <== dec_limit.limbs[p];
        next_sel2.b[p] <== next_from_amount_limbs.limbs[p];
    }

    component final_sel = U256Select();
    final_sel.sel <== early_noop;
    for (var p2 = 0; p2 < 4; p2++) {
        final_sel.a[p2] <== dec_start.limbs[p2];
        final_sel.b[p2] <== next_sel2.out[p2];
    }

    component final_sel2 = U256Select();
    final_sel2.sel <== liquidity_noop;
    for (var p3 = 0; p3 < 4; p3++) {
        final_sel2.a[p3] <== dec_limit.limbs[p3];
        final_sel2.b[p3] <== final_sel.out[p3];
    }

    sqrt_price_next <== final_sel2.out[0]
        + final_sel2.out[1] * (1 << 64)
        + final_sel2.out[2] * (1 << 128)
        + final_sel2.out[3] * (1 << 192);
    component out = DecomposeU256ToLimbs();
    out.value <== sqrt_price_next;
    for (var q = 0; q < 4; q++) {
        out.limbs[q] === final_sel2.out[q];
    }

    signal amount_in_calc;
    signal amount_out_calc;
    signal fee_calc_out;
    amount_in_calc <== normal * normal_amount_in;
    amount_out_calc <== normal * normal_amount_out;
    fee_calc_out <== normal * normal_fee;

    amount_in <== amount_in_calc;
    component calc_in = U128ToU256Limbs();
    calc_in.in <== amount_in_calc;
    component out_in = U128ToU256Limbs();
    out_in.in <== amount_in;
    out_in.limbs[0] === calc_in.limbs[0];
    out_in.limbs[1] === calc_in.limbs[1];
    out_in.limbs[2] === 0;
    out_in.limbs[3] === 0;

    amount_out <== amount_out_calc;
    component calc_out = U128ToU256Limbs();
    calc_out.in <== amount_out_calc;
    component out_out = U128ToU256Limbs();
    out_out.in <== amount_out;
    out_out.limbs[0] === calc_out.limbs[0];
    out_out.limbs[1] === calc_out.limbs[1];
    out_out.limbs[2] === 0;
    out_out.limbs[3] === 0;

    fee_amount <== fee_calc_out;
    component calc_fee = U128ToU256Limbs();
    calc_fee.in <== fee_calc_out;
    component out_fee = U128ToU256Limbs();
    out_fee.in <== fee_amount;
    out_fee.limbs[0] === calc_fee.limbs[0];
    out_fee.limbs[1] === calc_fee.limbs[1];
    out_fee.limbs[2] === 0;
    out_fee.limbs[3] === 0;

    overflow === 0;
    is_limited <== limited;
    is_overflow <== overflow;
}
