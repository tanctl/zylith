import type { Call } from "starknet";

import type { MerklePath } from "./prover";

const TOKEN_DECIMALS = 18;
const U128_MAX = (BigInt(1) << BigInt(128)) - BigInt(1);

export type ZylithConfig = {
  poolAddress: string;
  shieldedNotesAddress: string;
  token0: string;
  token1: string;
};

const CHAIN_ID_ALIASES: Record<string, string> = {
  SN_SEPOLIA: "0x534e5f5345504f4c4941",
  SN_MAIN: "0x534e5f4d41494e",
};
const FELT_PATTERN = /^0x[0-9a-fA-F]+$/;
const ZERO_FELT_PATTERN = /^0x0+$/;

function getRawEnv(key: string): string {
  const value = import.meta.env[key];
  if (!value) {
    // Return empty string instead of throwing to prevent client crash
    // The config will be validated at runtime when needed
    console.warn(`Environment variable ${key} is not set`);
    return "";
  }
  return String(value).trim();
}

function getEnv(key: string): string {
  const value = getRawEnv(key);
  if (!value) return "";
  return normalizeHex(value);
}

export const zylithConfig: ZylithConfig = {
  poolAddress: getEnv("VITE_POOL_ADDRESS"),
  shieldedNotesAddress: getEnv("VITE_SHIELDED_NOTES"),
  token0: getEnv("VITE_TOKEN0"),
  token1: getEnv("VITE_TOKEN1"),
};

export function normalizeChainId(value: string): string {
  const trimmed = value.trim();
  if (!trimmed) {
    return "";
  }
  if (trimmed.startsWith("0x")) {
    return trimmed.toLowerCase();
  }
  const upper = trimmed.toUpperCase();
  if (CHAIN_ID_ALIASES[upper]) {
    return CHAIN_ID_ALIASES[upper].toLowerCase();
  }
  return trimmed;
}

export const expectedChainId = normalizeChainId(getRawEnv("VITE_EXPECTED_CHAIN_ID"));
const proverUrl = getRawEnv("VITE_PROVER_URL");
const rpcUrl = getRawEnv("VITE_RPC_URL");

function isValidFelt(value: string): boolean {
  return FELT_PATTERN.test(value) && !ZERO_FELT_PATTERN.test(value);
}

export function validateConfig(): void {
  const missing: string[] = [];
  if (!zylithConfig.poolAddress) missing.push("VITE_POOL_ADDRESS");
  if (!zylithConfig.shieldedNotesAddress) missing.push("VITE_SHIELDED_NOTES");
  if (!zylithConfig.token0) missing.push("VITE_TOKEN0");
  if (!zylithConfig.token1) missing.push("VITE_TOKEN1");
  if (!expectedChainId) missing.push("VITE_EXPECTED_CHAIN_ID");
  if (!proverUrl) missing.push("VITE_PROVER_URL");
  if (!rpcUrl) missing.push("VITE_RPC_URL");
  if (missing.length > 0) {
    throw new Error(`Missing environment variables: ${missing.join(", ")}`);
  }
  const invalid: string[] = [];
  if (!isValidFelt(zylithConfig.poolAddress)) invalid.push("VITE_POOL_ADDRESS");
  if (!isValidFelt(zylithConfig.shieldedNotesAddress)) {
    invalid.push("VITE_SHIELDED_NOTES");
  }
  if (!isValidFelt(zylithConfig.token0)) invalid.push("VITE_TOKEN0");
  if (!isValidFelt(zylithConfig.token1)) invalid.push("VITE_TOKEN1");
  if (!expectedChainId.startsWith("0x")) invalid.push("VITE_EXPECTED_CHAIN_ID");
  if (zylithConfig.token0 === zylithConfig.token1) {
    invalid.push("VITE_TOKEN0/VITE_TOKEN1 must be different");
  }
  try {
    void new URL(proverUrl);
  } catch {
    invalid.push("VITE_PROVER_URL");
  }
  try {
    void new URL(rpcUrl);
  } catch {
    invalid.push("VITE_RPC_URL");
  }
  if (invalid.length > 0) {
    throw new Error(`Invalid environment variables: ${invalid.join(", ")}`);
  }
}

export const tokenSymbols = {
  token0: "STRK",
  token1: "ETH",
};

export function normalizeHex(value: string): string {
  const prefixed = value.startsWith("0x") ? value : `0x${value}`;
  return prefixed.toLowerCase();
}

export function toFeltHex(value: string | number | bigint): string {
  if (typeof value === "string") {
    if (value.startsWith("0x")) {
      return normalizeHex(value);
    }
    return normalizeHex(BigInt(value).toString(16));
  }
  if (typeof value === "number") {
    return normalizeHex(BigInt(value).toString(16));
  }
  return normalizeHex(value.toString(16));
}

export function serializeMerkleProof(proof: MerklePath): string[] {
  if (proof.path.length !== proof.indices.length) {
    throw new Error("Merkle path mismatch");
  }
  const out: string[] = [];
  out.push(toFeltHex(proof.root));
  out.push(toFeltHex(proof.commitment));
  out.push(toFeltHex(proof.leaf_index));
  out.push(toFeltHex(proof.path.length));
  out.push(...proof.path.map(toFeltHex));
  out.push(toFeltHex(proof.indices.length));
  out.push(...proof.indices.map((value) => (value ? "0x1" : "0x0")));
  return out;
}

export function serializeMerkleProofs(proofs: MerklePath[]): string[] {
  const out = [toFeltHex(proofs.length)];
  for (const proof of proofs) {
    out.push(...serializeMerkleProof(proof));
  }
  return out;
}

