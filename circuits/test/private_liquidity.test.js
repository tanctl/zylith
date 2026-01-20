'use strict';

const { loadCircuit, loadVectorOrSkip, runVector, logPerf } = require('./utils');

describe('private_liquidity', function () {
  this.timeout(120000);

  async function withVector(name, fn) {
    const vector = loadVectorOrSkip(this, 'private_liquidity', name);
    if (!vector) return;
    const circuit = await loadCircuit('private_liquidity.circom');
    await fn(circuit, vector);
  }

  it('test_add_liquidity_in_range', async function () {
    await withVector.call(this, 'add_liquidity_in_range', runVector);
  });

  it('test_add_liquidity_out_of_range', async function () {
    await withVector.call(this, 'add_liquidity_out_of_range', runVector);
  });

  it('test_remove_liquidity_with_fees', async function () {
    await withVector.call(this, 'remove_liquidity_with_fees', runVector);
  });

  it('test_fee_calculation_matches_ekubo', async function () {
    await withVector.call(this, 'fee_calculation_matches_ekubo', runVector);
  });

  it('test_claim_liquidity_fees', async function () {
    await withVector.call(this, 'claim_liquidity_fees', runVector);
  });

  it('perf_private_liquidity', async function () {
    const vector = loadVectorOrSkip(this, 'private_liquidity', 'add_liquidity_in_range');
    if (!vector) return;
    const circuit = await loadCircuit('private_liquidity.circom');
    await logPerf('private_liquidity', circuit, vector.input);
  });
});
