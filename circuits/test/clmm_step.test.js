'use strict';

const { loadCircuit, loadVectorOrSkip, runVector, logPerf } = require('./utils');

describe('clmm_step', function () {
  this.timeout(120000);

  async function withVector(name, fn) {
    const vector = loadVectorOrSkip(this, 'clmm_step', name);
    if (!vector) return;
    const circuit = await loadCircuit('test/fixtures/clmm_step_wrapper.circom');
    await fn(circuit, vector);
  }

  it('test_single_step_zero_for_one', async function () {
    await withVector.call(this, 'single_step_zero_for_one', runVector);
  });

  it('test_single_step_one_for_zero', async function () {
    await withVector.call(this, 'single_step_one_for_zero', runVector);
  });

  it('test_exact_amount_in', async function () {
    await withVector.call(this, 'exact_amount_in', runVector);
  });

  it('test_price_limit_reached', async function () {
    await withVector.call(this, 'price_limit_reached', runVector);
  });

  it('test_full_liquidity_consumed', async function () {
    await withVector.call(this, 'full_liquidity_consumed', runVector);
  });

  it('test_fee_application', async function () {
    await withVector.call(this, 'fee_application', runVector);
  });

  it('test_match_ekubo_output', async function () {
    await withVector.call(this, 'match_ekubo_output', runVector);
  });

  it('perf_clmm_step', async function () {
    const vector = loadVectorOrSkip(this, 'clmm_step', 'single_step_zero_for_one');
    if (!vector) return;
    const circuit = await loadCircuit('test/fixtures/clmm_step_wrapper.circom');
    await logPerf('clmm_step', circuit, vector.input);
  });
});