export function serializeProofCalldata(tokens: string[]): string[] {
  return tokens.map(toFeltHex);
}

export function splitU256(value: bigint): [string, string] {
  const mask = (BigInt(1) << BigInt(128)) - BigInt(1);
  const low = value & mask;
  const high = value >> BigInt(128);
  return [toFeltHex(low), toFeltHex(high)];
}

export function parseUnits(input: string, decimals = TOKEN_DECIMALS): bigint {
  const normalized = input.trim();
  if (!normalized) {
    throw new Error("Amount is required");
  }
  if (normalized.startsWith("0x")) {
    const value = BigInt(normalized);
    if (value > U128_MAX) {
      throw new Error("Amount exceeds max u128");
    }
    return value;
  }
  const [wholeRaw, fraction = ""] = normalized.split(".");
  if (fraction.length > decimals) {
    throw new Error(`Too many decimal places (max ${decimals})`);
  }
  const whole = wholeRaw === "" ? "0" : wholeRaw;
  const frac = fraction.padEnd(decimals, "0").slice(0, decimals);
  const combined = `${whole}${frac}`;
  const value = BigInt(combined);
  if (value > U128_MAX) {
    throw new Error("Amount exceeds max u128");
  }
  return value;
}

export function formatUnits(value: string | bigint, decimals = TOKEN_DECIMALS): string {
  const amount = typeof value === "bigint" ? value : BigInt(value);
  const base = BigInt(10) ** BigInt(decimals);
  const whole = amount / base;
  const fraction = amount % base;
  const fracStr = fraction.toString().padStart(decimals, "0").replace(/0+$/, "");
  return fracStr.length > 0 ? `${whole.toString()}.${fracStr}` : whole.toString();
}

export function buildApproveCall(
  token: string,
  spender: string,
  amount: bigint,
): Call {
  const [low, high] = splitU256(amount);
  return {
    contractAddress: token,
    entrypoint: "approve",
    calldata: [spender, low, high],
  };
}

export function buildDepositCall(
  tokenId: number,
  proof: string[],
  insertionProof: MerklePath,
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProof(insertionProof),
  ];
  return {
    contractAddress: zylithConfig.shieldedNotesAddress,
    entrypoint: tokenId === 0 ? "deposit_token0" : "deposit_token1",
    calldata,
  };
}

export function buildSwapCall(
  exactOut: boolean,
  proof: string[],
  inputProofs: MerklePath[],
  outputProofs: MerklePath[],
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProofs(inputProofs),
    ...serializeMerkleProofs(outputProofs),
  ];
  return {
    contractAddress: zylithConfig.poolAddress,
    entrypoint: exactOut ? "swap_private_exact_out" : "swap_private",
    calldata,
  };
}

export function buildLiquidityAddCall(
  proof: string[],
  proofsToken0: MerklePath[],
  proofsToken1: MerklePath[],
  proofPosition: MerklePath | null,
  insertProofPosition: MerklePath | null,
  outputProofToken0: MerklePath | null,
  outputProofToken1: MerklePath | null,
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProofs(proofsToken0),
    ...serializeMerkleProofs(proofsToken1),
    ...serializeMerkleProofs(proofPosition ? [proofPosition] : []),
    ...serializeMerkleProofs(insertProofPosition ? [insertProofPosition] : []),
    ...serializeMerkleProofs(outputProofToken0 ? [outputProofToken0] : []),
    ...serializeMerkleProofs(outputProofToken1 ? [outputProofToken1] : []),
  ];
  return {
    contractAddress: zylithConfig.poolAddress,
    entrypoint: "add_liquidity_private",
    calldata,
  };
}

export function buildLiquidityRemoveCall(
  proof: string[],
  proofPosition: MerklePath,
  insertProofPosition: MerklePath | null,
  outputProofToken0: MerklePath | null,
  outputProofToken1: MerklePath | null,
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProof(proofPosition),
    ...serializeMerkleProofs(insertProofPosition ? [insertProofPosition] : []),
    ...serializeMerkleProofs(outputProofToken0 ? [outputProofToken0] : []),
    ...serializeMerkleProofs(outputProofToken1 ? [outputProofToken1] : []),
  ];
  return {
    contractAddress: zylithConfig.poolAddress,
    entrypoint: "remove_liquidity_private",
    calldata,
  };
}

export function buildLiquidityClaimCall(
  proof: string[],
  proofPosition: MerklePath,
  insertProofPosition: MerklePath | null,
  outputProofToken0: MerklePath | null,
  outputProofToken1: MerklePath | null,
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProof(proofPosition),
    ...serializeMerkleProofs(insertProofPosition ? [insertProofPosition] : []),
    ...serializeMerkleProofs(outputProofToken0 ? [outputProofToken0] : []),
    ...serializeMerkleProofs(outputProofToken1 ? [outputProofToken1] : []),
  ];
  return {
    contractAddress: zylithConfig.poolAddress,
    entrypoint: "claim_liquidity_fees_private",
    calldata,
  };
}

export function buildWithdrawCall(
  tokenId: number,
  proof: string[],
  merkleProof: MerklePath,
): Call {
  const calldata = [
    ...serializeProofCalldata(proof),
    ...serializeMerkleProof(merkleProof),
  ];
  return {
    contractAddress: zylithConfig.shieldedNotesAddress,
    entrypoint: tokenId === 0 ? "withdraw_token0" : "withdraw_token1",
    calldata,
  };
}
