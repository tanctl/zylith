'use strict';

const { loadCircuit, loadVectorOrSkip, runVector, logPerf } = require('./utils');

describe('private_swap', function () {
  const timeoutMs = Number.parseInt(process.env.CIRCUIT_TEST_TIMEOUT_MS || '600000', 10);
  this.timeout(Number.isFinite(timeoutMs) ? timeoutMs : 600000);

  async function withVector(name, circuitPath, fn) {
    const vector = loadVectorOrSkip(this, 'private_swap', name);
    if (!vector) return;
    const circuit = await loadCircuit(circuitPath);
    await fn(circuit, vector);
  }

  it('test_single_step_swap', async function () {
    await withVector.call(this, 'single_step_swap', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_multi_step_swap', async function () {
    await withVector.call(this, 'multi_step_swap', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_tick_crossing', async function () {
    await withVector.call(this, 'tick_crossing', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_insufficient_balance_fails', async function () {
    await withVector.call(this, 'insufficient_balance_fails', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_output_commitment_computed', async function () {
    await withVector.call(this, 'output_commitment_computed', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_price_transition_correct', async function () {
    await withVector.call(this, 'price_transition_correct', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_10_tick_crossings_max', async function () {
    await withVector.call(this, 'ten_tick_crossings_max', 'private_swap_one_for_zero.circom', runVector);
  });

  it('test_single_step_swap_zero_for_one', async function () {
    await withVector.call(
      this,
      'single_step_swap_zero_for_one',
      'private_swap_zero_for_one.circom',
      runVector
    );
  });

  it('perf_private_swap', async function () {
    const vector = loadVectorOrSkip(this, 'private_swap', 'single_step_swap');
    if (!vector) return;
    const circuit = await loadCircuit('private_swap_one_for_zero.circom');
    await logPerf('private_swap', circuit, vector.input);
  });
});
