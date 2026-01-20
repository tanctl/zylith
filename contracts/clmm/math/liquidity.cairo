use core::num::traits::Zero;
use crate::math::delta::{amount0_delta, amount1_delta};
use crate::types::delta::Delta;
use crate::types::i129::i129;

const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;
const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;

// Returns the token0, token1 delta owed for a given change in liquidity
pub fn liquidity_delta_to_amount_delta(
    sqrt_ratio: u256, liquidity_delta: u256, sqrt_ratio_lower: u256, sqrt_ratio_upper: u256,
) -> Delta {
    // skip the maths for the 0 case
    if (liquidity_delta.high == 0) & (liquidity_delta.low == 0) {
        return Zero::zero();
    }

    // if the pool is losing liquidity, we round the amount down
    let (sign, mag) = signed_u256_to_sign_mag(liquidity_delta);
    let round_up = !sign;

    if (sqrt_ratio <= sqrt_ratio_lower) {
        return Delta {
            amount0: i129 {
                mag: amount0_delta(
                    sqrt_ratio_lower, sqrt_ratio_upper, mag, round_up,
                ),
                sign,
            },
            amount1: Zero::zero(),
        };
    } else if (sqrt_ratio < sqrt_ratio_upper) {
        return Delta {
            amount0: i129 {
                mag: amount0_delta(sqrt_ratio, sqrt_ratio_upper, mag, round_up),
                sign,
            },
            amount1: i129 {
                mag: amount1_delta(sqrt_ratio_lower, sqrt_ratio, mag, round_up),
                sign,
            },
        };
    } else {
        return Delta {
            amount0: Zero::zero(),
            amount1: i129 {
                mag: amount1_delta(
                    sqrt_ratio_lower, sqrt_ratio_upper, mag, round_up,
                ),
                sign,
            },
        };
    }
}

fn signed_u256_to_sign_mag(value: u256) -> (bool, u128) {
    assert(value.high == 0, 'LIQ_DELTA_HIGH');
    if value.low < HIGH_BIT_U128 {
        (false, value.low)
    } else {
        let mag = if value.low == HIGH_BIT_U128 {
            HIGH_BIT_U128
        } else {
            (MAX_U128 - value.low) + 1
        };
        (true, mag)
    }
}
