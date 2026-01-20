'use strict';

const { loadCircuit, loadVectorOrSkip, runVector, logPerf } = require('./utils');

describe('private_swap', function () {
  this.timeout(120000);

  async function withVector(name, fn) {
    const vector = loadVectorOrSkip(this, 'private_swap', name);
    if (!vector) return;
    const circuit = await loadCircuit('private_swap.circom');
    await fn(circuit, vector);
  }

  it('test_single_step_swap', async function () {
    await withVector.call(this, 'single_step_swap', runVector);
  });

  it('test_multi_step_swap', async function () {
    await withVector.call(this, 'multi_step_swap', runVector);
  });

  it('test_tick_crossing', async function () {
    await withVector.call(this, 'tick_crossing', runVector);
  });

  it('test_insufficient_balance_fails', async function () {
    await withVector.call(this, 'insufficient_balance_fails', runVector);
  });

  it('test_output_commitment_computed', async function () {
    await withVector.call(this, 'output_commitment_computed', runVector);
  });

  it('test_price_transition_correct', async function () {
    await withVector.call(this, 'price_transition_correct', runVector);
  });

  it('test_10_tick_crossings_max', async function () {
    await withVector.call(this, 'ten_tick_crossings_max', runVector);
  });

  it('perf_private_swap', async function () {
    const vector = loadVectorOrSkip(this, 'private_swap', 'single_step_swap');
    if (!vector) return;
    const circuit = await loadCircuit('private_swap.circom');
    await logPerf('private_swap', circuit, vector.input);
  });
});
