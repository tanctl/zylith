'use strict';

const { loadCircuit, loadVectorOrSkip, runVector, logPerf } = require('./utils');

describe('private_swap_exact_out', function () {
  const timeoutMs = Number.parseInt(process.env.CIRCUIT_TEST_TIMEOUT_MS || '600000', 10);
  this.timeout(Number.isFinite(timeoutMs) ? timeoutMs : 600000);

  async function withVector(name, circuitPath, fn) {
    const vector = loadVectorOrSkip(this, 'private_swap_exact_out', name);
    if (!vector) return;
    const circuit = await loadCircuit(circuitPath);
    await fn(circuit, vector);
  }

  it('test_single_step_swap_exact_out', async function () {
    await withVector.call(
      this,
      'single_step_swap_exact_out',
      'private_swap_exact_out_one_for_zero.circom',
      runVector
    );
  });

  it('test_multi_step_swap_exact_out', async function () {
    await withVector.call(
      this,
      'multi_step_swap_exact_out',
      'private_swap_exact_out_one_for_zero.circom',
      runVector
    );
  });

  it('test_single_step_swap_exact_out_zero_for_one', async function () {
    await withVector.call(
      this,
      'single_step_swap_exact_out_zero_for_one',
      'private_swap_exact_out_zero_for_one.circom',
      runVector
    );
  });

  it('perf_private_swap_exact_out', async function () {
    const vector = loadVectorOrSkip(this, 'private_swap_exact_out', 'single_step_swap_exact_out');
    if (!vector) return;
    const circuit = await loadCircuit('private_swap_exact_out_one_for_zero.circom');
    await logPerf('private_swap_exact_out', circuit, vector.input);
  });
});
