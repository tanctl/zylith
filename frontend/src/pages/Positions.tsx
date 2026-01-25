import { useEffect, useMemo, useRef, useState } from "react";

import { useWallet } from "../components/WalletProvider";
import {
  fetchPoolConfig,
  proveLiquidityAdd,
  proveLiquidityClaim,
  proveLiquidityRemove,
  quoteLiquidityAdd,
  type LiquidityQuoteResponse,
  type PoolConfigResponse,
} from "../lib/prover";
import {
  buildLiquidityAddCall,
  buildLiquidityClaimCall,
  buildLiquidityRemoveCall,
  expectedChainId,
  formatUnits,
  normalizeFelt,
  tokenSymbols,
  zylithConfig,
} from "../lib/zylith";
import {
  createPositionNote,
  createTokenNote,
  loadVaultNotes,
  upsertVaultNotes,
  type PositionNote,
  type TokenNote,
  type VaultNote,
} from "../lib/vault";
import { useDebounce } from "../lib/hooks";

const QUOTE_DEBOUNCE_MS = 300;
const DECIMAL_INPUT_PATTERN = /^\d+$/;
const HEX_INPUT_PATTERN = /^0x[0-9a-fA-F]+$/;
const PENDING_TX_MESSAGE =
  "Transaction not confirmed. Notes remain pending until confirmed.";
type PendingResolution = "accepted" | "rejected";
const U128_MAX = (BigInt(1) << BigInt(128)) - BigInt(1);

function parseLiquidity(input: string): bigint {
  const normalized = input.trim();
  if (!normalized) {
    throw new Error("Liquidity is required");
  }
  if (normalized.startsWith("-")) {
    throw new Error("Liquidity must be greater than zero");
  }
  if (HEX_INPUT_PATTERN.test(normalized)) {
    const value = BigInt(normalized);
    if (value <= BigInt(0)) {
      throw new Error("Liquidity must be greater than zero");
    }
    if (value > U128_MAX) {
      throw new Error("Liquidity exceeds max u128");
    }
    return value;
  }
  if (!DECIMAL_INPUT_PATTERN.test(normalized)) {
    throw new Error("Liquidity must be a whole number");
  }
  if (/^0+$/.test(normalized)) {
    throw new Error("Liquidity must be greater than zero");
  }
  const value = BigInt(normalized);
  if (value > U128_MAX) {
    throw new Error("Liquidity exceeds max u128");
  }
  return value;
}

function pendingTxError(err: unknown): Error {
  const detail = err instanceof Error ? err.message : "";
  return new Error(detail ? `${PENDING_TX_MESSAGE} ${detail}` : PENDING_TX_MESSAGE);
}

function classifyReceiptStatus(receipt: unknown): PendingResolution | "pending" {
  if (!receipt || typeof receipt !== "object") {
    return "pending";
  }
  const payload = receipt as Record<string, unknown>;
  const status = String(payload.status ?? "").toUpperCase();
  const exec = String(payload.execution_status ?? "").toUpperCase();
  const finality = String(payload.finality_status ?? "").toUpperCase();
  if (status.includes("REJECTED") || exec.includes("REVERTED")) {
    return "rejected";
  }
  if (
    status.includes("ACCEPTED") ||
    exec.includes("SUCCEEDED") ||
    finality.includes("ACCEPTED")
  ) {
    return "accepted";
  }
  return "pending";
}

function resolvePendingNotes(
  notes: VaultNote[],
  resolutions: Map<string, PendingResolution>,
): VaultNote[] {
  const next: VaultNote[] = [];
  for (const note of notes) {
    if (note.state !== "pending" || !note.pending_tx) {
      next.push(note);
      continue;
    }
    const resolution = resolutions.get(note.pending_tx);
    if (!resolution) {
      next.push(note);
      continue;
    }
    const action = note.pending_action ?? "spend";
    if (resolution === "accepted") {
      next.push({
        ...note,
        state: action === "receive" ? "unspent" : "spent",
        pending_tx: undefined,
        pending_action: undefined,
      });
    } else if (action === "spend") {
      next.push({
        ...note,
        state: "unspent",
        pending_tx: undefined,
        pending_action: undefined,
      });
    }
  }
  return next;
}

