'use strict';

const { expect } = require('chai');
const { buildPoseidon } = require('circomlibjs');
const {
  STARK_MODULUS,
  loadCircuit,
  expectWitnessFail,
  readSignal,
} = require('./utils');

const VK_MEMBERSHIP = BigInt('0x4d454d42455253484950');
const DOMAIN_TAG = BigInt('0x5a594c495448');
const NOTE_TYPE_TOKEN = BigInt(1);
const ZERO_LEAF_HASH = BigInt(
  '0x293d3e8a80f400daaaffdd5932e2bcc8814bab8f414a75dcacf87318f8b14c5'
);

async function computeNoteCommitment({ tokenId, amount, secret, nullifierSeed }) {
  const poseidon = await buildPoseidon();
  const F = poseidon.F;
  const nullifier = F.toObject(
    poseidon([DOMAIN_TAG, NOTE_TYPE_TOKEN, tokenId, secret, nullifierSeed])
  );
  const commitment = F.toObject(
    poseidon([DOMAIN_TAG, NOTE_TYPE_TOKEN, tokenId, amount, secret, nullifier])
  );
  return { commitment, nullifier };
}

async function findValidNote({ tokenId, amount }) {
  for (let i = 1; i < 5000; i++) {
    const secret = BigInt(i);
    const nullifierSeed = BigInt(i + 1000);
    const { commitment, nullifier } = await computeNoteCommitment({
      tokenId,
      amount,
      secret,
      nullifierSeed,
    });
    if (
      commitment > 0n &&
      commitment < STARK_MODULUS &&
      commitment !== ZERO_LEAF_HASH &&
      nullifier < STARK_MODULUS
    ) {
      return { commitment, nullifier, secret, nullifierSeed };
    }
  }
  throw new Error('no valid note found');
}

describe('membership', function () {
  this.timeout(120000);

  it('test_valid_membership_proof', async function () {
    const circuit = await loadCircuit('membership.circom');
    const tokenId = BigInt(0);
    const amount = BigInt(1234);
    const { commitment, secret, nullifierSeed } = await findValidNote({
      tokenId,
      amount,
    });

    const input = {
      tag: VK_MEMBERSHIP.toString(),
      merkle_root: '1',
      commitment: commitment.toString(),
      token_id: tokenId.toString(),
      amount: amount.toString(),
      secret: secret.toString(),
      nullifier_seed: nullifierSeed.toString(),
    };

    const witness = await circuit.calculateWitness(input, true);
    await circuit.checkConstraints(witness);
    const outCommitment = await readSignal(circuit, witness, 'main.out_commitment');
    expect(outCommitment.toString()).to.equal(commitment.toString());
  });

  it('test_invalid_path_fails', async function () {
    const circuit = await loadCircuit('membership.circom');
    const tokenId = BigInt(0);
    const amount = BigInt(1);
    const secret = BigInt(2);
    const nullifierSeed = BigInt(3);
    const { commitment } = await computeNoteCommitment({
      tokenId,
      amount,
      secret,
      nullifierSeed,
    });

    const input = {
      tag: VK_MEMBERSHIP.toString(),
      merkle_root: STARK_MODULUS.toString(),
      commitment: commitment.toString(),
      token_id: tokenId.toString(),
      amount: amount.toString(),
      secret: secret.toString(),
      nullifier_seed: nullifierSeed.toString(),
    };

    await expectWitnessFail(circuit, input);
  });

  it('test_wrong_nullifier_fails', async function () {
    const circuit = await loadCircuit('membership.circom');
    const tokenId = BigInt(1);
    const amount = BigInt(100);
    const secret = BigInt(777);
    const nullifierSeed = BigInt(11);
    const { commitment } = await computeNoteCommitment({
      tokenId,
      amount,
      secret,
      nullifierSeed,
    });

    const input = {
      tag: VK_MEMBERSHIP.toString(),
      merkle_root: '2',
      commitment: commitment.toString(),
      token_id: tokenId.toString(),
      amount: amount.toString(),
      secret: secret.toString(),
      nullifier_seed: '12',
    };

    await expectWitnessFail(circuit, input);
  });

  it('test_wrong_amount_fails', async function () {
    const circuit = await loadCircuit('membership.circom');
    const tokenId = BigInt(1);
    const amount = BigInt(100);
    const secret = BigInt(888);
    const nullifierSeed = BigInt(9);
    const { commitment } = await computeNoteCommitment({
      tokenId,
      amount,
      secret,
      nullifierSeed,
    });

    const input = {
      tag: VK_MEMBERSHIP.toString(),
      merkle_root: '3',
      commitment: commitment.toString(),
      token_id: tokenId.toString(),
      amount: '101',
      secret: secret.toString(),
      nullifier_seed: nullifierSeed.toString(),
    };

    await expectWitnessFail(circuit, input);
  });

  it('test_zero_leaf_fails', async function () {
    const circuit = await loadCircuit('membership.circom');
    const input = {
      tag: VK_MEMBERSHIP.toString(),
      merkle_root: '4',
      commitment: '0',
      token_id: '0',
      amount: '1',
      secret: '2',
      nullifier_seed: '3',
    };

    await expectWitnessFail(circuit, input);
  });
});
