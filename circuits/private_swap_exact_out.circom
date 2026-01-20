pragma circom 2.2.3;

// private swap circuit - proves ekubo swap math for bounded multi-step swaps, hashes and tick data are enforced on-chain
// exact-output swaps are supported in this version

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

    component mag_out = U128ToU256Limbs();
    mag_out.in <== mag;
    mag_out.limbs[2] === 0;
    mag_out.limbs[3] === 0;
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

template PrivateSwapExactOut() {
    // this implementation currently supports up to 16 initialized-tick crossings per swap proof. swaps exceeding this must be chunked or use future recursive proofs.
    var MAX_STEPS = MAX_SWAP_STEPS();
    var MAX_NOTES = MAX_INPUT_NOTES();
    var VK_SWAP_EXACT_OUT = 0x535741505f45584143545f4f5554; // "SWAP_EXACT_OUT"
    var DOMAIN_TAG = 0x5a594c495448; // "ZYLITH"
    var NOTE_TYPE_TOKEN = 1;

    // public inputs
    signal input tag;
    signal input merkle_root;
    signal input nullifier;
    signal input sqrt_price_start;
    signal input sqrt_price_end_public;
    signal input liquidity_before;
    signal input fee;
    signal input fee_growth_global_0_before;
    signal input fee_growth_global_1_before;
    signal input output_commitment;
    signal input change_commitment;
    signal input is_limited;
    signal input zero_for_one;
    signal input step_sqrt_price_next[MAX_STEPS];
    signal input step_sqrt_price_limit[MAX_STEPS];
    signal input step_tick_next[MAX_STEPS];
    signal input step_liquidity_net[MAX_STEPS];
    signal input step_fee_growth_global_0[MAX_STEPS];
    signal input step_fee_growth_global_1[MAX_STEPS];
    signal input commitment_in;
    signal input token_id_in;
    signal input note_count;
    signal input nullifier_extra[MAX_NOTES - 1];
    signal input commitment_extra[MAX_NOTES - 1];

    // private inputs
    signal input step_amount_in[MAX_STEPS];  // u128
    signal input step_amount_out[MAX_STEPS]; // u128
    signal input step_amount_before_fee_div_q[MAX_STEPS][4];
    signal input step_amount0_limit_div_q[MAX_STEPS][4][4];
    signal input step_amount0_calc_div_q[MAX_STEPS][4][4];
    signal input step_amount0_out_div_q[MAX_STEPS][4][4];
    signal input step_next0_div_ceil_q[MAX_STEPS][4];
    signal input step_next1_div_floor_q[MAX_STEPS][4];
    signal input step_fee_div_q[MAX_STEPS][4];
    signal input note_amount_in[MAX_NOTES]; // u128
    signal input secret_in[MAX_NOTES];
    signal input nullifier_seed_in[MAX_NOTES];
    signal input secret_out;
    signal input nullifier_seed_out;
    signal input change_secret;
    signal input change_nullifier_seed;
    signal input tick_spacing;

    signal amount_in_consumed;
    signal amount_out;

    // tag check
    tag === VK_SWAP_EXACT_OUT;

    component spacing_check = TickSpacingCheck();
    spacing_check.tick_spacing <== tick_spacing;

    component step_tick_checks[MAX_STEPS];
    component step_tick_align[MAX_STEPS];
    for (var t = 0; t < MAX_STEPS; t++) {
        step_tick_checks[t] = TickRangeCheck();
        step_tick_checks[t].tick <== step_tick_next[t];
        step_tick_align[t] = TickAlignmentCheck();
        step_tick_align[t].mag <== step_tick_checks[t].mag;
        step_tick_align[t].tick_spacing <== tick_spacing;
    }

    // zero_for_one boolean
    zero_for_one * (zero_for_one - 1) === 0;
    // token_id_in must be 0 or 1 and match direction
    token_id_in * (token_id_in - 1) === 0;
    zero_for_one * token_id_in === 0;
    (1 - zero_for_one) * (token_id_in - 1) === 0;

    // range checks for u128 public quantities
    component rc_liq_before = U128ToU256Limbs();
    rc_liq_before.in <== liquidity_before;
    component rc_fee = U128ToU256Limbs();
    rc_fee.in <== fee;

    component rc_root = StarkFieldRangeCheck();
    rc_root.value <== merkle_root;

    // fee growth values must be < Stark field
    component rc_fee_growth_0_before = StarkFieldRangeCheck();
    rc_fee_growth_0_before.value <== fee_growth_global_0_before;
    component rc_fee_growth_1_before = StarkFieldRangeCheck();
    rc_fee_growth_1_before.value <== fee_growth_global_1_before;
    component fee0_before_limbs = DecomposeU256ToLimbs();
    component fee1_before_limbs = DecomposeU256ToLimbs();
    fee0_before_limbs.value <== fee_growth_global_0_before;
    fee1_before_limbs.value <== fee_growth_global_1_before;
    component max_fee_limbs = DecomposeU256ToLimbs();
    max_fee_limbs.value <== MAX_FEE_GROWTH();
    component cmp_fee0_max_before = U256Cmp();
    component cmp_fee1_max_before = U256Cmp();
    for (var fg0 = 0; fg0 < 4; fg0++) {
        cmp_fee0_max_before.a[fg0] <== fee0_before_limbs.limbs[fg0];
        cmp_fee0_max_before.b[fg0] <== max_fee_limbs.limbs[fg0];
        cmp_fee1_max_before.a[fg0] <== fee1_before_limbs.limbs[fg0];
        cmp_fee1_max_before.b[fg0] <== max_fee_limbs.limbs[fg0];
    }
    cmp_fee0_max_before.lt + cmp_fee0_max_before.eq === 1;
    cmp_fee1_max_before.lt + cmp_fee1_max_before.eq === 1;
    component rc_fee_growth_0_steps[MAX_STEPS];
    component rc_fee_growth_1_steps[MAX_STEPS];
    for (var fg = 0; fg < MAX_STEPS; fg++) {
        rc_fee_growth_0_steps[fg] = StarkFieldRangeCheck();
        rc_fee_growth_0_steps[fg].value <== step_fee_growth_global_0[fg];
        rc_fee_growth_1_steps[fg] = StarkFieldRangeCheck();
        rc_fee_growth_1_steps[fg].value <== step_fee_growth_global_1[fg];
    }

    component note_count_bits = Num2Bits(8);
    note_count_bits.in <== note_count;
    component note_count_zero = IsEqual();
    note_count_zero.in[0] <== note_count;
    note_count_zero.in[1] <== 0;
    note_count_zero.out === 0;
    component note_count_lt = LessThan(8);
    note_count_lt.in[0] <== note_count;
    note_count_lt.in[1] <== MAX_NOTES + 1;
    note_count_lt.out === 1;

    signal note_active[MAX_NOTES];
    component note_active_lt[MAX_NOTES];
    for (var n = 0; n < MAX_NOTES; n++) {
        note_active_lt[n] = LessThan(8);
        note_active_lt[n].in[0] <== n;
        note_active_lt[n].in[1] <== note_count;
        note_active[n] <== note_active_lt[n].out;
        note_active[n] * (note_active[n] - 1) === 0;
    }

    component rc_note_amt[MAX_NOTES];
    for (var rn = 0; rn < MAX_NOTES; rn++) {
        rc_note_amt[rn] = Num2Bits(128);
        rc_note_amt[rn].in <== note_amount_in[rn];
    }

    signal token_id_out;
    token_id_out <== 1 - token_id_in;

    component input_note[MAX_NOTES];
    signal note_nullifier[MAX_NOTES];
    signal note_commitment[MAX_NOTES];
    signal note_amount_eff[MAX_NOTES];
    component note_amount_limbs[MAX_NOTES];
    component note_sum_add[MAX_NOTES];
    signal note_sum_limbs[MAX_NOTES + 1][2];
    note_sum_limbs[0][0] <== 0;
    note_sum_limbs[0][1] <== 0;
    for (var n2 = 0; n2 < MAX_NOTES; n2++) {
        input_note[n2] = TokenNote();
        input_note[n2].token_id <== token_id_in;
        input_note[n2].amount <== note_amount_in[n2];
        input_note[n2].secret <== secret_in[n2];
        input_note[n2].nullifier_seed <== nullifier_seed_in[n2];
        note_nullifier[n2] <== input_note[n2].nullifier;
        note_commitment[n2] <== input_note[n2].commitment;

        note_amount_eff[n2] <== note_amount_in[n2] * note_active[n2];
        note_amount_limbs[n2] = U128ToU256Limbs();
        note_amount_limbs[n2].in <== note_amount_eff[n2];
        note_sum_add[n2] = U128Add();
        note_sum_add[n2].a[0] <== note_sum_limbs[n2][0];
        note_sum_add[n2].a[1] <== note_sum_limbs[n2][1];
        note_sum_add[n2].b[0] <== note_amount_limbs[n2].limbs[0];
        note_sum_add[n2].b[1] <== note_amount_limbs[n2].limbs[1];
        note_sum_add[n2].carry === 0;
        note_sum_limbs[n2 + 1][0] <== note_sum_add[n2].out[0];
        note_sum_limbs[n2 + 1][1] <== note_sum_add[n2].out[1];

        if (n2 == 0) {
            commitment_in === note_active[n2] * note_commitment[n2];
            nullifier === note_active[n2] * note_nullifier[n2];
        } else {
            commitment_extra[n2 - 1] === note_active[n2] * note_commitment[n2];
            nullifier_extra[n2 - 1] === note_active[n2] * note_nullifier[n2];
        }
    }

    signal note_amount_total;
    note_amount_total <== note_sum_limbs[MAX_NOTES][0]
        + note_sum_limbs[MAX_NOTES][1] * (1 << 64);

    component nullifier_eq[MAX_NOTES][MAX_NOTES];
    signal nullifier_both_active[MAX_NOTES][MAX_NOTES];
    for (var ni = 0; ni < MAX_NOTES; ni++) {
        for (var nj = ni + 1; nj < MAX_NOTES; nj++) {
            nullifier_eq[ni][nj] = IsEqual();
            nullifier_eq[ni][nj].in[0] <== note_nullifier[ni];
            nullifier_eq[ni][nj].in[1] <== note_nullifier[nj];
            nullifier_both_active[ni][nj] <== note_active[ni] * note_active[nj];
            nullifier_both_active[ni][nj] * nullifier_eq[ni][nj].out === 0;
        }
    }

    // direction enforcement on aggregate prices
    component dec_price_start_dir = DecomposeU256ToLimbs();
    dec_price_start_dir.value <== sqrt_price_start;
    component dec_price_end_dir = DecomposeU256ToLimbs();
    dec_price_end_dir.value <== sqrt_price_end_public;
    component cmp_dir_final = U256Cmp();
    for (var d = 0; d < 4; d++) {
        cmp_dir_final.a[d] <== dec_price_start_dir.limbs[d];
        cmp_dir_final.b[d] <== dec_price_end_dir.limbs[d];
    }
    zero_for_one * (cmp_dir_final.gt + cmp_dir_final.eq) === zero_for_one;
    (1 - zero_for_one) * (cmp_dir_final.lt + cmp_dir_final.eq) === (1 - zero_for_one);

    signal sum_in_inputs[MAX_STEPS + 1];
    signal sum_out_inputs[MAX_STEPS + 1];
    sum_in_inputs[0] <== 0;
    sum_out_inputs[0] <== 0;
    for (var si = 0; si < MAX_STEPS; si++) {
        sum_in_inputs[si + 1] <== sum_in_inputs[si] + step_amount_in[si];
        sum_out_inputs[si + 1] <== sum_out_inputs[si] + step_amount_out[si];
    }
    amount_in_consumed <== sum_in_inputs[MAX_STEPS];
    amount_out <== sum_out_inputs[MAX_STEPS];

    // chains
    signal step_sqrt_price_start[MAX_STEPS + 1];
    signal step_liquidity[MAX_STEPS + 1];
    signal step_fee_growth_0[MAX_STEPS + 1][4];
    signal step_fee_growth_1[MAX_STEPS + 1][4];
    signal amount_remaining[MAX_STEPS + 1];
    signal sum_in_chain[MAX_STEPS + 1];
    signal sum_out_chain[MAX_STEPS + 1];

    step_sqrt_price_start[0] <== sqrt_price_start;
    step_liquidity[0] <== liquidity_before;
    amount_remaining[0] <== amount_out;
    sum_in_chain[0] <== 0;
    sum_out_chain[0] <== 0;

    signal halted[MAX_STEPS + 1];
    signal limited_accum[MAX_STEPS + 1];
    signal overflow_accum[MAX_STEPS + 1];
    halted[0] <== 0;
    limited_accum[0] <== 0;
    overflow_accum[0] <== 0;

    component fee0_before = DecomposeU256ToLimbs();
    fee0_before.value <== fee_growth_global_0_before;
    component fee1_before = DecomposeU256ToLimbs();
    fee1_before.value <== fee_growth_global_1_before;
    for (var f = 0; f < 4; f++) {
        step_fee_growth_0[0][f] <== fee0_before.limbs[f];
        step_fee_growth_1[0][f] <== fee1_before.limbs[f];
    }

    component dec_limit[MAX_STEPS];
    component dec_end[MAX_STEPS];
    component cmp_end_limit[MAX_STEPS];
    signal choose_end[MAX_STEPS];
    component limit_sel[MAX_STEPS];
    component step[MAX_STEPS];
    signal step_limit_value[MAX_STEPS];
    signal active[MAX_STEPS];
    signal amount_remaining_step[MAX_STEPS];
    component step_limit_bind[MAX_STEPS];
    component tick_range[MAX_STEPS];
    component dec_step_next[MAX_STEPS];
    component dec_step_out[MAX_STEPS];
    component step_limit_eq[MAX_STEPS];
    signal step_hit_limit[MAX_STEPS];
    component step_in_limbs[MAX_STEPS];
    component calc_in[MAX_STEPS];
    component step_out_limbs[MAX_STEPS];
    component calc_out[MAX_STEPS];
    component rem_a[MAX_STEPS];
    component rem_b[MAX_STEPS];
    component rem_sub[MAX_STEPS];
    component fee_amt_limbs[MAX_STEPS];
    component liq_limbs[MAX_STEPS];
    component liq_zero[MAX_STEPS];
    component fee_zero[MAX_STEPS];
    signal do_fee[MAX_STEPS];
    signal fee_num[MAX_STEPS][4];
    signal fee_num_u512[MAX_STEPS][8];
    signal safe_liq[MAX_STEPS][4];
    component fee_div[MAX_STEPS];
    signal fee_inc[MAX_STEPS][4];
    component add0[MAX_STEPS];
    component add1[MAX_STEPS];
    component fee0_pub[MAX_STEPS];
    component fee1_pub[MAX_STEPS];
    component fee0_max[MAX_STEPS];
    component fee1_max[MAX_STEPS];
    component crossed_cmp[MAX_STEPS];
    signal crossed[MAX_STEPS];
    component liq_net[MAX_STEPS];
    signal add_liq[MAX_STEPS];
    component liq_add[MAX_STEPS];
    component liq_sub[MAX_STEPS];
    component liq_cur[MAX_STEPS];
    component liq_mag[MAX_STEPS];
    signal liq_after_cross[MAX_STEPS][2];
    signal liq_after_value[MAX_STEPS];
    signal liq_cur_value[MAX_STEPS];
    signal liq_next_u128[MAX_STEPS];
    component end_eq[MAX_STEPS];
    signal step_hit_end[MAX_STEPS];
    signal halt_event[MAX_STEPS];
    signal halted_next[MAX_STEPS];
    signal limited_next[MAX_STEPS];
    signal overflow_next[MAX_STEPS];

    for (var i = 0; i < MAX_STEPS; i++) {
        // compute step limit from final price and tick boundary
        dec_limit[i] = DecomposeU256ToLimbs();
        dec_limit[i].value <== step_sqrt_price_limit[i];
        dec_end[i] = DecomposeU256ToLimbs();
        dec_end[i].value <== sqrt_price_end_public;

        cmp_end_limit[i] = U256Cmp();
        for (var j = 0; j < 4; j++) {
            cmp_end_limit[i].a[j] <== dec_end[i].limbs[j];
            cmp_end_limit[i].b[j] <== dec_limit[i].limbs[j];
        }

        choose_end[i] <== cmp_end_limit[i].lt + zero_for_one * (cmp_end_limit[i].gt - cmp_end_limit[i].lt);
        choose_end[i] * (choose_end[i] - 1) === 0;

        limit_sel[i] = U256Select();
        limit_sel[i].sel <== choose_end[i];
        for (var j2 = 0; j2 < 4; j2++) {
            limit_sel[i].a[j2] <== dec_end[i].limbs[j2];
            limit_sel[i].b[j2] <== dec_limit[i].limbs[j2];
        }
        step_limit_value[i] <== limit_sel[i].out[0]
            + limit_sel[i].out[1] * (1 << 64)
            + limit_sel[i].out[2] * (1 << 128)
            + limit_sel[i].out[3] * (1 << 192);

        // swap step
        step[i] = ClmmStepExactOut();
        step[i].sqrt_price_start <== step_sqrt_price_start[i];
        step[i].sqrt_price_limit <== step_limit_value[i];
        step[i].liquidity <== step_liquidity[i];
        active[i] <== 1 - halted[i];
        active[i] * (active[i] - 1) === 0;
        amount_remaining_step[i] <== amount_remaining[i] * active[i];
        step[i].amount_remaining <== amount_remaining_step[i];
        step[i].fee <== fee;
        step[i].zero_for_one <== zero_for_one;
        for (var dq0 = 0; dq0 < 4; dq0++) {
            step[i].amount_before_fee_div_q[dq0] <== step_amount_before_fee_div_q[i][dq0];
            step[i].next0_div_ceil_q[dq0] <== step_next0_div_ceil_q[i][dq0];
            step[i].next1_div_floor_q[dq0] <== step_next1_div_floor_q[i][dq0];
        }
        for (var dq1 = 0; dq1 < 4; dq1++) {
            for (var dq2 = 0; dq2 < 4; dq2++) {
                step[i].amount0_limit_div_q[dq1][dq2] <== step_amount0_limit_div_q[i][dq1][dq2];
                step[i].amount0_calc_div_q[dq1][dq2] <== step_amount0_calc_div_q[i][dq1][dq2];
                step[i].amount0_out_div_q[dq1][dq2] <== step_amount0_out_div_q[i][dq1][dq2];
            }
        }

        // bind limit limbs to step input
        step_limit_bind[i] = DecomposeU256ToLimbs();
        step_limit_bind[i].value <== step_limit_value[i];
        for (var l = 0; l < 4; l++) {
            step_limit_bind[i].limbs[l] === limit_sel[i].out[l];
        }

        tick_range[i] = I32RangeCheck();
        tick_range[i].value <== step_tick_next[i];

        // enforce step outputs against public next price
        dec_step_next[i] = DecomposeU256ToLimbs();
        dec_step_next[i].value <== step_sqrt_price_next[i];
        dec_step_out[i] = DecomposeU256ToLimbs();
        dec_step_out[i].value <== step[i].sqrt_price_next;
        for (var l2 = 0; l2 < 4; l2++) {
            dec_step_next[i].limbs[l2] === dec_step_out[i].limbs[l2];
        }

        step_limit_eq[i] = U256Eq();
        for (var lim = 0; lim < 4; lim++) {
            step_limit_eq[i].a[lim] <== dec_step_next[i].limbs[lim];
            step_limit_eq[i].b[lim] <== step_limit_bind[i].limbs[lim];
        }
        step_hit_limit[i] <== step_limit_eq[i].eq;

        // amount in/out binding
        step_in_limbs[i] = U128ToU256Limbs();
        step_in_limbs[i].in <== step_amount_in[i];
        calc_in[i] = U128ToU256Limbs();
        calc_in[i].in <== step[i].amount_in;
        step_in_limbs[i].limbs[0] === calc_in[i].limbs[0];
        step_in_limbs[i].limbs[1] === calc_in[i].limbs[1];
        step_in_limbs[i].limbs[2] === 0;
        step_in_limbs[i].limbs[3] === 0;

        step_out_limbs[i] = U128ToU256Limbs();
        step_out_limbs[i].in <== step_amount_out[i];
        calc_out[i] = U128ToU256Limbs();
        calc_out[i].in <== step[i].amount_out;
        step_out_limbs[i].limbs[0] === calc_out[i].limbs[0];
        step_out_limbs[i].limbs[1] === calc_out[i].limbs[1];
        step_out_limbs[i].limbs[2] === 0;
        step_out_limbs[i].limbs[3] === 0;

        // update amount remaining
        rem_a[i] = U128ToU256Limbs();
        rem_a[i].in <== amount_remaining[i];
        rem_b[i] = U128ToU256Limbs();
        rem_b[i].in <== step_amount_out[i];
        rem_sub[i] = U128Sub();
        rem_sub[i].a[0] <== rem_a[i].limbs[0];
        rem_sub[i].a[1] <== rem_a[i].limbs[1];
        rem_sub[i].b[0] <== rem_b[i].limbs[0];
        rem_sub[i].b[1] <== rem_b[i].limbs[1];
        amount_remaining[i + 1] <== rem_sub[i].out[0] + rem_sub[i].out[1] * (1 << 64);

        sum_in_chain[i + 1] <== sum_in_chain[i] + step_amount_in[i];
        sum_out_chain[i + 1] <== sum_out_chain[i] + step_amount_out[i];

        // fee growth update
        fee_amt_limbs[i] = U128ToU256Limbs();
        fee_amt_limbs[i].in <== step[i].fee_amount;
        liq_limbs[i] = U128ToU256Limbs();
        liq_limbs[i].in <== step_liquidity[i];
        liq_zero[i] = U128IsZero();
        liq_zero[i].limbs[0] <== liq_limbs[i].limbs[0];
        liq_zero[i].limbs[1] <== liq_limbs[i].limbs[1];
        fee_zero[i] = U128IsZero();
        fee_zero[i].limbs[0] <== fee_amt_limbs[i].limbs[0];
        fee_zero[i].limbs[1] <== fee_amt_limbs[i].limbs[1];
        do_fee[i] <== (1 - liq_zero[i].out) * (1 - fee_zero[i].out);
        do_fee[i] * (do_fee[i] - 1) === 0;

        // numerator = fee_amount << 128
        fee_num[i][0] <== 0;
        fee_num[i][1] <== 0;
        fee_num[i][2] <== fee_amt_limbs[i].limbs[0];
        fee_num[i][3] <== fee_amt_limbs[i].limbs[1];
        for (var m = 0; m < 4; m++) fee_num_u512[i][m] <== fee_num[i][m];
        for (var m2 = 4; m2 < 8; m2++) fee_num_u512[i][m2] <== 0;

        // safe liquidity for div
        safe_liq[i][0] <== liq_limbs[i].limbs[0] + liq_zero[i].out;
        safe_liq[i][1] <== liq_limbs[i].limbs[1];
        safe_liq[i][2] <== 0;
        safe_liq[i][3] <== 0;

        fee_div[i] = U256DivFloor();
        for (var n = 0; n < 8; n++) fee_div[i].num[n] <== fee_num_u512[i][n];
        for (var n2 = 0; n2 < 4; n2++) {
            fee_div[i].den[n2] <== safe_liq[i][n2];
            fee_div[i].q_val[n2] <== step_fee_div_q[i][n2];
        }

        for (var o = 0; o < 4; o++) {
            fee_inc[i][o] <== fee_div[i].out[o] * do_fee[i];
        }

        add0[i] = U256Add();
        add1[i] = U256Add();
        for (var p = 0; p < 4; p++) {
            add0[i].a[p] <== step_fee_growth_0[i][p];
            add1[i].a[p] <== step_fee_growth_1[i][p];
            add0[i].b[p] <== fee_inc[i][p] * zero_for_one;
            add1[i].b[p] <== fee_inc[i][p] * (1 - zero_for_one);
        }
        add0[i].carry === 0;
        add1[i].carry === 0;

        // bind to public fee growth outputs
        fee0_pub[i] = DecomposeU256ToLimbs();
        fee0_pub[i].value <== step_fee_growth_global_0[i];
        fee1_pub[i] = DecomposeU256ToLimbs();
        fee1_pub[i].value <== step_fee_growth_global_1[i];
        for (var q = 0; q < 4; q++) {
            fee0_pub[i].limbs[q] === add0[i].out[q];
            fee1_pub[i].limbs[q] === add1[i].out[q];
            step_fee_growth_0[i + 1][q] <== add0[i].out[q];
            step_fee_growth_1[i + 1][q] <== add1[i].out[q];
        }
        fee0_max[i] = U256Cmp();
        fee1_max[i] = U256Cmp();
        for (var qm = 0; qm < 4; qm++) {
            fee0_max[i].a[qm] <== fee0_pub[i].limbs[qm];
            fee0_max[i].b[qm] <== max_fee_limbs.limbs[qm];
            fee1_max[i].a[qm] <== fee1_pub[i].limbs[qm];
            fee1_max[i].b[qm] <== max_fee_limbs.limbs[qm];
        }
        fee0_max[i].lt + fee0_max[i].eq === 1;
        fee1_max[i].lt + fee1_max[i].eq === 1;

        // liquidity update on tick crossing
        crossed_cmp[i] = U256Eq();
        for (var r = 0; r < 4; r++) {
            crossed_cmp[i].a[r] <== dec_step_next[i].limbs[r];
            crossed_cmp[i].b[r] <== dec_limit[i].limbs[r];
        }
        crossed[i] <== crossed_cmp[i].eq;

        liq_net[i] = DecodeSignedI256ToU128();
        liq_net[i].value <== step_liquidity_net[i];

        add_liq[i] <== 1 - (liq_net[i].sign + zero_for_one - 2 * liq_net[i].sign * zero_for_one);
        add_liq[i] * (add_liq[i] - 1) === 0;

        liq_add[i] = U128Add();
        liq_sub[i] = U128Sub();
        liq_cur[i] = U128ToU256Limbs();
        liq_cur[i].in <== step_liquidity[i];
        liq_mag[i] = U128ToU256Limbs();
        liq_mag[i].in <== liq_net[i].mag;
        liq_add[i].a[0] <== liq_cur[i].limbs[0];
        liq_add[i].a[1] <== liq_cur[i].limbs[1];
        liq_add[i].b[0] <== liq_mag[i].limbs[0];
        liq_add[i].b[1] <== liq_mag[i].limbs[1];
        liq_sub[i].a[0] <== liq_cur[i].limbs[0];
        liq_sub[i].a[1] <== liq_cur[i].limbs[1];
        liq_sub[i].b[0] <== liq_mag[i].limbs[0];
        liq_sub[i].b[1] <== liq_mag[i].limbs[1];

        liq_after_cross[i][0] <== liq_sub[i].out[0] + add_liq[i] * (liq_add[i].out[0] - liq_sub[i].out[0]);
        liq_after_cross[i][1] <== liq_sub[i].out[1] + add_liq[i] * (liq_add[i].out[1] - liq_sub[i].out[1]);

        liq_after_value[i] <== liq_after_cross[i][0] + liq_after_cross[i][1] * (1 << 64);
        liq_cur_value[i] <== liq_cur[i].limbs[0] + liq_cur[i].limbs[1] * (1 << 64);
        liq_next_u128[i] <== liq_cur_value[i] + crossed[i] * (liq_after_value[i] - liq_cur_value[i]);
        step_liquidity[i + 1] <== liq_next_u128[i];

        // advance price
        step_sqrt_price_start[i + 1] <== step_sqrt_price_next[i];

        end_eq[i] = U256Eq();
        for (var he = 0; he < 4; he++) {
            end_eq[i].a[he] <== dec_step_next[i].limbs[he];
            end_eq[i].b[he] <== dec_end[i].limbs[he];
        }
        step_hit_end[i] <== end_eq[i].eq;

        halt_event[i] <== step_hit_end[i] + step[i].is_overflow - step_hit_end[i] * step[i].is_overflow;
        halt_event[i] * (halt_event[i] - 1) === 0;
        halted_next[i] <== halted[i] + halt_event[i] - halted[i] * halt_event[i];
        halted_next[i] * (halted_next[i] - 1) === 0;
        halted[i + 1] <== halted_next[i];

        limited_next[i] <== limited_accum[i] + step_hit_limit[i]
            - limited_accum[i] * step_hit_limit[i];
        limited_next[i] * (limited_next[i] - 1) === 0;
        limited_accum[i + 1] <== limited_next[i];

        overflow_next[i] <== overflow_accum[i] + step[i].is_overflow - overflow_accum[i] * step[i].is_overflow;
        overflow_next[i] * (overflow_next[i] - 1) === 0;
        overflow_accum[i + 1] <== overflow_next[i];
    }

    // final price binding
    step_sqrt_price_start[MAX_STEPS] === sqrt_price_end_public;

    component fee0_after_cmp = U256Cmp();
    component fee1_after_cmp = U256Cmp();
    for (var f = 0; f < 4; f++) {
        fee0_after_cmp.a[f] <== fee0_before_limbs.limbs[f];
        fee0_after_cmp.b[f] <== fee0_pub[MAX_STEPS - 1].limbs[f];
        fee1_after_cmp.a[f] <== fee1_before_limbs.limbs[f];
        fee1_after_cmp.b[f] <== fee1_pub[MAX_STEPS - 1].limbs[f];
    }
    fee0_after_cmp.lt + fee0_after_cmp.eq === 1;
    fee1_after_cmp.lt + fee1_after_cmp.eq === 1;

    // sum checks
    amount_in_consumed === sum_in_chain[MAX_STEPS];
    amount_out === sum_out_chain[MAX_STEPS];
    component rc_amt_consumed = Num2Bits(128);
    rc_amt_consumed.in <== amount_in_consumed;
    component rc_amt_out_total = Num2Bits(128);
    rc_amt_out_total.in <== amount_out;
    component dec_amt_consumed = DecomposeU256ToLimbs();
    dec_amt_consumed.value <== amount_in_consumed;
    dec_amt_consumed.limbs[2] === 0;
    dec_amt_consumed.limbs[3] === 0;
    component dec_amt_out_total = DecomposeU256ToLimbs();
    dec_amt_out_total.value <== amount_out;
    dec_amt_out_total.limbs[2] === 0;
    dec_amt_out_total.limbs[3] === 0;

    component output_note = TokenNote();
    output_note.token_id <== token_id_out;
    output_note.amount <== amount_out;
    output_note.secret <== secret_out;
    output_note.nullifier_seed <== nullifier_seed_out;

    // only emit an output commitment when amount_out is nonzero
    component out_limbs = U128ToU256Limbs();
    out_limbs.in <== amount_out;
    component out_zero = U128IsZero();
    out_zero.limbs[0] <== out_limbs.limbs[0];
    out_zero.limbs[1] <== out_limbs.limbs[1];
    signal has_output;
    has_output <== 1 - out_zero.out;
    has_output * (has_output - 1) === 0;
    output_commitment === has_output * output_note.commitment;

    component note_limbs = U128ToU256Limbs();
    note_limbs.in <== note_amount_total;
    component consumed_limbs = U128ToU256Limbs();
    consumed_limbs.in <== amount_in_consumed;
    component change_sub = U128Sub();
    change_sub.a[0] <== note_limbs.limbs[0];
    change_sub.a[1] <== note_limbs.limbs[1];
    change_sub.b[0] <== consumed_limbs.limbs[0];
    change_sub.b[1] <== consumed_limbs.limbs[1];
    signal change_amount;
    change_amount <== change_sub.out[0] + change_sub.out[1] * (1 << 64);

    component change_zero = U128IsZero();
    change_zero.limbs[0] <== change_sub.out[0];
    change_zero.limbs[1] <== change_sub.out[1];
    signal has_change;
    has_change <== 1 - change_zero.out;
    has_change * (has_change - 1) === 0;

    component change_note = TokenNote();
    change_note.token_id <== token_id_in;
    change_note.amount <== change_amount;
    change_note.secret <== change_secret;
    change_note.nullifier_seed <== change_nullifier_seed;
    change_commitment === has_change * change_note.commitment;

    overflow_accum[MAX_STEPS] === 0;
    is_limited === limited_accum[MAX_STEPS];
    is_limited * (is_limited - 1) === 0;
}

component main { public [
    tag,
    merkle_root,
    nullifier,
    sqrt_price_start,
    sqrt_price_end_public,
    liquidity_before,
    fee,
    fee_growth_global_0_before,
    fee_growth_global_1_before,
    output_commitment,
    change_commitment,
    is_limited,
    zero_for_one,
    step_sqrt_price_next,
    step_sqrt_price_limit,
    step_tick_next,
    step_liquidity_net,
    step_fee_growth_global_0,
    step_fee_growth_global_1,
    commitment_in,
    token_id_in,
    note_count,
    nullifier_extra,
    commitment_extra
] } = PrivateSwapExactOut();
