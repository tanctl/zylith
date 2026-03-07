pragma circom 2.2.3;

include "./private_swap_exact_out.circom";

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
] } = PrivateSwapExactOutDir(0);
