use core::integer::u256;
use core::num::traits::{OverflowingAdd, OverflowingSub, Zero};
use crate::constants::generated as generated_constants;
use crate::types::fees_per_liquidity::{
    FeesPerLiquidity, fees_per_liquidity_new, to_fees_per_liquidity,
};

const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;
const ONE_U256: u256 = u256 { low: 1, high: 0 };
const ZERO_U256: u256 = u256 { low: 0, high: 0 };
const MAX_U256: u256 = u256 { low: MAX_U128, high: MAX_U128 };
const MAX_FEE_GROWTH: u256 = generated_constants::MAX_FEE_GROWTH;

#[test]
fn test_u256_wraps() {
    let (sum, overflow_add) = OverflowingAdd::overflowing_add(MAX_U256, ONE_U256);
    assert(overflow_add, 'max+1 overflow');
    assert(sum == ZERO_U256, 'max+1');

    let (diff, overflow_sub) = OverflowingSub::overflowing_sub(ZERO_U256, ONE_U256);
    assert(overflow_sub, '0-1 overflow');
    assert(diff == MAX_U256, '0-1');
}

#[test]
fn test_fpl_zeroable() {
    let fpl: FeesPerLiquidity = Zero::zero();
    assert(fpl.value0 == Zero::zero(), 'fpl0');
    assert(fpl.value1 == Zero::zero(), 'fpl1');
    assert(!fpl.is_non_zero(), 'nonzero');
    assert(fpl.is_zero(), 'zero');
}

#[test]
fn test_fpl_add_sub_zeroable() {
    let fpl: FeesPerLiquidity = Zero::zero();
    assert(!(fpl + fpl).is_non_zero(), 'nonzero');
    assert(!(fpl - fpl).is_non_zero(), 'nonzero');
    assert((fpl + fpl).is_zero(), 'zero');
    assert((fpl - fpl).is_zero(), 'zero');
}

#[test]
fn test_fpl_underflow_sub() {
    let fpl_zero: FeesPerLiquidity = Zero::zero();
    let fpl_one = FeesPerLiquidity { value0: ONE_U256, value1: ONE_U256 };

    let difference = fpl_zero - fpl_one;

    assert(
        difference == FeesPerLiquidity { value0: MAX_FEE_GROWTH, value1: MAX_FEE_GROWTH },
        'overflow',
    );
}

#[test]
fn test_fpl_overflow_add() {
    let fpl_one = FeesPerLiquidity { value0: ONE_U256, value1: ONE_U256 };

    let fpl_max = FeesPerLiquidity { value0: MAX_FEE_GROWTH, value1: MAX_FEE_GROWTH };

    let sum = fpl_max + fpl_one;

    assert(sum == FeesPerLiquidity { value0: ZERO_U256, value1: ZERO_U256 }, 'sum');
}

#[test]
fn test_fees_per_liquidity_new() {
    assert(
        fees_per_liquidity_new(
            100, 250, 10000,
        ) == FeesPerLiquidity {
            value0: u256 { low: 3402823669209384634633746074317682114, high: 0 },
            value1: u256 { low: 8507059173023461586584365185794205286, high: 0 },
        },
        'example',
    );
}

#[test]
fn test_to_fees_per_liquidity_max_fees() {
    to_fees_per_liquidity(10633823966279327296825105735305134080, 1);
}

#[test]
#[should_panic(expected: ('FEES_OVERFLOW',))]
fn test_to_fees_per_liquidity_overflows() {
    to_fees_per_liquidity(10633823966279327296825105735305134081, 1);
}

#[test]
#[should_panic(expected: ('ZERO_LIQUIDITY_FEES',))]
fn test_to_fees_per_liquidity_div_by_zero() {
    to_fees_per_liquidity(1, 0);
}

#[test]
fn test_storage_size() {
    assert(starknet::Store::<FeesPerLiquidity>::size() == 4, 'size');
}
