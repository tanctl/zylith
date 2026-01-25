export type NoteInput = {
  secret: string;
  nullifier: string;
  amount: string;
  token: string;
};

export type NoteOutput = NoteInput;

export type PositionNoteInput = {
  secret: string;
  nullifier: string;
  tick_lower: number;
  tick_upper: number;
  liquidity: string;
  fee_growth_inside_0: string;
  fee_growth_inside_1: string;
};

export type PositionNoteOutput = PositionNoteInput;

export type MerklePath = {
  token: string;
  root: string;
  commitment: string;
  leaf_index: number;
  path: string[];
  indices: boolean[];
};

export type SwapProofRequest = {
  notes: NoteInput[];
  zero_for_one: boolean;
  exact_out: boolean;
  amount_out?: string;
  sqrt_ratio_limit?: string;
  output_note?: NoteInput;
  change_note?: NoteInput;
};

export type SwapProofResponse = {
  proof: string[];
  input_proofs: MerklePath[];
  output_proofs: MerklePath[];
  output_note?: NoteOutput;
  change_note?: NoteOutput;
  amount_out: string;
  amount_in_consumed: string;
};

export type LiquidityAddProofRequest = {
  token0_notes: NoteInput[];
  token1_notes: NoteInput[];
  position_note?: PositionNoteInput;
  tick_lower: number;
  tick_upper: number;
  liquidity_delta: string;
  output_position_note?: PositionNoteInput;
  output_note_token0?: NoteInput;
  output_note_token1?: NoteInput;
};

export type LiquidityRemoveProofRequest = {
  position_note: PositionNoteInput;
  liquidity_delta: string;
  output_position_note?: PositionNoteInput;
  output_note_token0?: NoteInput;
  output_note_token1?: NoteInput;
};

export type LiquidityClaimProofRequest = {
  position_note: PositionNoteInput;
  output_position_note?: PositionNoteInput;
  output_note_token0?: NoteInput;
  output_note_token1?: NoteInput;
};

export type LiquidityProofResponse = {
  proof: string[];
  proofs_token0: MerklePath[];
  proofs_token1: MerklePath[];
  proof_position?: MerklePath;
  insert_proof_position?: MerklePath;
  output_proof_token0?: MerklePath;
  output_proof_token1?: MerklePath;
  output_note_token0?: NoteOutput;
  output_note_token1?: NoteOutput;
  output_position_note?: PositionNoteOutput;
};

export type WithdrawProofRequest = {
  note: NoteInput;
  token_id: number;
  recipient: string;
  root_index?: number;
  root_hash?: string;
};

export type WithdrawProofResponse = {
  proof: string[];
  merkle_proof: MerklePath;
  commitment: string;
  nullifier: string;
};

export type DepositProofRequest = {
  note: NoteInput;
  token_id: number;
};

export type DepositProofResponse = {
  proof: string[];
  insertion_proof: MerklePath;
  commitment: string;
};

export type PoolConfigResponse = {
  pool_address: string;
  shielded_notes_address: string;
  token0: string;
  token1: string;
  fee: string;
  tick_spacing: string;
  min_sqrt_ratio: string;
  max_sqrt_ratio: string;
  max_input_notes: number;
};

export type SwapQuoteRequest = {
  amount: string;
  zero_for_one: boolean;
  exact_out: boolean;
  sqrt_ratio_limit?: string;
};

export type SwapQuoteResponse = {
  amount_in: string;
  amount_out: string;
  sqrt_price_end: string;
  tick_end: number;
  liquidity_end: string;
  is_limited: boolean;
};

export type LiquidityQuoteRequest = {
  tick_lower: number;
  tick_upper: number;
  liquidity_delta: string;
};

export type LiquidityQuoteResponse = {
  amount0: string;
  amount1: string;
  sqrt_ratio_lower: string;
  sqrt_ratio_upper: string;
};

const PROVER_URL =
  import.meta.env.VITE_PROVER_URL ?? "http://127.0.0.1:8081";
const PROVER_API_KEY = import.meta.env.VITE_PROVER_API_KEY;

function buildHeaders(): HeadersInit {
  const headers: Record<string, string> = {
    "Content-Type": "application/json",
  };
  if (PROVER_API_KEY) {
    headers["x-api-key"] = PROVER_API_KEY;
  }
  return headers;
}

async function postJson<T>(path: string, body: unknown, signal?: AbortSignal): Promise<T> {
  const response = await fetch(`${PROVER_URL}${path}`, {
    method: "POST",
    headers: buildHeaders(),
    body: JSON.stringify(body),
    signal,
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const message =
      typeof payload.error === "string" ? payload.error : response.statusText;
    throw new Error(message);
  }
  return response.json() as Promise<T>;
}

async function getJson<T>(path: string): Promise<T> {
  const response = await fetch(`${PROVER_URL}${path}`, {
    method: "GET",
    headers: buildHeaders(),
  });
  if (!response.ok) {
    const payload = await response.json().catch(() => ({}));
    const message =
      typeof payload.error === "string" ? payload.error : response.statusText;
    throw new Error(message);
  }
  return response.json() as Promise<T>;
}

export const proveSwap = (payload: SwapProofRequest) =>
  postJson<SwapProofResponse>("/proofs/swap", payload);

export const proveLiquidityAdd = (payload: LiquidityAddProofRequest) =>
  postJson<LiquidityProofResponse>("/proofs/liquidity/add", payload);

export const proveLiquidityRemove = (payload: LiquidityRemoveProofRequest) =>
  postJson<LiquidityProofResponse>("/proofs/liquidity/remove", payload);

export const proveLiquidityClaim = (payload: LiquidityClaimProofRequest) =>
  postJson<LiquidityProofResponse>("/proofs/liquidity/claim", payload);

export const proveWithdraw = (payload: WithdrawProofRequest) =>
  postJson<WithdrawProofResponse>("/proofs/withdraw", payload);

export const proveDeposit = (payload: DepositProofRequest) =>
  postJson<DepositProofResponse>("/proofs/deposit", payload);

export const fetchPoolConfig = () =>
  getJson<PoolConfigResponse>("/pool/config");

export const quoteSwap = (payload: SwapQuoteRequest, signal?: AbortSignal) =>
  postJson<SwapQuoteResponse>("/quote/swap", payload, signal);

export const quoteLiquidityAdd = (payload: LiquidityQuoteRequest, signal?: AbortSignal) =>
  postJson<LiquidityQuoteResponse>("/quote/liquidity/add", payload, signal);