export default function PositionsPage() {
  const wallet = useWallet();
  const [vaultNotes, setVaultNotes] = useState<VaultNote[]>([]);
  const [notesLoaded, setNotesLoaded] = useState(false);
  const [selectedPositionId, setSelectedPositionId] = useState<string | null>(null);
  const [tickLower, setTickLower] = useState("-120");
  const [tickUpper, setTickUpper] = useState("120");
  const [liquidityDelta, setLiquidityDelta] = useState("");
  const [poolConfig, setPoolConfig] = useState<PoolConfigResponse | null>(null);
  const [configError, setConfigError] = useState("");
  const [quote, setQuote] = useState<LiquidityQuoteResponse | null>(null);
  const [quoteError, setQuoteError] = useState("");
  const [quotePending, setQuotePending] = useState(false);
  const [pending, setPending] = useState(false);
  const [error, setError] = useState("");
  const [pendingWarning, setPendingWarning] = useState("");
  const [refreshPending, setRefreshPending] = useState(false);
  const [refreshError, setRefreshError] = useState("");
  const [showAdd, setShowAdd] = useState(false);

  // Debounce inputs for quote requests
  const debouncedLiquidity = useDebounce(liquidityDelta, QUOTE_DEBOUNCE_MS);
  const debouncedTickLower = useDebounce(tickLower, QUOTE_DEBOUNCE_MS);
  const debouncedTickUpper = useDebounce(tickUpper, QUOTE_DEBOUNCE_MS);
  const quoteAbortRef = useRef<AbortController | null>(null);
  const vaultWriteQueue = useRef<Promise<VaultNote[] | null>>(Promise.resolve(null));

  useEffect(() => {
    if (!wallet.vaultKey) {
      setVaultNotes([]);
      setNotesLoaded(false);
      return;
    }
    let cancelled = false;
    loadVaultNotes(wallet.vaultKey)
      .then((notes) => {
        if (!cancelled) {
          setVaultNotes(notes);
          setNotesLoaded(true);
        }
      })
      .catch((err) => {
        if (!cancelled) {
          const message =
            err instanceof Error ? err.message : "Vault unavailable";
          wallet.reportVaultError(message);
          setVaultNotes([]);
          setNotesLoaded(false);
        }
      });
    return () => {
      cancelled = true;
    };
  }, [wallet.vaultKey, wallet.vaultRevision, wallet.reportVaultError]);

  useEffect(() => {
    let cancelled = false;
    fetchPoolConfig()
      .then((config) => {
        if (!cancelled) {
          const envToken0 = normalizeFelt(zylithConfig.token0);
          const envToken1 = normalizeFelt(zylithConfig.token1);
          const envPool = normalizeFelt(zylithConfig.poolAddress);
          const envNotes = normalizeFelt(zylithConfig.shieldedNotesAddress);
          const cfgToken0 = normalizeFelt(config.token0);
          const cfgToken1 = normalizeFelt(config.token1);
          const cfgPool = normalizeFelt(config.pool_address);
          const cfgNotes = normalizeFelt(config.shielded_notes_address);
          if (
            cfgToken0 !== envToken0 ||
            cfgToken1 !== envToken1 ||
            cfgPool !== envPool ||
            cfgNotes !== envNotes
          ) {
            setConfigError(
              "Pool config mismatch. Check token addresses and backend target.",
            );
          } else {
            setConfigError("");
          }
          setPoolConfig(config);
        }
      })
      .catch(() => {
        if (!cancelled) {
          setPoolConfig(null);
        }
      });
    return () => {
      cancelled = true;
    };
  }, []);

  useEffect(() => {
    // Abort any in-flight quote request
    quoteAbortRef.current?.abort();
    quoteAbortRef.current = null;

    if (!showAdd) {
      setQuote(null);
      setQuoteError("");
      setQuotePending(false);
      return;
    }
    if (!debouncedLiquidity.trim()) {
      setQuote(null);
      setQuoteError("");
      setQuotePending(false);
      return;
    }
    const lower = Number(debouncedTickLower);
    const upper = Number(debouncedTickUpper);
    if (!Number.isFinite(lower) || !Number.isFinite(upper)) {
      setQuote(null);
      setQuoteError("Invalid tick bounds");
      setQuotePending(false);
      return;
    }
    if (!Number.isInteger(lower) || !Number.isInteger(upper)) {
      setQuote(null);
      setQuoteError("Ticks must be integers");
      setQuotePending(false);
      return;
    }
    if (lower >= upper) {
      setQuote(null);
      setQuoteError("tick_lower must be less than tick_upper");
      setQuotePending(false);
      return;
    }
    let liquidity: bigint;
    try {
      liquidity = parseLiquidity(debouncedLiquidity);
    } catch (err) {
      setQuote(null);
      setQuoteError(err instanceof Error ? err.message : "Invalid liquidity");
      setQuotePending(false);
      return;
    }

    const controller = new AbortController();
    quoteAbortRef.current = controller;
    setQuotePending(true);
    setQuoteError("");

    quoteLiquidityAdd(
      {
        tick_lower: lower,
        tick_upper: upper,
        liquidity_delta: liquidity.toString(),
      },
      controller.signal,
    )
      .then((response) => {
        if (!controller.signal.aborted) {
          setQuote(response);
        }
      })
      .catch((err) => {
        if (!controller.signal.aborted) {
          setQuote(null);
          if (err instanceof Error && err.name !== "AbortError") {
            setQuoteError(err.message);
          }
        }
      })
      .finally(() => {
        if (!controller.signal.aborted) {
          setQuotePending(false);
        }
      });

    return () => {
      controller.abort();
    };
  }, [debouncedLiquidity, showAdd, debouncedTickLower, debouncedTickUpper]);

  const positions = useMemo(() => {
    return vaultNotes.filter(
      (note): note is PositionNote =>
        note.type === "position" && note.state === "unspent",
    );
  }, [vaultNotes]);

  const pendingNotes = useMemo(
    () => vaultNotes.filter((note) => note.state === "pending"),
    [vaultNotes],
  );

  const selectedPosition = positions.find((pos) => pos.id === selectedPositionId) ?? null;

  useEffect(() => {
    if (selectedPosition) {
      setTickLower(selectedPosition.tick_lower.toString());
      setTickUpper(selectedPosition.tick_upper.toString());
    }
  }, [selectedPosition]);

  const required0Label = useMemo(() => {
    if (!quote) {
      return "—";
    }
    return formatUnits(quote.amount0);
  }, [quote]);

  const required1Label = useMemo(() => {
    if (!quote) {
      return "—";
    }
    return formatUnits(quote.amount1);
  }, [quote]);

  const tickSpacingLabel = useMemo(() => {
    if (!poolConfig) {
      return "—";
    }
    return poolConfig.tick_spacing;
  }, [poolConfig]);

  const maxInputNotes = poolConfig?.max_input_notes ?? 4;

  const persistVaultNotes = async (
    updater: (notes: VaultNote[]) => VaultNote[],
  ) => {
    if (!wallet.vaultKey) {
      throw new Error("Vault not ready");
    }
    const task = async () => {
      try {
        const next = await upsertVaultNotes(wallet.vaultKey, updater);
        setVaultNotes(next);
        return next;
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Vault unavailable";
        wallet.reportVaultError(message);
        throw err;
      }
    };
    const nextPromise = vaultWriteQueue.current.then(task);
    vaultWriteQueue.current = nextPromise.then(
      () => null,
      () => null,
    );
    return nextPromise;
  };

  const applyPendingResolution = async (
    resolutions: Map<string, PendingResolution>,
  ) => {
    if (resolutions.size === 0) {
      return;
    }
    await persistVaultNotes((current) => resolvePendingNotes(current, resolutions));
  };

  const refreshPendingNotes = async () => {
    setRefreshError("");
    if (!wallet.account || !wallet.vaultKey) {
      setRefreshError("Connect your wallet");
      return;
    }
    const pendingTxs = Array.from(
      new Set(
        vaultNotes
          .filter((note) => note.state === "pending" && note.pending_tx)
          .map((note) => note.pending_tx as string),
      ),
    );
    if (pendingTxs.length === 0) {
      setRefreshError("No pending transactions");
      return;
    }
    setRefreshPending(true);
    const resolutions = new Map<string, PendingResolution>();
    let failed = false;
    for (const tx of pendingTxs) {
      try {
        const receipt = await wallet.account.getTransactionReceipt(tx);
        const status = classifyReceiptStatus(receipt);
        if (status === "accepted" || status === "rejected") {
          resolutions.set(tx, status);
        }
      } catch (err) {
        failed = true;
        const message = err instanceof Error ? err.message : "Failed to fetch receipts";
        setRefreshError(message);
      }
    }
    try {
      await applyPendingResolution(resolutions);
      if (!failed && resolutions.size === 0) {
        setRefreshError("No finalized transactions yet");
      }
    } finally {
      setRefreshPending(false);
    }
  };

  const selectTokenNotes = (token: string, required: bigint) => {
    if (required === BigInt(0)) {
      return [];
    }
    const tokenKey = normalizeFelt(token);
    const notes = vaultNotes.filter(
      (note): note is TokenNote =>
        note.type === "token" &&
        normalizeFelt(note.token) === tokenKey &&
        note.state === "unspent",
    );
    const sorted = [...notes].sort(
      (a, b) => (BigInt(b.amount) < BigInt(a.amount) ? -1 : BigInt(b.amount) > BigInt(a.amount) ? 1 : 0),
    );
    const selected: TokenNote[] = [];
    let total = BigInt(0);
    for (const note of sorted) {
      if (selected.length >= maxInputNotes) {
        break;
      }
      selected.push(note);
      total += BigInt(note.amount);
      if (total >= required) {
        break;
      }
    }
    if (total < required) {
      throw new Error("Insufficient shielded balance");
    }
    return selected;
  };

  const handleAdd = async () => {
    setError("");
    setPendingWarning("");
    if (configError) {
      setError(configError);
      return;
    }
    if (!wallet.account || !wallet.vaultKey) {
      setError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setError("Wrong network");
      return;
    }
    if (!liquidityDelta.trim()) {
      setError("Enter liquidity delta");
      return;
    }
    const lower = Number(tickLower);
    const upper = Number(tickUpper);
    if (!Number.isFinite(lower) || !Number.isFinite(upper)) {
      setError("Invalid tick bounds");
      return;
    }
    if (!Number.isInteger(lower) || !Number.isInteger(upper)) {
      setError("Ticks must be integers");
      return;
    }
    if (lower >= upper) {
      setError("tick_lower must be less than tick_upper");
      return;
    }
    if (poolConfig) {
      const spacing = Number(poolConfig.tick_spacing);
      if (spacing > 0 && (lower % spacing !== 0 || upper % spacing !== 0)) {
        setError(`Ticks must align to spacing ${spacing}`);
        return;
      }
    }
    if (!notesLoaded) {
      setError("Vault not ready");
      return;
    }

    let liquidity: bigint;
    try {
      liquidity = parseLiquidity(liquidityDelta);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Invalid liquidity");
      return;
    }
    try {
      setPending(true);
      const quoteResult = await quoteLiquidityAdd({
        tick_lower: lower,
        tick_upper: upper,
        liquidity_delta: liquidity.toString(),
      });
      const required0 = BigInt(quoteResult.amount0);
      const required1 = BigInt(quoteResult.amount1);
      const token0Notes = selectTokenNotes(zylithConfig.token0, required0);
      const token1Notes = selectTokenNotes(zylithConfig.token1, required1);
      const result = await proveLiquidityAdd({
        token0_notes: token0Notes.map((note) => ({
          secret: note.secret,
          nullifier: note.nullifier,
          amount: note.amount,
          token: note.token,
        })),
        token1_notes: token1Notes.map((note) => ({
          secret: note.secret,
          nullifier: note.nullifier,
          amount: note.amount,
          token: note.token,
        })),
        position_note: selectedPosition
          ? {
            secret: selectedPosition.secret,
            nullifier: selectedPosition.nullifier,
            tick_lower: selectedPosition.tick_lower,
            tick_upper: selectedPosition.tick_upper,
            liquidity: selectedPosition.liquidity,
            fee_growth_inside_0: selectedPosition.fee_growth_inside_0,
            fee_growth_inside_1: selectedPosition.fee_growth_inside_1,
          }
          : undefined,
        tick_lower: lower,
        tick_upper: upper,
        liquidity_delta: liquidity.toString(),
      });

      const call = buildLiquidityAddCall(
        result.proof,
        result.proofs_token0,
        result.proofs_token1,
        result.proof_position ?? null,
        result.insert_proof_position ?? null,
        result.output_proof_token0 ?? null,
        result.output_proof_token1 ?? null,
      );
      const { transaction_hash } = await wallet.account.execute([call]);
      const pendingOutputs: VaultNote[] = [];
      if (result.output_note_token0) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token0.token,
            result.output_note_token0.amount,
            result.output_note_token0.secret,
            result.output_note_token0.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_note_token1) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token1.token,
            result.output_note_token1.amount,
            result.output_note_token1.secret,
            result.output_note_token1.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_position_note) {
        pendingOutputs.push(
          createPositionNote({
            secret: result.output_position_note.secret,
            nullifier: result.output_position_note.nullifier,
            tick_lower: result.output_position_note.tick_lower,
            tick_upper: result.output_position_note.tick_upper,
            liquidity: result.output_position_note.liquidity,
            fee_growth_inside_0: result.output_position_note.fee_growth_inside_0,
            fee_growth_inside_1: result.output_position_note.fee_growth_inside_1,
            state: "pending",
            pending_tx: transaction_hash,
            pending_action: "receive",
          }),
        );
      }
      await persistVaultNotes((current): VaultNote[] => {
        const spentIds = new Set([
          ...token0Notes.map((note) => note.id),
          ...token1Notes.map((note) => note.id),
          ...(selectedPosition ? [selectedPosition.id] : []),
        ]);
        const next = current.map((note) =>
          spentIds.has(note.id)
            ? {
              ...note,
              state: "pending" as const,
              pending_tx: transaction_hash,
              pending_action: "spend" as const,
            }
            : note,
        );
        return [...next, ...pendingOutputs];
      });

      try {
        const receipt = await wallet.account.waitForTransaction(transaction_hash);
        const status = classifyReceiptStatus(receipt);
        if (status === "accepted") {
          await applyPendingResolution(
            new Map([[transaction_hash, "accepted"]]),
          );
          setLiquidityDelta("");
          setShowAdd(false);
        } else if (status === "rejected") {
          await applyPendingResolution(
            new Map([[transaction_hash, "rejected"]]),
          );
          setError("Transaction reverted");
          return;
        } else {
          setPendingWarning(PENDING_TX_MESSAGE);
          return;
        }
      } catch (err) {
        setPendingWarning(pendingTxError(err).message);
        return;
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Liquidity add failed");
    } finally {
      setPending(false);
    }
  };

  const handleRemove = async () => {
    setError("");
    setPendingWarning("");
    if (configError) {
      setError(configError);
      return;
    }
    if (!wallet.account || !wallet.vaultKey) {
      setError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setError("Wrong network");
      return;
    }
    if (!selectedPosition) {
      setError("Select a position");
      return;
    }
    if (!liquidityDelta.trim()) {
      setError("Enter liquidity delta");
      return;
    }
    const positionLiquidity = BigInt(selectedPosition.liquidity);
    let liquidity: bigint;
    try {
      liquidity = parseLiquidity(liquidityDelta);
    } catch (err) {
      setError(err instanceof Error ? err.message : "Invalid liquidity");
      return;
    }
    if (liquidity > positionLiquidity) {
      setError("Liquidity delta exceeds position liquidity");
      return;
    }
    try {
      setPending(true);
      const result = await proveLiquidityRemove({
        position_note: {
          secret: selectedPosition.secret,
          nullifier: selectedPosition.nullifier,
          tick_lower: selectedPosition.tick_lower,
          tick_upper: selectedPosition.tick_upper,
          liquidity: selectedPosition.liquidity,
          fee_growth_inside_0: selectedPosition.fee_growth_inside_0,
          fee_growth_inside_1: selectedPosition.fee_growth_inside_1,
        },
        liquidity_delta: liquidity.toString(),
      });

      if (!result.proof_position) {
        throw new Error("Missing position proof");
      }

      const call = buildLiquidityRemoveCall(
        result.proof,
        result.proof_position,
        result.insert_proof_position ?? null,
        result.output_proof_token0 ?? null,
        result.output_proof_token1 ?? null,
      );
      const { transaction_hash } = await wallet.account.execute([call]);
      const pendingOutputs: VaultNote[] = [];
      if (result.output_note_token0) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token0.token,
            result.output_note_token0.amount,
            result.output_note_token0.secret,
            result.output_note_token0.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_note_token1) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token1.token,
            result.output_note_token1.amount,
            result.output_note_token1.secret,
            result.output_note_token1.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_position_note) {
        pendingOutputs.push(
          createPositionNote({
            secret: result.output_position_note.secret,
            nullifier: result.output_position_note.nullifier,
            tick_lower: result.output_position_note.tick_lower,
            tick_upper: result.output_position_note.tick_upper,
            liquidity: result.output_position_note.liquidity,
            fee_growth_inside_0: result.output_position_note.fee_growth_inside_0,
            fee_growth_inside_1: result.output_position_note.fee_growth_inside_1,
            state: "pending",
            pending_tx: transaction_hash,
            pending_action: "receive",
          }),
        );
      }
      await persistVaultNotes((current): VaultNote[] =>
        [
          ...current.map((note) =>
            note.id === selectedPosition.id
              ? {
                ...note,
                state: "pending" as const,
                pending_tx: transaction_hash,
                pending_action: "spend" as const,
              }
              : note,
          ),
          ...pendingOutputs,
        ],
      );
      try {
        const receipt = await wallet.account.waitForTransaction(transaction_hash);
        const status = classifyReceiptStatus(receipt);
        if (status === "accepted") {
          await applyPendingResolution(
            new Map([[transaction_hash, "accepted"]]),
          );
          setLiquidityDelta("");
        } else if (status === "rejected") {
          await applyPendingResolution(
            new Map([[transaction_hash, "rejected"]]),
          );
          setError("Transaction reverted");
          return;
        } else {
          setPendingWarning(PENDING_TX_MESSAGE);
          return;
        }
      } catch (err) {
        setPendingWarning(pendingTxError(err).message);
        return;
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Liquidity remove failed");
    } finally {
      setPending(false);
    }
  };

  const handleClaim = async () => {
    setError("");
    setPendingWarning("");
    if (configError) {
      setError(configError);
      return;
    }
    if (!wallet.account || !wallet.vaultKey) {
      setError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setError("Wrong network");
      return;
    }
    if (!selectedPosition) {
      setError("Select a position");
      return;
    }
    try {
      setPending(true);
      const result = await proveLiquidityClaim({
        position_note: {
          secret: selectedPosition.secret,
          nullifier: selectedPosition.nullifier,
          tick_lower: selectedPosition.tick_lower,
          tick_upper: selectedPosition.tick_upper,
          liquidity: selectedPosition.liquidity,
          fee_growth_inside_0: selectedPosition.fee_growth_inside_0,
          fee_growth_inside_1: selectedPosition.fee_growth_inside_1,
        },
      });

      if (!result.proof_position) {
        throw new Error("Missing position proof");
      }

      const call = buildLiquidityClaimCall(
        result.proof,
        result.proof_position,
        result.insert_proof_position ?? null,
        result.output_proof_token0 ?? null,
        result.output_proof_token1 ?? null,
      );
      const { transaction_hash } = await wallet.account.execute([call]);
      const pendingOutputs: VaultNote[] = [];
      if (result.output_note_token0) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token0.token,
            result.output_note_token0.amount,
            result.output_note_token0.secret,
            result.output_note_token0.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_note_token1) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note_token1.token,
            result.output_note_token1.amount,
            result.output_note_token1.secret,
            result.output_note_token1.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.output_position_note) {
        pendingOutputs.push(
          createPositionNote({
            secret: result.output_position_note.secret,
            nullifier: result.output_position_note.nullifier,
            tick_lower: result.output_position_note.tick_lower,
            tick_upper: result.output_position_note.tick_upper,
            liquidity: result.output_position_note.liquidity,
            fee_growth_inside_0: result.output_position_note.fee_growth_inside_0,
            fee_growth_inside_1: result.output_position_note.fee_growth_inside_1,
            state: "pending",
            pending_tx: transaction_hash,
            pending_action: "receive",
          }),
        );
      }
      await persistVaultNotes((current): VaultNote[] =>
        [
          ...current.map((note) =>
            note.id === selectedPosition.id
              ? {
                ...note,
                state: "pending" as const,
                pending_tx: transaction_hash,
                pending_action: "spend" as const,
              }
              : note,
          ),
          ...pendingOutputs,
        ],
      );
      try {
        const receipt = await wallet.account.waitForTransaction(transaction_hash);
        const status = classifyReceiptStatus(receipt);
        if (status === "accepted") {
          await applyPendingResolution(
            new Map([[transaction_hash, "accepted"]]),
          );
        } else if (status === "rejected") {
          await applyPendingResolution(
            new Map([[transaction_hash, "rejected"]]),
          );
          setError("Transaction reverted");
          return;
        } else {
          setPendingWarning(PENDING_TX_MESSAGE);
          return;
        }
      } catch (err) {
        setPendingWarning(pendingTxError(err).message);
        return;
      }
    } catch (err) {
      setError(err instanceof Error ? err.message : "Claim failed");
    } finally {
      setPending(false);
    }
  };

  return (
    <div className="space-y-4">
      {configError && (
        <div className="surface-1 edge-subtle p-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-red-300">
            {configError}
          </div>
        </div>
      )}
      {pendingNotes.length > 0 && (
        <div className="surface-0 inner-highlight p-3">
          <div className="flex items-center justify-between gap-2">
            <div className="text-[10px] uppercase tracking-[0.15em] text-zylith-text-tertiary">
              Pending notes: {pendingNotes.length}. Await confirmations.
            </div>
            <button
              type="button"
              onClick={refreshPendingNotes}
              disabled={refreshPending}
              className="
                px-2 py-1 text-[9px] font-semibold uppercase tracking-[0.12em]
                text-zylith-text-primary
                surface-2 edge-subtle
                transition-all duration-300 ease-heavy
                hover:edge-medium
                disabled:opacity-40 disabled:cursor-not-allowed
              "
            >
              {refreshPending ? "Checking..." : "Refresh"}
            </button>
          </div>
          {refreshError && (
            <div className="text-[10px] uppercase tracking-[0.12em] text-amber-300 mt-2">
              {refreshError}
            </div>
          )}
        </div>
      )}
      {pendingWarning && (
        <div className="surface-1 edge-subtle p-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-amber-300">
            {pendingWarning}
          </div>
        </div>
      )}
      <div className="flex items-center justify-between">
        <div>
          <h1 className="text-lg font-medium tracking-tight text-zylith-text-primary">
            Positions
          </h1>
          <p className="text-[10px] uppercase tracking-[0.1em] text-zylith-text-tertiary mt-0.5">
            Shielded LP • {positions.length} Active
          </p>
        </div>
        <button
          onClick={() => {
            setShowAdd((value) => !value);
            setError("");
          }}
          className="
            px-3 py-2 text-[10px] font-semibold uppercase tracking-[0.12em]
            text-zylith-text-primary
            surface-2 accent-inner cut-diagonal
            transition-all duration-400 ease-heavy
            hover:accent-focus
          "
        >
          {showAdd ? "Close" : "New Position"}
        </button>
      </div>

      <div className="space-y-2">
        {positions.map((pos) => (
          <button
            key={pos.id}
            onClick={() => setSelectedPositionId(pos.id)}
            className="
              w-full text-left
              surface-1 inner-highlight
              transition-all duration-400 ease-heavy
              hover:surface-2 hover:edge-medium
              group
            "
          >
            <div className="flex items-center justify-between px-4 py-2.5 border-b border-zylith-edge-subtle/20">
              <div className="flex items-center gap-3">
                <span className="font-mono text-[10px] text-zylith-text-tertiary">
                  {pos.id.slice(0, 6)}…
                </span>
                <span className="text-sm font-medium text-zylith-text-primary">
                  {tokenSymbols.token0} / {tokenSymbols.token1}
                </span>
              </div>
              <div
                className={`px-2 py-0.5 text-[9px] font-medium uppercase tracking-[0.1em] ${selectedPosition?.id === pos.id
                  ? "status-active text-zylith-text-primary"
                  : "status-inactive text-zylith-text-tertiary"
                  }`}
              >
                {selectedPosition?.id === pos.id ? "Selected" : "Select"}
              </div>
            </div>
            <div className="grid grid-cols-4 gap-px bg-zylith-edge-subtle/10">
              <div className="surface-0 px-3 py-2.5">
                <div className="text-[9px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-1">
                  Range
                </div>
                <div className="font-mono text-[11px] text-zylith-text-secondary">
                  {pos.tick_lower} — {pos.tick_upper}
                </div>
              </div>
              <div className="surface-0 px-3 py-2.5">
                <div className="text-[9px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-1">
                  Liquidity
                </div>
                <div className="font-mono text-[11px] text-zylith-text-primary">
                  {pos.liquidity}
                </div>
              </div>
              <div className="surface-0 px-3 py-2.5">
                <div className="text-[9px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-1">
                  Token0
                </div>
                <div className="font-mono text-[11px] text-zylith-text-secondary">
                  {formatUnits(balanceForToken(vaultNotes, zylithConfig.token0))}
                </div>
              </div>
              <div className="surface-0 px-3 py-2.5">
                <div className="text-[9px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-1">
                  Token1
                </div>
                <div className="font-mono text-[11px] text-zylith-text-secondary">
                  {formatUnits(balanceForToken(vaultNotes, zylithConfig.token1))}
                </div>
              </div>
            </div>
          </button>
        ))}
      </div>

      {positions.length === 0 && (
        <div className="surface-1 inner-highlight p-8 text-center">
          <p className="text-[11px] uppercase tracking-[0.1em] text-zylith-text-tertiary">
            No positions found
          </p>
        </div>
      )}

      <div className="surface-1 edge-subtle p-4 space-y-3">
        <div className="text-[10px] uppercase tracking-[0.15em] text-zylith-text-tertiary">
          {showAdd ? "Add Liquidity" : "Manage Position"}
        </div>
        {showAdd ? (
          <div className="space-y-3">
            <div className="grid grid-cols-3 gap-2">
              <input
                value={tickLower}
                onChange={(event) => setTickLower(event.target.value)}
                placeholder="tick_lower"
                className="surface-2 inner-highlight px-3 py-2 font-mono text-zylith-text-primary outline-none"
                disabled={!!selectedPosition}
              />
              <input
                value={tickUpper}
                onChange={(event) => setTickUpper(event.target.value)}
                placeholder="tick_upper"
                className="surface-2 inner-highlight px-3 py-2 font-mono text-zylith-text-primary outline-none"
                disabled={!!selectedPosition}
              />
              <input
                value={liquidityDelta}
                onChange={(event) => setLiquidityDelta(event.target.value)}
                placeholder="liquidity_delta"
                className="surface-2 inner-highlight px-3 py-2 font-mono text-zylith-text-primary outline-none"
              />
            </div>
            <div className="surface-0 inner-highlight p-2.5 space-y-1.5">
              <div className="flex items-center justify-between text-[10px]">
                <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">
                  Tick Spacing
                </span>
                <span className="font-mono text-zylith-text-secondary">
                  {tickSpacingLabel}
                </span>
              </div>
              <div className="flex items-center justify-between text-[10px]">
                <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">
                  Required {tokenSymbols.token0}
                </span>
                <span className="font-mono text-zylith-text-secondary">
                  {required0Label}
                </span>
              </div>
              <div className="flex items-center justify-between text-[10px]">
                <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">
                  Required {tokenSymbols.token1}
                </span>
                <span className="font-mono text-zylith-text-secondary">
                  {required1Label}
                </span>
              </div>
              <div className="flex items-center justify-between text-[10px]">
                <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">
                  Quote
                </span>
                <span className="font-mono text-zylith-text-tertiary">
                  {quotePending ? "..." : quote ? "OK" : "—"}
                </span>
              </div>
              {quoteError && (
                <div className="text-[10px] text-amber-300 uppercase tracking-[0.1em]">
                  {quoteError}
                </div>
              )}
            </div>
            <button
              className="
                w-full py-2
                text-[10px] font-semibold uppercase tracking-[0.15em]
                text-zylith-text-primary
                surface-2 accent-inner cut-diagonal
                transition-all duration-600 ease-heavy
                hover:accent-focus
                disabled:opacity-40 disabled:cursor-not-allowed
              "
              onClick={wallet.account ? handleAdd : wallet.connect}
              disabled={pending || (!notesLoaded && !!wallet.account) || !!configError}
            >
              {pending ? "Working..." : "Generate Add Proof"}
            </button>
          </div>
        ) : (
          <div className="space-y-3">
            <input
              value={liquidityDelta}
              onChange={(event) => setLiquidityDelta(event.target.value)}
              placeholder="liquidity_delta"
              className="surface-2 inner-highlight px-3 py-2 font-mono text-zylith-text-primary outline-none"
            />
            <div className="grid grid-cols-2 gap-2">
              <button
                className="
                  w-full py-2
                  text-[10px] font-semibold uppercase tracking-[0.15em]
                  text-zylith-text-primary
                  surface-2 accent-inner cut-diagonal
                  transition-all duration-600 ease-heavy
                  hover:accent-focus
                  disabled:opacity-40 disabled:cursor-not-allowed
                "
                onClick={wallet.account ? handleRemove : wallet.connect}
                disabled={pending || (!notesLoaded && !!wallet.account) || !!configError}
              >
                {pending ? "Working..." : "Remove Liquidity"}
              </button>
              <button
                className="
                  w-full py-2
                  text-[10px] font-semibold uppercase tracking-[0.15em]
                  text-zylith-text-primary
                  surface-2 accent-inner cut-diagonal
                  transition-all duration-600 ease-heavy
                  hover:accent-focus
                  disabled:opacity-40 disabled:cursor-not-allowed
                "
                onClick={wallet.account ? handleClaim : wallet.connect}
                disabled={pending || (!notesLoaded && !!wallet.account) || !!configError}
              >
                {pending ? "Working..." : "Claim Fees"}
              </button>
            </div>
          </div>
        )}
        {error && (
          <div className="text-[10px] text-red-400 uppercase tracking-[0.1em]">
            {error}
          </div>
        )}
      </div>

    </div>
  );
}

function balanceForToken(notes: VaultNote[], token: string): bigint {
  const tokenKey = normalizeFelt(token);
  let total = BigInt(0);
  for (const note of notes) {
    if (
      note.type === "token" &&
      normalizeFelt(note.token) === tokenKey &&
      note.state === "unspent"
    ) {
      total += BigInt(note.amount);
    }
  }
  return total;
}
