// private liquidity circuit - proves note ownership, liquidity math, and fee growth accounting
pragma circom 2.2.3;

include "./clmm_step.circom";
include "./note_commitments.circom";

// decode signed i128 with 128-bit two's complement encoding (sign-extended to u256)
template DecodeSignedI128() {
    signal input value;
    signal output sign;
    signal output mag;

    component dec = DecomposeU256ToLimbs();
    dec.value <== value;

    // low limbs as u128
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

    // enforce sign-extension in high limbs
    signal high_expected;
    high_expected <== sign * 0xffffffffffffffff;
    dec.limbs[2] === high_expected;
    dec.limbs[3] === high_expected;

    // mag = (2^128 - low_u128) for negative, else low_u128
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

// decode signed i128 stored in low 128 bits (high limbs zero)
template DecodeSignedI128NoSignExt() {
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

template I32RangeCheck() {
    signal input value;

    component dec = DecodeSignedI128NoSignExt();
    dec.value <== value;

    component mag_bits = Num2Bits(32);
    mag_bits.in <== dec.mag;

    signal top_bit;
    top_bit <== mag_bits.out[31];
    (1 - dec.sign) * top_bit === 0;

    var sum = 0;
    for (var i = 0; i < 31; i++) {
        sum += mag_bits.out[i];
    }
    signal lower_sum;
    lower_sum <== sum;
    signal sign_top;
    sign_top <== dec.sign * top_bit;
    sign_top * lower_sum === 0;
}

template PrivateLiquidity() {
    var VK_LIQ_ADD = 0x4c49515f414444; // "LIQ_ADD"
    var VK_LIQ_REMOVE = 0x4c49515f52454d4f5645; // "LIQ_REMOVE"
    var VK_LIQ_CLAIM = 0x4c49515f434c41494d; // "LIQ_CLAIM"
    var MAX_NOTES = MAX_INPUT_NOTES();

    // inputs: aggregate pool state only, per-note amounts remain private
    signal input tag;
    signal input merkle_root_token0;
    signal input merkle_root_token1;
    signal input merkle_root_position;
    signal input nullifier_position;
    signal input sqrt_price_start;
    signal input tick_start;
    signal input tick_lower;
    signal input tick_upper;
    signal input sqrt_ratio_lower;
    signal input sqrt_ratio_upper;
    signal input liquidity_before;
    signal input liquidity_delta;
    signal input fee;
    signal input fee_growth_global_0_before;
    signal input fee_growth_global_1_before;
    signal input fee_growth_global_0;
    signal input fee_growth_global_1;
    signal input prev_position_commitment;
    signal input new_position_commitment;
    signal input liquidity_commitment;
    signal input fee_growth_inside_0_before;
    signal input fee_growth_inside_1_before;
    signal input fee_growth_inside_0_after;
    signal input fee_growth_inside_1_after;
    signal input input_commitment_token0;
    signal input input_commitment_token1;
    signal input nullifier_token0;
    signal input nullifier_token1;
    signal input output_commitment_token0;
    signal input output_commitment_token1;
    signal input protocol_fee_0;
    signal input protocol_fee_1;
    signal input token0_note_count;
    signal input token1_note_count;
    signal input nullifier_token0_extra[MAX_NOTES - 1];
    signal input nullifier_token1_extra[MAX_NOTES - 1];
    signal input input_commitment_token0_extra[MAX_NOTES - 1];
    signal input input_commitment_token1_extra[MAX_NOTES - 1];

    // private inputs
    signal input token0_note_amount[MAX_NOTES]; // u128
    signal input token0_note_secret[MAX_NOTES];
    signal input token0_note_nullifier_seed[MAX_NOTES];
    signal input token1_note_amount[MAX_NOTES]; // u128
    signal input token1_note_secret[MAX_NOTES];
    signal input token1_note_nullifier_seed[MAX_NOTES];
    signal input position_liquidity; // u128
    signal input position_secret_in;
    signal input position_nullifier_seed_in;
    signal input position_secret_out;
    signal input position_nullifier_seed_out;
    signal input out_token0_secret;
    signal input out_token0_nullifier_seed;
    signal input out_token1_secret;
    signal input out_token1_nullifier_seed;
    signal input tick_spacing;
    signal input amount0_below_div_q[4][4];
    signal input amount0_inside_div_q[4][4];
    signal input tick_lower_inv_div_q[4];
    signal input tick_upper_inv_div_q[4];

    signal _bind_tag;
    _bind_tag <== tag * tag;
    signal _bind_merkle_root_token0;
    _bind_merkle_root_token0 <== merkle_root_token0 * merkle_root_token0;
    signal _bind_merkle_root_token1;
    _bind_merkle_root_token1 <== merkle_root_token1 * merkle_root_token1;
    signal _bind_merkle_root_position;
    _bind_merkle_root_position <== merkle_root_position * merkle_root_position;
    signal _bind_nullifier_position;
    _bind_nullifier_position <== nullifier_position * nullifier_position;
    signal _bind_sqrt_price_start;
    _bind_sqrt_price_start <== sqrt_price_start * sqrt_price_start;
    signal _bind_tick_start;
    _bind_tick_start <== tick_start * tick_start;
    signal _bind_tick_lower;
    _bind_tick_lower <== tick_lower * tick_lower;
    signal _bind_tick_upper;
    _bind_tick_upper <== tick_upper * tick_upper;
    signal _bind_sqrt_ratio_lower;
    _bind_sqrt_ratio_lower <== sqrt_ratio_lower * sqrt_ratio_lower;
    signal _bind_sqrt_ratio_upper;
    _bind_sqrt_ratio_upper <== sqrt_ratio_upper * sqrt_ratio_upper;
    signal _bind_liquidity_before;
    _bind_liquidity_before <== liquidity_before * liquidity_before;
    signal _bind_liquidity_delta;
    _bind_liquidity_delta <== liquidity_delta * liquidity_delta;
    signal _bind_fee;
    _bind_fee <== fee * fee;
    signal _bind_fee_growth_global_0_before;
    _bind_fee_growth_global_0_before <== fee_growth_global_0_before * fee_growth_global_0_before;
    signal _bind_fee_growth_global_1_before;
    _bind_fee_growth_global_1_before <== fee_growth_global_1_before * fee_growth_global_1_before;
    signal _bind_fee_growth_global_0;
    _bind_fee_growth_global_0 <== fee_growth_global_0 * fee_growth_global_0;
    signal _bind_fee_growth_global_1;
    _bind_fee_growth_global_1 <== fee_growth_global_1 * fee_growth_global_1;
    signal _bind_prev_position_commitment;
    _bind_prev_position_commitment <== prev_position_commitment * prev_position_commitment;
    signal _bind_new_position_commitment;
    _bind_new_position_commitment <== new_position_commitment * new_position_commitment;
    signal _bind_liquidity_commitment;
    _bind_liquidity_commitment <== liquidity_commitment * liquidity_commitment;
    signal _bind_fee_growth_inside_0_before;
    _bind_fee_growth_inside_0_before <== fee_growth_inside_0_before * fee_growth_inside_0_before;
    signal _bind_fee_growth_inside_1_before;
    _bind_fee_growth_inside_1_before <== fee_growth_inside_1_before * fee_growth_inside_1_before;
    signal _bind_fee_growth_inside_0_after;
    _bind_fee_growth_inside_0_after <== fee_growth_inside_0_after * fee_growth_inside_0_after;
    signal _bind_fee_growth_inside_1_after;
    _bind_fee_growth_inside_1_after <== fee_growth_inside_1_after * fee_growth_inside_1_after;
    signal _bind_input_commitment_token0;
    _bind_input_commitment_token0 <== input_commitment_token0 * input_commitment_token0;
    signal _bind_input_commitment_token1;
    _bind_input_commitment_token1 <== input_commitment_token1 * input_commitment_token1;
    signal _bind_nullifier_token0;
    _bind_nullifier_token0 <== nullifier_token0 * nullifier_token0;
    signal _bind_nullifier_token1;
    _bind_nullifier_token1 <== nullifier_token1 * nullifier_token1;
    signal _bind_output_commitment_token0;
    _bind_output_commitment_token0 <== output_commitment_token0 * output_commitment_token0;
    signal _bind_output_commitment_token1;
    _bind_output_commitment_token1 <== output_commitment_token1 * output_commitment_token1;
    signal _bind_protocol_fee_0;
    _bind_protocol_fee_0 <== protocol_fee_0 * protocol_fee_0;
    signal _bind_protocol_fee_1;
    _bind_protocol_fee_1 <== protocol_fee_1 * protocol_fee_1;
    signal _bind_token0_note_count;
    _bind_token0_note_count <== token0_note_count * token0_note_count;
    signal _bind_token1_note_count;
    _bind_token1_note_count <== token1_note_count * token1_note_count;
    signal _bind_nullifier_token0_extra[MAX_NOTES - 1];
    signal _bind_nullifier_token1_extra[MAX_NOTES - 1];
    signal _bind_input_commitment_token0_extra[MAX_NOTES - 1];
    signal _bind_input_commitment_token1_extra[MAX_NOTES - 1];
    for (var bi = 0; bi < MAX_NOTES - 1; bi++) {
        _bind_nullifier_token0_extra[bi] <== nullifier_token0_extra[bi] * nullifier_token0_extra[bi];
        _bind_nullifier_token1_extra[bi] <== nullifier_token1_extra[bi] * nullifier_token1_extra[bi];
        _bind_input_commitment_token0_extra[bi] <== input_commitment_token0_extra[bi] * input_commitment_token0_extra[bi];
        _bind_input_commitment_token1_extra[bi] <== input_commitment_token1_extra[bi] * input_commitment_token1_extra[bi];
    }

    // tag check
    component is_add = IsEqual();
    is_add.in[0] <== tag;
    is_add.in[1] <== VK_LIQ_ADD;
    component is_remove = IsEqual();
    is_remove.in[0] <== tag;
    is_remove.in[1] <== VK_LIQ_REMOVE;
    component is_claim = IsEqual();
    is_claim.in[0] <== tag;
    is_claim.in[1] <== VK_LIQ_CLAIM;
    is_add.out + is_remove.out + is_claim.out === 1;

    component spacing_check = TickSpacingCheck();
    spacing_check.tick_spacing <== tick_spacing;

    // tick_start may be min_tick - 1 after crossing the minimum price boundary
    component tick_start_check = TickRangeCheckAllowMinMinusOne();
    tick_start_check.tick <== tick_start;

    component tick_lower_check = TickRangeCheck();
    tick_lower_check.tick <== tick_lower;
    component tick_upper_check = TickRangeCheck();
    tick_upper_check.tick <== tick_upper;

    component tick_lower_align = TickAlignmentCheck();
    tick_lower_align.mag <== tick_lower_check.mag;
    tick_lower_align.tick_spacing <== tick_spacing;
    component tick_upper_align = TickAlignmentCheck();
    tick_upper_align.mag <== tick_upper_check.mag;
    tick_upper_align.tick_spacing <== tick_spacing;

    component tick_lower_mag_lt = LessThan(128);
    tick_lower_mag_lt.in[0] <== tick_lower_check.mag;
    tick_lower_mag_lt.in[1] <== tick_upper_check.mag;
    component tick_upper_mag_lt = LessThan(128);
    tick_upper_mag_lt.in[0] <== tick_upper_check.mag;
    tick_upper_mag_lt.in[1] <== tick_lower_check.mag;

    signal sign_diff;
    sign_diff <== tick_lower_check.sign + tick_upper_check.sign
        - 2 * tick_lower_check.sign * tick_upper_check.sign;
    sign_diff * (sign_diff - 1) === 0;

    signal both_pos;
    both_pos <== (1 - tick_lower_check.sign) * (1 - tick_upper_check.sign);
    both_pos * (both_pos - 1) === 0;
    signal both_neg;
    both_neg <== tick_lower_check.sign * tick_upper_check.sign;
    both_neg * (both_neg - 1) === 0;

    signal tick_lower_lt_upper;
    signal both_sel;
    both_sel <== tick_upper_mag_lt.out + both_pos * (tick_lower_mag_lt.out - tick_upper_mag_lt.out);
    tick_lower_lt_upper <== both_sel + sign_diff * (tick_lower_check.sign - both_sel);
    tick_lower_lt_upper === 1;

    // range checks for u128 quantities
    component dec_liq_before = DecomposeU256ToLimbs();
    dec_liq_before.value <== liquidity_before;
    component rc_liq_before = U128RangeCheck();
    for (var i = 0; i < 4; i++) rc_liq_before.limbs[i] <== dec_liq_before.limbs[i];

    component rc_fee = U128ToU256Limbs();
    rc_fee.in <== fee;
    component note0_count_bits = Num2Bits(8);
    note0_count_bits.in <== token0_note_count;
    component note1_count_bits = Num2Bits(8);
    note1_count_bits.in <== token1_note_count;
    component note0_count_lt = LessThan(8);
    note0_count_lt.in[0] <== token0_note_count;
    note0_count_lt.in[1] <== MAX_NOTES + 1;
    note0_count_lt.out === 1;
    component note1_count_lt = LessThan(8);
    note1_count_lt.in[0] <== token1_note_count;
    note1_count_lt.in[1] <== MAX_NOTES + 1;
    note1_count_lt.out === 1;
    component note0_count_zero = IsEqual();
    note0_count_zero.in[0] <== token0_note_count;
    note0_count_zero.in[1] <== 0;
    component note1_count_zero = IsEqual();
    note1_count_zero.in[0] <== token1_note_count;
    note1_count_zero.in[1] <== 0;
    signal remove_or_claim;
    remove_or_claim <== is_remove.out + is_claim.out;
    remove_or_claim * (remove_or_claim - 1) === 0;
    remove_or_claim * (1 - note0_count_zero.out) === 0;
    remove_or_claim * (1 - note1_count_zero.out) === 0;
    signal add_both_zero;
    add_both_zero <== note0_count_zero.out * note1_count_zero.out;
    is_add.out * add_both_zero === 0;

    signal note0_active[MAX_NOTES];
    component note0_active_lt[MAX_NOTES];
    signal note1_active[MAX_NOTES];
    component note1_active_lt[MAX_NOTES];
    for (var n = 0; n < MAX_NOTES; n++) {
        note0_active_lt[n] = LessThan(8);
        note0_active_lt[n].in[0] <== n;
        note0_active_lt[n].in[1] <== token0_note_count;
        note0_active[n] <== note0_active_lt[n].out;
        note0_active[n] * (note0_active[n] - 1) === 0;

        note1_active_lt[n] = LessThan(8);
        note1_active_lt[n].in[0] <== n;
        note1_active_lt[n].in[1] <== token1_note_count;
        note1_active[n] <== note1_active_lt[n].out;
        note1_active[n] * (note1_active[n] - 1) === 0;
    }

    component rc_note0[MAX_NOTES];
    component rc_note1[MAX_NOTES];
    for (var rn = 0; rn < MAX_NOTES; rn++) {
        rc_note0[rn] = Num2Bits(128);
        rc_note0[rn].in <== token0_note_amount[rn];
        rc_note1[rn] = Num2Bits(128);
        rc_note1[rn].in <== token1_note_amount[rn];
    }
    component rc_pos_liq = Num2Bits(128);
    rc_pos_liq.in <== position_liquidity;

    component rc_root0 = StarkFieldRangeCheck();
    rc_root0.value <== merkle_root_token0;
    component rc_root1 = StarkFieldRangeCheck();
    rc_root1.value <== merkle_root_token1;
    component rc_root_pos = StarkFieldRangeCheck();
    rc_root_pos.value <== merkle_root_position;

    // fee growth values must be < Stark field
    component rc_fg0_before = StarkFieldRangeCheck();
    rc_fg0_before.value <== fee_growth_global_0_before;
    component rc_fg1_before = StarkFieldRangeCheck();
    rc_fg1_before.value <== fee_growth_global_1_before;
    component rc_fg0_after = StarkFieldRangeCheck();
    rc_fg0_after.value <== fee_growth_global_0;
    component rc_fg1_after = StarkFieldRangeCheck();
    rc_fg1_after.value <== fee_growth_global_1;
    component rc_fi0_before = StarkFieldRangeCheck();
    rc_fi0_before.value <== fee_growth_inside_0_before;
    component rc_fi1_before = StarkFieldRangeCheck();
    rc_fi1_before.value <== fee_growth_inside_1_before;
    component rc_fi0_after = StarkFieldRangeCheck();
    rc_fi0_after.value <== fee_growth_inside_0_after;
    component rc_fi1_after = StarkFieldRangeCheck();
    rc_fi1_after.value <== fee_growth_inside_1_after;
    component max_fee_limbs = DecomposeU256ToLimbs();
    max_fee_limbs.value <== MAX_FEE_GROWTH();

    // signed i128 decoding for liquidity_delta (two's complement, sign-extended)
    component liq_dec = DecodeSignedI256ToU128();
    liq_dec.value <== liquidity_delta;
    is_add.out * liq_dec.sign === 0;
    is_remove.out * (1 - liq_dec.sign) === 0;
    is_claim.out * liq_dec.sign === 0;
    component liq_mag_zero = IsEqual();
    liq_mag_zero.in[0] <== liq_dec.mag;
    liq_mag_zero.in[1] <== 0;
    is_claim.out * (1 - liq_mag_zero.out) === 0;
    signal round_up;
    round_up <== 1 - liq_dec.sign;
    round_up * (round_up - 1) === 0;

    is_add.out * liq_mag_zero.out === 0;

    component tick_start_range = I32RangeCheck();
    tick_start_range.value <== tick_start;
    component tick_lower_range = I32RangeCheck();
    tick_lower_range.value <== tick_lower;
    component tick_upper_range = I32RangeCheck();
    tick_upper_range.value <== tick_upper;

    // sqrt ratio bounds check (lower < upper)
    component dec_lower = DecomposeU256ToLimbs();
    component dec_upper = DecomposeU256ToLimbs();
    dec_lower.value <== sqrt_ratio_lower;
    dec_upper.value <== sqrt_ratio_upper;
    // bind sqrt ratios to tick values
    component sqrt_lower_calc = TickToSqrtRatio();
    sqrt_lower_calc.tick <== tick_lower;
    for (var sr0 = 0; sr0 < 4; sr0++) {
        sqrt_lower_calc.inv_div_q[sr0] <== tick_lower_inv_div_q[sr0];
    }
    component sqrt_upper_calc = TickToSqrtRatio();
    sqrt_upper_calc.tick <== tick_upper;
    for (var sr1 = 0; sr1 < 4; sr1++) {
        sqrt_upper_calc.inv_div_q[sr1] <== tick_upper_inv_div_q[sr1];
    }
    component sqrt_lower_limbs = DecomposeU256ToLimbs();
    sqrt_lower_limbs.value <== sqrt_lower_calc.sqrt_ratio;
    component sqrt_upper_limbs = DecomposeU256ToLimbs();
    sqrt_upper_limbs.value <== sqrt_upper_calc.sqrt_ratio;
    for (var sr2 = 0; sr2 < 4; sr2++) {
        sqrt_lower_limbs.limbs[sr2] === dec_lower.limbs[sr2];
        sqrt_upper_limbs.limbs[sr2] === dec_upper.limbs[sr2];
    }
    component cmp_bounds = U256Cmp();
    for (var i2 = 0; i2 < 4; i2++) {
        cmp_bounds.a[i2] <== dec_lower.limbs[i2];
        cmp_bounds.b[i2] <== dec_upper.limbs[i2];
    }
    cmp_bounds.lt === 1;

    // liquidity delta amounts
    component dec_price = DecomposeU256ToLimbs();
    dec_price.value <== sqrt_price_start;
    component cmp_lower = U256Cmp();
    component cmp_upper = U256Cmp();
    for (var p = 0; p < 4; p++) {
        cmp_lower.a[p] <== dec_price.limbs[p];
        cmp_lower.b[p] <== dec_lower.limbs[p];
        cmp_upper.a[p] <== dec_price.limbs[p];
        cmp_upper.b[p] <== dec_upper.limbs[p];
    }

    signal price_le_lower;
    price_le_lower <== cmp_lower.lt + cmp_lower.eq;
    price_le_lower * (price_le_lower - 1) === 0;
    signal price_lt_upper;
    price_lt_upper <== cmp_upper.lt;
    price_lt_upper * (price_lt_upper - 1) === 0;
    signal inside;
    inside <== (1 - price_le_lower) * price_lt_upper;
    inside * (inside - 1) === 0;
    signal above;
    above <== 1 - price_le_lower - inside;
    above * (above - 1) === 0;

    component amt0_below = Amount0Delta();
    amt0_below.sqrt_ratio_a <== sqrt_ratio_lower;
    amt0_below.sqrt_ratio_b <== sqrt_ratio_upper;
    amt0_below.liquidity <== liq_dec.mag;
    amt0_below.round_up <== round_up;
    for (var dq0 = 0; dq0 < 4; dq0++) {
        for (var dq1 = 0; dq1 < 4; dq1++) {
            amt0_below.div_q[dq0][dq1] <== amount0_below_div_q[dq0][dq1];
        }
    }

    component amt0_inside = Amount0Delta();
    amt0_inside.sqrt_ratio_a <== sqrt_price_start;
    amt0_inside.sqrt_ratio_b <== sqrt_ratio_upper;
    amt0_inside.liquidity <== liq_dec.mag;
    amt0_inside.round_up <== round_up;
    for (var dq2 = 0; dq2 < 4; dq2++) {
        for (var dq3 = 0; dq3 < 4; dq3++) {
            amt0_inside.div_q[dq2][dq3] <== amount0_inside_div_q[dq2][dq3];
        }
    }

    component amt1_inside = Amount1Delta();
    amt1_inside.sqrt_ratio_a <== sqrt_ratio_lower;
    amt1_inside.sqrt_ratio_b <== sqrt_price_start;
    amt1_inside.liquidity <== liq_dec.mag;
    amt1_inside.round_up <== round_up;

    component amt1_above = Amount1Delta();
    amt1_above.sqrt_ratio_a <== sqrt_ratio_lower;
    amt1_above.sqrt_ratio_b <== sqrt_ratio_upper;
    amt1_above.liquidity <== liq_dec.mag;
    amt1_above.round_up <== round_up;

    signal amount0;
    signal amount0_below_eff;
    signal amount0_inside_eff;
    amount0_below_eff <== price_le_lower * amt0_below.amount0;
    amount0_inside_eff <== inside * amt0_inside.amount0;
    amount0 <== amount0_below_eff + amount0_inside_eff;
    signal amount1;
    signal amount1_inside_eff;
    signal amount1_above_eff;
    amount1_inside_eff <== inside * amt1_inside.amount1;
    amount1_above_eff <== above * amt1_above.amount1;
    amount1 <== amount1_inside_eff + amount1_above_eff;

    // input token notes (used for add only)
    component input_note0[MAX_NOTES];
    component input_note1[MAX_NOTES];
    signal note0_nullifier[MAX_NOTES];
    signal note1_nullifier[MAX_NOTES];
    signal note0_commitment[MAX_NOTES];
    signal note1_commitment[MAX_NOTES];
    signal note0_amount_eff[MAX_NOTES];
    signal note1_amount_eff[MAX_NOTES];
    component note0_amount_limbs[MAX_NOTES];
    component note1_amount_limbs[MAX_NOTES];
    component note0_sum_add[MAX_NOTES];
    component note1_sum_add[MAX_NOTES];
    signal note0_sum_limbs[MAX_NOTES + 1][2];
    signal note1_sum_limbs[MAX_NOTES + 1][2];
    signal note0_commitment_eff[MAX_NOTES];
    signal note1_commitment_eff[MAX_NOTES];
    signal note0_nullifier_eff[MAX_NOTES];
    signal note1_nullifier_eff[MAX_NOTES];
    note0_sum_limbs[0][0] <== 0;
    note0_sum_limbs[0][1] <== 0;
    note1_sum_limbs[0][0] <== 0;
    note1_sum_limbs[0][1] <== 0;
    for (var n0 = 0; n0 < MAX_NOTES; n0++) {
        input_note0[n0] = TokenNote();
        input_note0[n0].token_id <== 0;
        input_note0[n0].amount <== token0_note_amount[n0];
        input_note0[n0].secret <== token0_note_secret[n0];
        input_note0[n0].nullifier_seed <== token0_note_nullifier_seed[n0];
        note0_nullifier[n0] <== input_note0[n0].nullifier;
        note0_commitment[n0] <== input_note0[n0].commitment;

        input_note1[n0] = TokenNote();
        input_note1[n0].token_id <== 1;
        input_note1[n0].amount <== token1_note_amount[n0];
        input_note1[n0].secret <== token1_note_secret[n0];
        input_note1[n0].nullifier_seed <== token1_note_nullifier_seed[n0];
        note1_nullifier[n0] <== input_note1[n0].nullifier;
        note1_commitment[n0] <== input_note1[n0].commitment;

        note0_amount_eff[n0] <== token0_note_amount[n0] * note0_active[n0];
        note1_amount_eff[n0] <== token1_note_amount[n0] * note1_active[n0];
        note0_commitment_eff[n0] <== note0_commitment[n0] * note0_active[n0];
        note1_commitment_eff[n0] <== note1_commitment[n0] * note1_active[n0];
        note0_nullifier_eff[n0] <== note0_nullifier[n0] * note0_active[n0];
        note1_nullifier_eff[n0] <== note1_nullifier[n0] * note1_active[n0];
        note0_amount_limbs[n0] = U128ToU256Limbs();
        note0_amount_limbs[n0].in <== note0_amount_eff[n0];
        note1_amount_limbs[n0] = U128ToU256Limbs();
        note1_amount_limbs[n0].in <== note1_amount_eff[n0];

        note0_sum_add[n0] = U128Add();
        note0_sum_add[n0].a[0] <== note0_sum_limbs[n0][0];
        note0_sum_add[n0].a[1] <== note0_sum_limbs[n0][1];
        note0_sum_add[n0].b[0] <== note0_amount_limbs[n0].limbs[0];
        note0_sum_add[n0].b[1] <== note0_amount_limbs[n0].limbs[1];
        note0_sum_add[n0].carry === 0;
        note0_sum_limbs[n0 + 1][0] <== note0_sum_add[n0].out[0];
        note0_sum_limbs[n0 + 1][1] <== note0_sum_add[n0].out[1];

        note1_sum_add[n0] = U128Add();
        note1_sum_add[n0].a[0] <== note1_sum_limbs[n0][0];
        note1_sum_add[n0].a[1] <== note1_sum_limbs[n0][1];
        note1_sum_add[n0].b[0] <== note1_amount_limbs[n0].limbs[0];
        note1_sum_add[n0].b[1] <== note1_amount_limbs[n0].limbs[1];
        note1_sum_add[n0].carry === 0;
        note1_sum_limbs[n0 + 1][0] <== note1_sum_add[n0].out[0];
        note1_sum_limbs[n0 + 1][1] <== note1_sum_add[n0].out[1];

        if (n0 == 0) {
            input_commitment_token0 === is_add.out * note0_commitment_eff[n0];
            input_commitment_token1 === is_add.out * note1_commitment_eff[n0];
            nullifier_token0 === is_add.out * note0_nullifier_eff[n0];
            nullifier_token1 === is_add.out * note1_nullifier_eff[n0];
        } else {
            input_commitment_token0_extra[n0 - 1] === is_add.out * note0_commitment_eff[n0];
            input_commitment_token1_extra[n0 - 1] === is_add.out * note1_commitment_eff[n0];
            nullifier_token0_extra[n0 - 1] === is_add.out * note0_nullifier_eff[n0];
            nullifier_token1_extra[n0 - 1] === is_add.out * note1_nullifier_eff[n0];
        }
    }

    signal token0_note_total;
    signal token1_note_total;
    token0_note_total <== note0_sum_limbs[MAX_NOTES][0]
        + note0_sum_limbs[MAX_NOTES][1] * (1 << 64);
    token1_note_total <== note1_sum_limbs[MAX_NOTES][0]
        + note1_sum_limbs[MAX_NOTES][1] * (1 << 64);

    component nullifier_eq0[MAX_NOTES][MAX_NOTES];
    signal nullifier_both0[MAX_NOTES][MAX_NOTES];
    component nullifier_eq1[MAX_NOTES][MAX_NOTES];
    signal nullifier_both1[MAX_NOTES][MAX_NOTES];
    component nullifier_eq01[MAX_NOTES][MAX_NOTES];
    signal nullifier_both01[MAX_NOTES][MAX_NOTES];
    for (var ni = 0; ni < MAX_NOTES; ni++) {
        for (var nj = ni + 1; nj < MAX_NOTES; nj++) {
            nullifier_eq0[ni][nj] = IsEqual();
            nullifier_eq0[ni][nj].in[0] <== note0_nullifier[ni];
            nullifier_eq0[ni][nj].in[1] <== note0_nullifier[nj];
            nullifier_both0[ni][nj] <== note0_active[ni] * note0_active[nj];
            nullifier_both0[ni][nj] * nullifier_eq0[ni][nj].out === 0;

            nullifier_eq1[ni][nj] = IsEqual();
            nullifier_eq1[ni][nj].in[0] <== note1_nullifier[ni];
            nullifier_eq1[ni][nj].in[1] <== note1_nullifier[nj];
            nullifier_both1[ni][nj] <== note1_active[ni] * note1_active[nj];
            nullifier_both1[ni][nj] * nullifier_eq1[ni][nj].out === 0;
        }
    }
    for (var ni2 = 0; ni2 < MAX_NOTES; ni2++) {
        for (var nj2 = 0; nj2 < MAX_NOTES; nj2++) {
            nullifier_eq01[ni2][nj2] = IsEqual();
            nullifier_eq01[ni2][nj2].in[0] <== note0_nullifier[ni2];
            nullifier_eq01[ni2][nj2].in[1] <== note1_nullifier[nj2];
            nullifier_both01[ni2][nj2] <== note0_active[ni2] * note1_active[nj2];
            nullifier_both01[ni2][nj2] * nullifier_eq01[ni2][nj2].out === 0;
        }
    }

    // input position note (used for remove or update)
    component input_position_note = PositionNote();
    input_position_note.token_id <== 2;
    input_position_note.tick_lower <== tick_lower;
    input_position_note.tick_upper <== tick_upper;
    input_position_note.liquidity <== position_liquidity;
    input_position_note.fee_growth_inside_0 <== fee_growth_inside_0_before;
    input_position_note.fee_growth_inside_1 <== fee_growth_inside_1_before;
    input_position_note.secret <== position_secret_in;
    input_position_note.nullifier_seed <== position_nullifier_seed_in;

    component prev_pos_zero = IsEqual();
    prev_pos_zero.in[0] <== prev_position_commitment;
    prev_pos_zero.in[1] <== 0;
    signal has_prev_position;
    has_prev_position <== 1 - prev_pos_zero.out;
    has_prev_position * (has_prev_position - 1) === 0;
    remove_or_claim * (1 - has_prev_position) === 0;

    prev_position_commitment === has_prev_position * input_position_note.commitment;
    nullifier_position === has_prev_position * input_position_note.nullifier;

    // for add-new, position_liquidity must equal liquidity_delta magnitude
    signal add_new;
    add_new <== is_add.out * (1 - has_prev_position);
    add_new * (add_new - 1) === 0;
    signal liq_mag_diff;
    liq_mag_diff <== position_liquidity - liq_dec.mag;
    add_new * liq_mag_diff === 0;

    component pos_liq_limbs = U128ToU256Limbs();
    pos_liq_limbs.in <== position_liquidity;
    component liq_mag_limbs = U128ToU256Limbs();
    liq_mag_limbs.in <== liq_dec.mag;

    // remaining liquidity for remove (gated to avoid add underflow)
    signal sub_a0;
    signal sub_a1;
    sub_a0 <== liq_mag_limbs.limbs[0]
        + is_remove.out * (pos_liq_limbs.limbs[0] - liq_mag_limbs.limbs[0]);
    sub_a1 <== liq_mag_limbs.limbs[1]
        + is_remove.out * (pos_liq_limbs.limbs[1] - liq_mag_limbs.limbs[1]);
    component liq_sub = U128Sub();
    liq_sub.a[0] <== sub_a0;
    liq_sub.a[1] <== sub_a1;
    liq_sub.b[0] <== liq_mag_limbs.limbs[0];
    liq_sub.b[1] <== liq_mag_limbs.limbs[1];
    signal remaining_liquidity;
    remaining_liquidity <== liq_sub.out[0] + liq_sub.out[1] * (1 << 64);

    component liq_add = U128Add();
    liq_add.a[0] <== pos_liq_limbs.limbs[0];
    liq_add.a[1] <== pos_liq_limbs.limbs[1];
    liq_add.b[0] <== liq_mag_limbs.limbs[0];
    liq_add.b[1] <== liq_mag_limbs.limbs[1];
    liq_add.carry === 0;
    signal added_liquidity;
    added_liquidity <== liq_add.out[0] + liq_add.out[1] * (1 << 64);

    signal add_with_prev;
    add_with_prev <== is_add.out * has_prev_position;
    add_with_prev * (add_with_prev - 1) === 0;
    signal new_liq_add_prev;
    new_liq_add_prev <== add_with_prev * added_liquidity;
    signal new_liq_add_new;
    new_liq_add_new <== add_new * position_liquidity;
    signal new_liq_remove;
    new_liq_remove <== is_remove.out * remaining_liquidity;

    signal new_liq_claim;
    new_liq_claim <== is_claim.out * position_liquidity;
    signal new_position_liquidity;
    new_position_liquidity <== new_liq_add_prev + new_liq_add_new + new_liq_remove + new_liq_claim;

    // fee growth monotonicity and add-position initialization
    component fee0_before = DecomposeU256ToLimbs();
    component fee0_after = DecomposeU256ToLimbs();
    fee0_before.value <== fee_growth_inside_0_before;
    fee0_after.value <== fee_growth_inside_0_after;
    component cmp_fee0_max_before = U256Cmp();
    component cmp_fee0_max_after = U256Cmp();
    for (var m0 = 0; m0 < 4; m0++) {
        cmp_fee0_max_before.a[m0] <== fee0_before.limbs[m0];
        cmp_fee0_max_before.b[m0] <== max_fee_limbs.limbs[m0];
        cmp_fee0_max_after.a[m0] <== fee0_after.limbs[m0];
        cmp_fee0_max_after.b[m0] <== max_fee_limbs.limbs[m0];
    }
    cmp_fee0_max_before.lt + cmp_fee0_max_before.eq === 1;
    cmp_fee0_max_after.lt + cmp_fee0_max_after.eq === 1;
    component diff0 = U256Sub();
    for (var d0 = 0; d0 < 4; d0++) {
        diff0.a[d0] <== fee0_after.limbs[d0];
        diff0.b[d0] <== fee0_before.limbs[d0];
    }
    component diff0_zero = U256IsZero();
    for (var dz0 = 0; dz0 < 4; dz0++) {
        diff0_zero.limbs[dz0] <== diff0.out[dz0];
    }
    add_new * (1 - diff0_zero.out) === 0;
    component cmp_fee0_inside = U256Cmp();
    for (var ci0 = 0; ci0 < 4; ci0++) {
        cmp_fee0_inside.a[ci0] <== fee0_before.limbs[ci0];
        cmp_fee0_inside.b[ci0] <== fee0_after.limbs[ci0];
    }
    cmp_fee0_inside.lt + cmp_fee0_inside.eq === 1;

    component fee1_before = DecomposeU256ToLimbs();
    component fee1_after = DecomposeU256ToLimbs();
    fee1_before.value <== fee_growth_inside_1_before;
    fee1_after.value <== fee_growth_inside_1_after;
    component cmp_fee1_max_before = U256Cmp();
    component cmp_fee1_max_after = U256Cmp();
    for (var m1 = 0; m1 < 4; m1++) {
        cmp_fee1_max_before.a[m1] <== fee1_before.limbs[m1];
        cmp_fee1_max_before.b[m1] <== max_fee_limbs.limbs[m1];
        cmp_fee1_max_after.a[m1] <== fee1_after.limbs[m1];
        cmp_fee1_max_after.b[m1] <== max_fee_limbs.limbs[m1];
    }
    cmp_fee1_max_before.lt + cmp_fee1_max_before.eq === 1;
    cmp_fee1_max_after.lt + cmp_fee1_max_after.eq === 1;
    component diff1 = U256Sub();
    for (var d1 = 0; d1 < 4; d1++) {
        diff1.a[d1] <== fee1_after.limbs[d1];
        diff1.b[d1] <== fee1_before.limbs[d1];
    }
    component diff1_zero = U256IsZero();
    for (var dz1 = 0; dz1 < 4; dz1++) {
        diff1_zero.limbs[dz1] <== diff1.out[dz1];
    }
    add_new * (1 - diff1_zero.out) === 0;
    component cmp_fee1_inside = U256Cmp();
    for (var ci1 = 0; ci1 < 4; ci1++) {
        cmp_fee1_inside.a[ci1] <== fee1_before.limbs[ci1];
        cmp_fee1_inside.b[ci1] <== fee1_after.limbs[ci1];
    }
    cmp_fee1_inside.lt + cmp_fee1_inside.eq === 1;

    // fee growth global monotonicity
    component fg0_before = DecomposeU256ToLimbs();
    component fg0_after = DecomposeU256ToLimbs();
    fg0_before.value <== fee_growth_global_0_before;
    fg0_after.value <== fee_growth_global_0;
    component fg1_before = DecomposeU256ToLimbs();
    component fg1_after = DecomposeU256ToLimbs();
    fg1_before.value <== fee_growth_global_1_before;
    fg1_after.value <== fee_growth_global_1;
    component cmp_fg0_max_before = U256Cmp();
    component cmp_fg0_max_after = U256Cmp();
    component cmp_fg1_max_before = U256Cmp();
    component cmp_fg1_max_after = U256Cmp();
    for (var g = 0; g < 4; g++) {
        cmp_fg0_max_before.a[g] <== fg0_before.limbs[g];
        cmp_fg0_max_before.b[g] <== max_fee_limbs.limbs[g];
        cmp_fg0_max_after.a[g] <== fg0_after.limbs[g];
        cmp_fg0_max_after.b[g] <== max_fee_limbs.limbs[g];
        cmp_fg1_max_before.a[g] <== fg1_before.limbs[g];
        cmp_fg1_max_before.b[g] <== max_fee_limbs.limbs[g];
        cmp_fg1_max_after.a[g] <== fg1_after.limbs[g];
        cmp_fg1_max_after.b[g] <== max_fee_limbs.limbs[g];
    }
    cmp_fg0_max_before.lt + cmp_fg0_max_before.eq === 1;
    cmp_fg0_max_after.lt + cmp_fg0_max_after.eq === 1;
    cmp_fg1_max_before.lt + cmp_fg1_max_before.eq === 1;
    cmp_fg1_max_after.lt + cmp_fg1_max_after.eq === 1;

    component cmp_fee0 = U256Cmp();
    component cmp_fee1 = U256Cmp();
    for (var i3 = 0; i3 < 4; i3++) {
        cmp_fee0.a[i3] <== fg0_before.limbs[i3];
        cmp_fee0.b[i3] <== fg0_after.limbs[i3];
        cmp_fee1.a[i3] <== fg1_before.limbs[i3];
        cmp_fee1.b[i3] <== fg1_after.limbs[i3];
    }
    cmp_fee0.lt + cmp_fee0.eq === 1;
    cmp_fee1.lt + cmp_fee1.eq === 1;

    component diff_fg0 = U256Sub();
    component diff_fg1 = U256Sub();
    for (var df = 0; df < 4; df++) {
        diff_fg0.a[df] <== fg0_after.limbs[df];
        diff_fg0.b[df] <== fg0_before.limbs[df];
        diff_fg1.a[df] <== fg1_after.limbs[df];
        diff_fg1.b[df] <== fg1_before.limbs[df];
    }
    component diff_fg0_zero = U256IsZero();
    component diff_fg1_zero = U256IsZero();
    for (var dz = 0; dz < 4; dz++) {
        diff_fg0_zero.limbs[dz] <== diff_fg0.out[dz];
        diff_fg1_zero.limbs[dz] <== diff_fg1.out[dz];
    }
    diff_fg0_zero.out === 1;
    diff_fg1_zero.out === 1;

    // fee amounts for remove (full 512-bit product shifted right by 128; take low 128 bits)
    component fee0_mul = U256Mul();
    component fee1_mul = U256Mul();
    for (var m = 0; m < 4; m++) {
        fee0_mul.a[m] <== diff0.out[m];
        fee0_mul.b[m] <== pos_liq_limbs.limbs[m];
        fee1_mul.a[m] <== diff1.out[m];
        fee1_mul.b[m] <== pos_liq_limbs.limbs[m];
    }
    component fee0_shift = U512ShiftRight128();
    component fee1_shift = U512ShiftRight128();
    for (var ms = 0; ms < 8; ms++) {
        fee0_shift.in[ms] <== fee0_mul.out[ms];
        fee1_shift.in[ms] <== fee1_mul.out[ms];
    }
    signal fee_amount0;
    fee_amount0 <== fee0_shift.out[0] + fee0_shift.out[1] * (1 << 64);
    signal fee_amount1;
    fee_amount1 <== fee1_shift.out[0] + fee1_shift.out[1] * (1 << 64);

    signal fee_amount0_eff;
    signal fee_amount1_eff;
    fee_amount0_eff <== remove_or_claim * fee_amount0;
    fee_amount1_eff <== remove_or_claim * fee_amount1;

    signal amount0_remove_eff;
    signal amount1_remove_eff;
    amount0_remove_eff <== is_remove.out * amount0;
    amount1_remove_eff <== is_remove.out * amount1;

    // protocol fees are charged on liquidity burns
    component prot_fee0 = ComputeFee();
    component prot_fee1 = ComputeFee();
    prot_fee0.amount <== amount0_remove_eff;
    prot_fee0.fee <== fee;
    prot_fee1.amount <== amount1_remove_eff;
    prot_fee1.fee <== fee;
    signal prot_fee0_eff;
    signal prot_fee1_eff;
    prot_fee0_eff <== prot_fee0.fee_amount;
    prot_fee1_eff <== prot_fee1.fee_amount;
    protocol_fee_0 === prot_fee0_eff;
    protocol_fee_1 === prot_fee1_eff;

    component amt0_eff_limbs = U128ToU256Limbs();
    amt0_eff_limbs.in <== amount0_remove_eff;
    component prot0_eff_limbs = U128ToU256Limbs();
    prot0_eff_limbs.in <== prot_fee0_eff;
    component amount0_net_sub = U128Sub();
    amount0_net_sub.a[0] <== amt0_eff_limbs.limbs[0];
    amount0_net_sub.a[1] <== amt0_eff_limbs.limbs[1];
    amount0_net_sub.b[0] <== prot0_eff_limbs.limbs[0];
    amount0_net_sub.b[1] <== prot0_eff_limbs.limbs[1];
    signal amount0_net_remove;
    amount0_net_remove <== amount0_net_sub.out[0] + amount0_net_sub.out[1] * (1 << 64);

    component amt1_eff_limbs = U128ToU256Limbs();
    amt1_eff_limbs.in <== amount1_remove_eff;
    component prot1_eff_limbs = U128ToU256Limbs();
    prot1_eff_limbs.in <== prot_fee1_eff;
    component amount1_net_sub = U128Sub();
    amount1_net_sub.a[0] <== amt1_eff_limbs.limbs[0];
    amount1_net_sub.a[1] <== amt1_eff_limbs.limbs[1];
    amount1_net_sub.b[0] <== prot1_eff_limbs.limbs[0];
    amount1_net_sub.b[1] <== prot1_eff_limbs.limbs[1];
    signal amount1_net_remove;
    amount1_net_remove <== amount1_net_sub.out[0] + amount1_net_sub.out[1] * (1 << 64);

    component fee0_eff_limbs = U128ToU256Limbs();
    fee0_eff_limbs.in <== fee_amount0_eff;
    component out0_add = U128Add();
    out0_add.a[0] <== amount0_net_sub.out[0];
    out0_add.a[1] <== amount0_net_sub.out[1];
    out0_add.b[0] <== fee0_eff_limbs.limbs[0];
    out0_add.b[1] <== fee0_eff_limbs.limbs[1];
    out0_add.carry === 0;
    signal out_amount0_remove;
    out_amount0_remove <== out0_add.out[0] + out0_add.out[1] * (1 << 64);

    component fee1_eff_limbs = U128ToU256Limbs();
    fee1_eff_limbs.in <== fee_amount1_eff;
    component out1_add = U128Add();
    out1_add.a[0] <== amount1_net_sub.out[0];
    out1_add.a[1] <== amount1_net_sub.out[1];
    out1_add.b[0] <== fee1_eff_limbs.limbs[0];
    out1_add.b[1] <== fee1_eff_limbs.limbs[1];
    out1_add.carry === 0;
    signal out_amount1_remove;
    out_amount1_remove <== out1_add.out[0] + out1_add.out[1] * (1 << 64);

    // add path change (token notes supply required amounts)
    signal note0_eff;
    signal note1_eff;
    signal amount0_eff;
    signal amount1_eff;
    note0_eff <== is_add.out * token0_note_total;
    note1_eff <== is_add.out * token1_note_total;
    amount0_eff <== is_add.out * amount0;
    amount1_eff <== is_add.out * amount1;

    component note0_limbs = U128ToU256Limbs();
    note0_limbs.in <== note0_eff;
    component amount0_limbs = U128ToU256Limbs();
    amount0_limbs.in <== amount0_eff;
    component change0_sub = U128Sub();
    change0_sub.a[0] <== note0_limbs.limbs[0];
    change0_sub.a[1] <== note0_limbs.limbs[1];
    change0_sub.b[0] <== amount0_limbs.limbs[0];
    change0_sub.b[1] <== amount0_limbs.limbs[1];
    signal out_amount0_add;
    out_amount0_add <== change0_sub.out[0] + change0_sub.out[1] * (1 << 64);

    component note1_limbs = U128ToU256Limbs();
    note1_limbs.in <== note1_eff;
    component amount1_limbs = U128ToU256Limbs();
    amount1_limbs.in <== amount1_eff;
    component change1_sub = U128Sub();
    change1_sub.a[0] <== note1_limbs.limbs[0];
    change1_sub.a[1] <== note1_limbs.limbs[1];
    change1_sub.b[0] <== amount1_limbs.limbs[0];
    change1_sub.b[1] <== amount1_limbs.limbs[1];
    signal out_amount1_add;
    out_amount1_add <== change1_sub.out[0] + change1_sub.out[1] * (1 << 64);

    signal out_amount0;
    signal out_amount1;
    out_amount0 <== out_amount0_add + out_amount0_remove;
    out_amount1 <== out_amount1_add + out_amount1_remove;

    // output notes
    component out_amount0_limbs = U128ToU256Limbs();
    out_amount0_limbs.in <== out_amount0;
    component out_amount1_limbs = U128ToU256Limbs();
    out_amount1_limbs.in <== out_amount1;
    component out0_zero = U128IsZero();
    out0_zero.limbs[0] <== out_amount0_limbs.limbs[0];
    out0_zero.limbs[1] <== out_amount0_limbs.limbs[1];
    component out1_zero = U128IsZero();
    out1_zero.limbs[0] <== out_amount1_limbs.limbs[0];
    out1_zero.limbs[1] <== out_amount1_limbs.limbs[1];
    signal has_out0;
    signal has_out1;
    has_out0 <== 1 - out0_zero.out;
    has_out1 <== 1 - out1_zero.out;
    has_out0 * (has_out0 - 1) === 0;
    has_out1 * (has_out1 - 1) === 0;

    component out_note0 = TokenNote();
    out_note0.token_id <== 0;
    out_note0.amount <== out_amount0;
    out_note0.secret <== out_token0_secret;
    out_note0.nullifier_seed <== out_token0_nullifier_seed;
    output_commitment_token0 === has_out0 * out_note0.commitment;

    component out_note1 = TokenNote();
    out_note1.token_id <== 1;
    out_note1.amount <== out_amount1;
    out_note1.secret <== out_token1_secret;
    out_note1.nullifier_seed <== out_token1_nullifier_seed;
    output_commitment_token1 === has_out1 * out_note1.commitment;

    // output position note
    component out_position_note = PositionNote();
    out_position_note.token_id <== 2;
    out_position_note.tick_lower <== tick_lower;
    out_position_note.tick_upper <== tick_upper;
    out_position_note.liquidity <== new_position_liquidity;
    out_position_note.fee_growth_inside_0 <== fee_growth_inside_0_after;
    out_position_note.fee_growth_inside_1 <== fee_growth_inside_1_after;
    out_position_note.secret <== position_secret_out;
    out_position_note.nullifier_seed <== position_nullifier_seed_out;

    component new_liq_limbs = U128ToU256Limbs();
    new_liq_limbs.in <== new_position_liquidity;
    component new_liq_zero = U128IsZero();
    new_liq_zero.limbs[0] <== new_liq_limbs.limbs[0];
    new_liq_zero.limbs[1] <== new_liq_limbs.limbs[1];
    signal has_new_position;
    has_new_position <== 1 - new_liq_zero.out;
    has_new_position * (has_new_position - 1) === 0;
    new_position_commitment === has_new_position * out_position_note.commitment;

    liquidity_commitment === prev_position_commitment + is_add.out * (new_position_commitment - prev_position_commitment);
}

component main { public [
    tag,
    merkle_root_token0,
    merkle_root_token1,
    merkle_root_position,
    nullifier_position,
    sqrt_price_start,
    tick_start,
    tick_lower,
    tick_upper,
    sqrt_ratio_lower,
    sqrt_ratio_upper,
    liquidity_before,
    liquidity_delta,
    fee,
    fee_growth_global_0_before,
    fee_growth_global_1_before,
    fee_growth_global_0,
    fee_growth_global_1,
    prev_position_commitment,
    new_position_commitment,
    liquidity_commitment,
    fee_growth_inside_0_before,
    fee_growth_inside_1_before,
    fee_growth_inside_0_after,
    fee_growth_inside_1_after,
    input_commitment_token0,
    input_commitment_token1,
    nullifier_token0,
    nullifier_token1,
    output_commitment_token0,
    output_commitment_token1,
    protocol_fee_0,
    protocol_fee_1,
    token0_note_count,
    token1_note_count,
    nullifier_token0_extra,
    nullifier_token1_extra,
    input_commitment_token0_extra,
    input_commitment_token1_extra
] } = PrivateLiquidity();
