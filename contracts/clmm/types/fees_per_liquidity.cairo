use core::num::traits::Zero;
use core::traits::Into;
use crate::constants::generated as generated_constants;

#[derive(Copy, Drop, Serde, PartialEq, starknet::Store, Debug)]
pub struct FeesPerLiquidity {
    pub value0: u256,
    pub value1: u256,
}

impl AddFeesPerLiquidity of Add<FeesPerLiquidity> {
    fn add(lhs: FeesPerLiquidity, rhs: FeesPerLiquidity) -> FeesPerLiquidity {
        FeesPerLiquidity {
            value0: add_fee_growth(lhs.value0, rhs.value0),
            value1: add_fee_growth(lhs.value1, rhs.value1),
        }
    }
}

impl SubFeesPerLiquidity of Sub<FeesPerLiquidity> {
    fn sub(lhs: FeesPerLiquidity, rhs: FeesPerLiquidity) -> FeesPerLiquidity {
        FeesPerLiquidity {
            value0: sub_fee_growth(lhs.value0, rhs.value0),
            value1: sub_fee_growth(lhs.value1, rhs.value1),
        }
    }
}

impl FeesPerLiquidityZero of Zero<FeesPerLiquidity> {
    fn zero() -> FeesPerLiquidity {
        FeesPerLiquidity { value0: Zero::zero(), value1: Zero::zero() }
    }
    fn is_zero(self: @FeesPerLiquidity) -> bool {
        (self.value0.is_zero()) & (self.value1.is_zero())
    }
    fn is_non_zero(self: @FeesPerLiquidity) -> bool {
        !Zero::is_zero(self)
    }
}

pub fn to_fees_per_liquidity(amount: u128, liquidity: u128) -> u256 {
    assert(liquidity.is_non_zero(), 'ZERO_LIQUIDITY_FEES');
    let max_amount = generated_constants::MAX_FEE_GROWTH.high;
    assert(generated_constants::MAX_FEE_GROWTH.low == 0, 'FEES_MAX_LOW_NONZERO');
    assert(amount <= max_amount, 'FEES_OVERFLOW');
    u256 { low: 0, high: amount } / liquidity.into()
}

fn fee_growth_modulus() -> u256 {
    generated_constants::MAX_FEE_GROWTH + u256 { low: 1, high: 0 }
}

fn add_fee_growth(lhs: u256, rhs: u256) -> u256 {
    let max = generated_constants::MAX_FEE_GROWTH;
    let sum = lhs + rhs;
    if sum > max {
        sum - fee_growth_modulus()
    } else {
        sum
    }
}

fn sub_fee_growth(lhs: u256, rhs: u256) -> u256 {
    if lhs >= rhs {
        lhs - rhs
    } else {
        fee_growth_modulus() - (rhs - lhs)
    }
}

pub fn fees_per_liquidity_new(amount0: u128, amount1: u128, liquidity: u128) -> FeesPerLiquidity {
    FeesPerLiquidity {
        value0: to_fees_per_liquidity(amount0, liquidity),
        value1: to_fees_per_liquidity(amount1, liquidity),
    }
}

pub fn fees_per_liquidity_from_amount0(amount0: u128, liquidity: u128) -> FeesPerLiquidity {
    FeesPerLiquidity { value0: to_fees_per_liquidity(amount0, liquidity), value1: Zero::zero() }
}

pub fn fees_per_liquidity_from_amount1(amount1: u128, liquidity: u128) -> FeesPerLiquidity {
    FeesPerLiquidity { value0: Zero::zero(), value1: to_fees_per_liquidity(amount1, liquidity) }
}
