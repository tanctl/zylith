'use strict';

const fs = require('fs');
const os = require('os');
const path = require('path');
const { expect } = require('chai');
const circomTester = require('circom_tester').wasm;

const STARK_MODULUS =
  BigInt('0x800000000000011000000000000000000000000000000000000000000000001');

function toBigInt(value) {
  if (typeof value === 'bigint') return value;
  if (typeof value === 'number') return BigInt(value);
  if (typeof value === 'string') return BigInt(value);
  throw new Error(`unsupported bigint conversion for ${typeof value}`);
}

async function loadCircuit(relPath) {
  const circuitPath = path.join(__dirname, '..', relPath);
  const tmpBase =
    process.env.ZYLITH_CIRCUITS_TMP ||
    path.join(os.tmpdir(), 'zylith-circuits');
  await fs.promises.mkdir(tmpBase, { recursive: true });
  const outputDir = path.join(
    tmpBase,
    `circom_${path.basename(relPath, path.extname(relPath))}`
  );
  await fs.promises.rm(outputDir, { recursive: true, force: true });
  await fs.promises.mkdir(outputDir, { recursive: true });
  const includePaths = [
    path.join(__dirname, '..'),
    path.join(__dirname, '..', 'node_modules'),
    path.join(__dirname, '..', 'node_modules', 'circomlib', 'circuits'),
  ];
  return circomTester(circuitPath, { include: includePaths, output: outputDir });
}

function loadVectorOrSkip(ctx, suite, name) {
  const baseDir = path.join(__dirname, 'vectors', suite);
  const filePath = path.join(baseDir, `${name}.json`);
  if (!fs.existsSync(filePath)) {
    if (process.env.ZYLITH_REQUIRE_VECTORS === '1') {
      throw new Error(`missing test vector: ${filePath}`);
    }
    ctx.skip();
    return null;
  }
  return JSON.parse(fs.readFileSync(filePath, 'utf8'));
}

async function expectWitnessFail(circuit, input) {
  let failed = false;
  try {
    await circuit.calculateWitness(input, true);
  } catch (err) {
    failed = true;
  }
  expect(failed, 'expected witness failure').to.equal(true);
}

async function readSignal(circuit, witness, signalPath) {
  if (!circuit.symbols) {
    await circuit.loadSymbols();
  }
  const sym = circuit.symbols[signalPath];
  if (!sym) {
    throw new Error(`signal not found: ${signalPath}`);
  }
  return toBigInt(witness[sym.varIdx]);
}

async function assertOutputs(circuit, witness, expected) {
  for (const [name, value] of Object.entries(expected)) {
    const actual = await readSignal(circuit, witness, `main.${name}`);
    expect(actual.toString()).to.equal(toBigInt(value).toString());
  }
}

async function runVector(circuit, vector) {
  if (vector.should_fail) {
    await expectWitnessFail(circuit, vector.input);
    return;
  }
  const witness = await circuit.calculateWitness(vector.input, true);
  await circuit.checkConstraints(witness);
  if (vector.expect && vector.expect.outputs) {
    await assertOutputs(circuit, witness, vector.expect.outputs);
  }
}

async function logPerf(label, circuit, input) {
  const start = Date.now();
  const witness = await circuit.calculateWitness(input, true);
  await circuit.checkConstraints(witness);
  const durationMs = Date.now() - start;
  const constraints = circuit.nConstraints || circuit.constraints?.length || 0;
  console.log(
    `[perf] ${label} witness_ms=${durationMs} constraints=${constraints}`
  );
  if (process.env.ZYLITH_ENFORCE_PERF === '1') {
    expect(durationMs).to.be.lessThan(60000);
  }
}

module.exports = {
  STARK_MODULUS,
  toBigInt,
  loadCircuit,
  loadVectorOrSkip,
  expectWitnessFail,
  readSignal,
  assertOutputs,
  runVector,
  logPerf,
};
