import { useEffect, useMemo, useRef, useState } from "react";

import { useWallet } from "../components/WalletProvider";
import {
  fetchPoolConfig,
  proveDeposit,
  proveSwap,
  proveWithdraw,
  quoteSwap,
  type PoolConfigResponse,
} from "../lib/prover";
import {
  buildApproveCall,
  buildDepositCall,
  buildSwapCall,
  buildWithdrawCall,
  expectedChainId,
  formatUnits,
  parseUnits,
  tokenSymbols,
  zylithConfig,
} from "../lib/zylith";
import {
  createTokenNote,
  generateSecretHex,
  loadVaultNotes,
  upsertVaultNotes,
  type TokenNote,
  type VaultNote,
} from "../lib/vault";
import { useDebounce } from "../lib/hooks";

const QUOTE_DEBOUNCE_MS = 300;
const DECIMAL_INPUT_PATTERN = /^(\d+(\.\d+)?|\.\d+)$/;
const HEX_INPUT_PATTERN = /^0x[0-9a-fA-F]+$/;
const MAX_DECIMALS = 18;
const PENDING_TX_MESSAGE =
  "Transaction not confirmed. Notes remain pending until confirmed.";
type PendingResolution = "accepted" | "rejected";

function validateAmountInput(value: string): string | null {
  const raw = value.trim();
  if (!raw) {
    return "Enter an amount";
  }
  if (raw.startsWith("-")) {
    return "Amount must be greater than zero";
  }
  if (HEX_INPUT_PATTERN.test(raw)) {
    return BigInt(raw) > BigInt(0) ? null : "Amount must be greater than zero";
  }
  const normalized = raw.startsWith(".") ? `0${raw}` : raw;
  if (!DECIMAL_INPUT_PATTERN.test(normalized)) {
    return "Enter a valid amount";
  }
  const fraction = normalized.split(".")[1] ?? "";
  if (fraction.length > MAX_DECIMALS) {
    return `Max ${MAX_DECIMALS} decimals`;
  }
  const digits = normalized.replace(".", "");
  if (/^0+$/.test(digits)) {
    return "Amount must be greater than zero";
  }
  return null;
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

function buildSqrtRatioLimit(
  sqrtEnd: bigint | null,
  zeroForOne: boolean,
  slippageBps: number | null,
  poolConfig: PoolConfigResponse | null,
): string | null {
  if (!sqrtEnd || slippageBps === null) {
    return null;
  }
  const bps = BigInt(slippageBps);
  const base = BigInt(10_000);
  const factor = zeroForOne ? base - bps : base + bps;
  if (factor <= BigInt(0)) {
    return null;
  }
  let limit = (sqrtEnd * factor) / base;
  if (poolConfig) {
    const min = BigInt(poolConfig.min_sqrt_ratio);
    const max = BigInt(poolConfig.max_sqrt_ratio);
    if (limit < min) {
      limit = min;
    }
    if (limit > max) {
      limit = max;
    }
  }
  return `0x${limit.toString(16)}`;
}

export default function SwapPage() {
  const wallet = useWallet();
  const [vaultNotes, setVaultNotes] = useState<VaultNote[]>([]);
  const [notesLoaded, setNotesLoaded] = useState(false);
  const [fromAmount, setFromAmount] = useState("");
  const [depositAmount, setDepositAmount] = useState("");
  const [zeroForOne, setZeroForOne] = useState(true);
  const [depositTokenId, setDepositTokenId] = useState<0 | 1>(0);
  const [slippage, setSlippage] = useState("0.5");
  const [quoteOut, setQuoteOut] = useState<bigint | null>(null);
  const [quoteSqrtEnd, setQuoteSqrtEnd] = useState<bigint | null>(null);
  const [quoteForAmount, setQuoteForAmount] = useState<string | null>(null);
  const [quotePending, setQuotePending] = useState(false);
  const [quoteError, setQuoteError] = useState("");
  const [poolConfig, setPoolConfig] = useState<PoolConfigResponse | null>(null);
  const [configError, setConfigError] = useState("");
  const [swapPending, setSwapPending] = useState(false);
  const [swapError, setSwapError] = useState("");
  const [depositPending, setDepositPending] = useState(false);
  const [depositError, setDepositError] = useState("");
  const [withdrawTokenId, setWithdrawTokenId] = useState<0 | 1>(0);
  const [withdrawNoteId, setWithdrawNoteId] = useState<string | null>(null);
  const [withdrawPending, setWithdrawPending] = useState(false);
  const [withdrawError, setWithdrawError] = useState("");
  const [pendingWarning, setPendingWarning] = useState("");
  const [refreshPending, setRefreshPending] = useState(false);
  const [refreshError, setRefreshError] = useState("");

  // Debounce the input amount for quote requests
  const debouncedFromAmount = useDebounce(fromAmount, QUOTE_DEBOUNCE_MS);
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
          const envToken0 = zylithConfig.token0.toLowerCase();
          const envToken1 = zylithConfig.token1.toLowerCase();
          const envPool = zylithConfig.poolAddress.toLowerCase();
          const envNotes = zylithConfig.shieldedNotesAddress.toLowerCase();
          const cfgToken0 = config.token0.toLowerCase();
          const cfgToken1 = config.token1.toLowerCase();
          const cfgPool = config.pool_address.toLowerCase();
          const cfgNotes = config.shielded_notes_address.toLowerCase();
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

    if (!debouncedFromAmount.trim()) {
      setQuoteOut(null);
      setQuoteSqrtEnd(null);
      setQuoteForAmount(null);
      setQuoteError("");
      setQuotePending(false);
      return;
    }

    const validationError = validateAmountInput(debouncedFromAmount);
    if (validationError) {
      setQuotePending(false);
      setQuoteOut(null);
      setQuoteSqrtEnd(null);
      setQuoteForAmount(null);
      setQuoteError(validationError);
      return;
    }
    let amountIn: bigint;
    try {
      amountIn = parseUnits(debouncedFromAmount);
    } catch (err) {
      setQuotePending(false);
      setQuoteOut(null);
      setQuoteSqrtEnd(null);
      setQuoteForAmount(null);
      setQuoteError(err instanceof Error ? err.message : "Invalid amount");
      return;
    }
    if (amountIn <= BigInt(0)) {
      setQuotePending(false);
      setQuoteOut(null);
      setQuoteSqrtEnd(null);
      setQuoteForAmount(null);
      setQuoteError("Amount must be greater than zero");
      return;
    }
    const amountInLabel = amountIn.toString();

    const controller = new AbortController();
    quoteAbortRef.current = controller;
    setQuotePending(true);
    setQuoteError("");

    quoteSwap(
      {
        amount: amountIn.toString(),
        zero_for_one: zeroForOne,
        exact_out: false,
      },
      controller.signal,
    )
      .then((response) => {
        if (!controller.signal.aborted) {
          setQuoteOut(BigInt(response.amount_out));
          setQuoteSqrtEnd(BigInt(response.sqrt_price_end));
          setQuoteForAmount(amountInLabel);
        }
      })
      .catch((err) => {
        if (!controller.signal.aborted) {
          setQuoteOut(null);
          setQuoteSqrtEnd(null);
          setQuoteForAmount(null);
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
  }, [debouncedFromAmount, zeroForOne]);

  const tokenIn = zeroForOne ? zylithConfig.token0 : zylithConfig.token1;
  const tokenOut = zeroForOne ? zylithConfig.token1 : zylithConfig.token0;
  const tokenInKey = tokenIn.toLowerCase();
  const tokenOutKey = tokenOut.toLowerCase();
  const symbolIn = zeroForOne ? tokenSymbols.token0 : tokenSymbols.token1;
  const symbolOut = zeroForOne ? tokenSymbols.token1 : tokenSymbols.token0;
  const withdrawTokenAddress =
    withdrawTokenId === 0 ? zylithConfig.token0 : zylithConfig.token1;
  const withdrawTokenKey = withdrawTokenAddress.toLowerCase();

  const balances = useMemo(() => {
    const token0Key = zylithConfig.token0.toLowerCase();
    const token1Key = zylithConfig.token1.toLowerCase();
    const totals: Record<string, bigint> = {
      [token0Key]: BigInt(0),
      [token1Key]: BigInt(0),
    };
    for (const note of vaultNotes) {
      if (note.type === "token" && note.state === "unspent") {
        const amount = BigInt(note.amount);
        const key = note.token.toLowerCase();
        totals[key] = (totals[key] ?? BigInt(0)) + amount;
      }
    }
    return totals;
  }, [vaultNotes]);

  const balanceIn = balances[tokenInKey] ?? BigInt(0);
  const balanceOut = balances[tokenOutKey] ?? BigInt(0);
  const pendingNotes = useMemo(
    () => vaultNotes.filter((note) => note.state === "pending"),
    [vaultNotes],
  );

  const withdrawNotes = useMemo(() => {
    return vaultNotes.filter(
      (note): note is TokenNote =>
        note.type === "token" &&
        note.token.toLowerCase() === withdrawTokenKey &&
        note.state === "unspent",
    );
  }, [vaultNotes, withdrawTokenKey]);

  useEffect(() => {
    if (withdrawNotes.length === 0) {
      setWithdrawNoteId(null);
    } else if (!withdrawNoteId || !withdrawNotes.some((note) => note.id === withdrawNoteId)) {
      setWithdrawNoteId(withdrawNotes[0].id);
    }
  }, [withdrawNotes, withdrawNoteId]);

  const slippageError = useMemo(() => {
    const raw = slippage.trim();
    if (!raw) {
      return "Enter slippage";
    }
    if (raw.startsWith("-")) {
      return "Slippage must be 0-50%";
    }
    const value = Number(raw);
    if (!Number.isFinite(value)) {
      return "Enter a valid slippage";
    }
    if (value < 0 || value > 50) {
      return "Slippage must be 0-50%";
    }
    return null;
  }, [slippage]);

  const slippageBps = useMemo(() => {
    if (slippageError) {
      return null;
    }
    return Math.round(Number(slippage) * 100);
  }, [slippage, slippageError]);

  const minOut = useMemo(() => {
    if (quoteOut === null || slippageBps === null) {
      return null;
    }
    const bps = BigInt(slippageBps);
    const base = BigInt(10_000);
    const factor = base - bps;
    return (quoteOut * factor) / base;
  }, [quoteOut, slippageBps]);

  const sqrtRatioLimit = useMemo(() => {
    return buildSqrtRatioLimit(quoteSqrtEnd, zeroForOne, slippageBps, poolConfig);
  }, [poolConfig, quoteSqrtEnd, slippageBps, zeroForOne]);

  const quoteOutLabel = useMemo(() => {
    if (quoteOut === null) {
      return "—";
    }
    return formatUnits(quoteOut);
  }, [quoteOut]);

  const minOutLabel = useMemo(() => {
    if (minOut === null) {
      return "—";
    }
    return formatUnits(minOut);
  }, [minOut]);

  const feeLabel = useMemo(() => {
    if (!poolConfig) {
      return "—";
    }
    const fee = Number(poolConfig.fee) / 10_000;
    return `${fee.toFixed(2)}%`;
  }, [poolConfig]);

  const swapLabel = useMemo(() => {
    if (!wallet.account) return "Connect Wallet";
    if (!notesLoaded) return "Loading vault...";
    if (swapPending) return "Swapping...";
    return "Swap";
  }, [wallet.account, notesLoaded, swapPending]);

  const depositLabel = useMemo(() => {
    if (!wallet.account) return "Connect Wallet";
    if (!notesLoaded) return "Loading vault...";
    if (depositPending) return "Depositing...";
    return "Deposit";
  }, [wallet.account, notesLoaded, depositPending]);

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

  const selectNotes = (amount: bigint, token: string) => {
    const tokenKey = token.toLowerCase();
    const candidates = vaultNotes.filter(
      (note): note is TokenNote =>
        note.type === "token" &&
        note.token.toLowerCase() === tokenKey &&
        note.state === "unspent",
    );
    const sorted = [...candidates].sort(
      (a, b) => (BigInt(b.amount) < BigInt(a.amount) ? -1 : BigInt(b.amount) > BigInt(a.amount) ? 1 : 0),
    );
    const selected: TokenNote[] = [];
    let total = BigInt(0);
    for (const note of sorted) {
      if (selected.length >= maxInputNotes) break;
      selected.push(note);
      total += BigInt(note.amount);
      if (total >= amount) break;
    }
    if (total < amount) {
      throw new Error("Insufficient shielded balance");
    }
    return selected;
  };

  const handleSwap = async () => {
    setSwapError("");
    setPendingWarning("");
    if (configError) {
      setSwapError(configError);
      return;
    }
    if (slippageError) {
      setSwapError(slippageError);
      return;
    }
    if (quoteOut === null || !quoteSqrtEnd) {
      setSwapError("Quote required before swapping");
      return;
    }
    if (!wallet.account || !wallet.vaultKey) {
      setSwapError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setSwapError("Wrong network");
      return;
    }
    const validationError = validateAmountInput(fromAmount);
    if (validationError) {
      setSwapError(validationError);
      return;
    }
    try {
      const amountIn = parseUnits(fromAmount);
      const amountInLabel = amountIn.toString();
      if (amountIn <= BigInt(0)) {
        setSwapError("Amount must be greater than zero");
        return;
      }
      const selectedNotes = selectNotes(amountIn, tokenIn);
      setSwapPending(true);
      let quoteOutLocal = quoteOut;
      let quoteSqrtLocal = quoteSqrtEnd;
      if (
        quoteForAmount !== amountInLabel ||
        quoteOutLocal === null ||
        quoteSqrtLocal === null
      ) {
        const quote = await quoteSwap({
          amount: amountInLabel,
          zero_for_one: zeroForOne,
          exact_out: false,
        });
        quoteOutLocal = BigInt(quote.amount_out);
        quoteSqrtLocal = BigInt(quote.sqrt_price_end);
        setQuoteOut(quoteOutLocal);
        setQuoteSqrtEnd(quoteSqrtLocal);
        setQuoteForAmount(amountInLabel);
      }
      const sqrtLimit = buildSqrtRatioLimit(
        quoteSqrtLocal,
        zeroForOne,
        slippageBps,
        poolConfig,
      );
      const result = await proveSwap({
        notes: selectedNotes.map((note) => ({
          secret: note.secret,
          nullifier: note.nullifier,
          amount: note.amount,
          token: note.token,
        })),
        zero_for_one: zeroForOne,
        exact_out: false,
        sqrt_ratio_limit: sqrtLimit ?? undefined,
      });

      const call = buildSwapCall(
        false,
        result.proof,
        result.input_proofs,
        result.output_proofs,
      );
      const { transaction_hash } = await wallet.account.execute([call]);
      const pendingOutputs: TokenNote[] = [];
      if (result.output_note) {
        pendingOutputs.push(
          createTokenNote(
            result.output_note.token,
            result.output_note.amount,
            result.output_note.secret,
            result.output_note.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      if (result.change_note) {
        pendingOutputs.push(
          createTokenNote(
            result.change_note.token,
            result.change_note.amount,
            result.change_note.secret,
            result.change_note.nullifier,
            "pending",
            transaction_hash,
            "receive",
          ),
        );
      }
      await persistVaultNotes((current) => {
        const spentIds = new Set(selectedNotes.map((note) => note.id));
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
          setFromAmount("");
        } else if (status === "rejected") {
          await applyPendingResolution(
            new Map([[transaction_hash, "rejected"]]),
          );
          setSwapError("Transaction reverted");
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
      setSwapError(err instanceof Error ? err.message : "Swap failed");
    } finally {
      setSwapPending(false);
    }
  };

  const handleDeposit = async () => {
    setDepositError("");
    setPendingWarning("");
    if (configError) {
      setDepositError(configError);
      return;
    }
    if (!wallet.account || !wallet.vaultKey) {
      setDepositError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setDepositError("Wrong network");
      return;
    }
    const validationError = validateAmountInput(depositAmount);
    if (validationError) {
      setDepositError(validationError);
      return;
    }
    try {
      const amount = parseUnits(depositAmount);
      if (amount <= BigInt(0)) {
        setDepositError("Amount must be greater than zero");
        return;
      }
      const tokenId = depositTokenId;
      const tokenAddress =
        tokenId === 0 ? zylithConfig.token0 : zylithConfig.token1;
      const note = {
        secret: generateSecretHex(),
        nullifier: generateSecretHex(),
        amount: amount.toString(),
        token: tokenAddress,
      };
      setDepositPending(true);
      const proofResult = await proveDeposit({
        note,
        token_id: tokenId,
      });

      const approveCall = buildApproveCall(
        tokenAddress,
        zylithConfig.shieldedNotesAddress,
        amount,
      );
      const depositCall = buildDepositCall(
        tokenId,
        proofResult.proof,
        proofResult.insertion_proof,
      );
      const { transaction_hash } = await wallet.account.execute([
        approveCall,
        depositCall,
      ]);
      const pendingNote = createTokenNote(
        note.token,
        note.amount,
        note.secret,
        note.nullifier,
        "pending",
        transaction_hash,
        "receive",
      );
      await persistVaultNotes((current): VaultNote[] => [
        ...current,
        pendingNote,
      ]);
      try {
        const receipt = await wallet.account.waitForTransaction(transaction_hash);
        const status = classifyReceiptStatus(receipt);
        if (status === "accepted") {
          await applyPendingResolution(
            new Map([[transaction_hash, "accepted"]]),
          );
          setDepositAmount("");
        } else if (status === "rejected") {
          await applyPendingResolution(
            new Map([[transaction_hash, "rejected"]]),
          );
          setDepositError("Transaction reverted");
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
      setDepositError(err instanceof Error ? err.message : "Deposit failed");
    } finally {
      setDepositPending(false);
    }
  };

  const handleWithdraw = async () => {
    setWithdrawError("");
    setPendingWarning("");
    if (configError) {
      setWithdrawError(configError);
      return;
    }
    if (!wallet.account || !wallet.vaultKey || !wallet.address) {
      setWithdrawError("Connect your wallet");
      return;
    }
    if (!wallet.chainId || wallet.chainId !== expectedChainId) {
      setWithdrawError("Wrong network");
      return;
    }
    const note = withdrawNotes.find((entry) => entry.id === withdrawNoteId);
    if (!note) {
      setWithdrawError("Select a note to withdraw");
      return;
    }
    try {
      setWithdrawPending(true);
      const proofResult = await proveWithdraw({
        note: {
          secret: note.secret,
          nullifier: note.nullifier,
          amount: note.amount,
          token: note.token,
        },
        token_id: withdrawTokenId,
        recipient: wallet.address,
      });
      const call = buildWithdrawCall(
        withdrawTokenId,
        proofResult.proof,
        proofResult.merkle_proof,
      );
      const { transaction_hash } = await wallet.account.execute([call]);
      await persistVaultNotes((current) =>
        current.map((entry) =>
          entry.id === note.id
            ? {
              ...entry,
              state: "pending" as const,
              pending_tx: transaction_hash,
              pending_action: "spend" as const,
            }
            : entry,
        ),
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
          setWithdrawError("Transaction reverted");
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
      setWithdrawError(err instanceof Error ? err.message : "Withdraw failed");
    } finally {
      setWithdrawPending(false);
    }
  };

  return (
    <div className="flex w-full flex-col items-center pt-8">
      {configError && (
        <div className="w-full max-w-[480px] mb-3 surface-1 edge-subtle p-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-red-300">
            {configError}
          </div>
        </div>
      )}
      {pendingNotes.length > 0 && (
        <div className="w-full max-w-[480px] mb-3 surface-0 inner-highlight p-3">
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
        <div className="w-full max-w-[480px] mb-3 surface-1 edge-subtle p-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-amber-300">
            {pendingWarning}
          </div>
        </div>
      )}
      {/* Swap container - angular, precise, no rounded corners */}
      <div className="w-full max-w-[480px] surface-1 edge-subtle">
        {/* Header - minimal, data-forward */}
        <div className="flex items-center justify-between px-4 py-3 border-b border-zylith-edge-subtle/30">
          <span className="text-xs font-medium uppercase tracking-[0.15em] text-zylith-text-primary">
            Swap
          </span>
        </div>

        <div className="p-3 space-y-2">
          {/* From field */}
          <div className="surface-2 inner-highlight p-3 transition-all duration-400 ease-heavy focus-within:accent-inner">
            <div className="flex items-center justify-between text-[10px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-2">
              <span>From</span>
              <span className="font-mono">
                BAL: {formatUnits(balanceIn)}
              </span>
            </div>
            <div className="flex items-center gap-2">
              <input
                type="text"
                inputMode="decimal"
                placeholder="0.00"
                className="flex-1 text-xl font-medium text-zylith-text-primary placeholder:text-zylith-text-tertiary bg-transparent outline-none"
                value={fromAmount}
                onChange={(event) => setFromAmount(event.target.value)}
              />
              <button className="surface-3 edge-subtle px-2.5 py-1.5 text-[11px] font-medium text-zylith-text-primary transition-all duration-400 ease-heavy hover:edge-medium">
                {symbolIn}
              </button>
            </div>
          </div>

          {/* Direction indicator - angular */}
          <div className="flex justify-center py-1">
            <button
              type="button"
              onClick={() => setZeroForOne((value) => !value)}
              className="w-6 h-6 flex items-center justify-center text-zylith-text-tertiary surface-0 edge-subtle hover:edge-medium"
            >
              <svg width="12" height="12" viewBox="0 0 12 12" fill="none">
                <path d="M6 2L6 10M6 10L3 7M6 10L9 7" stroke="currentColor" strokeWidth="1.5" strokeLinecap="square" />
              </svg>
            </button>
          </div>

          {/* To field */}
          <div className="surface-2 inner-highlight p-3 transition-all duration-400 ease-heavy focus-within:accent-inner">
            <div className="flex items-center justify-between text-[10px] uppercase tracking-[0.1em] text-zylith-text-tertiary mb-2">
              <span>To</span>
              <span className="font-mono">
                BAL: {formatUnits(balanceOut)}
              </span>
            </div>
            <div className="flex items-center gap-2">
              <input
                type="text"
                inputMode="decimal"
                placeholder="0.00"
                className="flex-1 text-xl font-medium text-zylith-text-primary placeholder:text-zylith-text-tertiary bg-transparent outline-none"
                readOnly
                value={quoteOut !== null ? quoteOutLabel : ""}
              />
              <button className="surface-3 edge-subtle px-2.5 py-1.5 text-[11px] font-medium text-zylith-text-primary transition-all duration-400 ease-heavy hover:edge-medium">
                {symbolOut}
              </button>
            </div>
          </div>

          {/* Pool info - dense, data-forward */}
          <div className="surface-0 inner-highlight p-2.5 space-y-1.5">
            <div className="flex items-center justify-between text-[10px]">
              <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">Fee</span>
              <span className="font-mono text-zylith-text-secondary">{feeLabel}</span>
            </div>
            <div className="flex items-center justify-between text-[10px]">
              <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">Slippage</span>
              <div className="flex items-center gap-1 font-mono text-zylith-text-secondary">
                <input
                  type="text"
                  inputMode="decimal"
                  value={slippage}
                  onChange={(event) => setSlippage(event.target.value)}
                  className="w-12 bg-transparent text-right outline-none"
                />
                <span>%</span>
              </div>
            </div>
            <div className="flex items-center justify-between text-[10px]">
              <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">Min Receive</span>
              <span className="font-mono text-zylith-text-secondary">
                {minOutLabel} {symbolOut}
              </span>
            </div>
            <div className="flex items-center justify-between text-[10px]">
              <span className="uppercase tracking-[0.1em] text-zylith-text-tertiary">Quote</span>
              <span className="font-mono text-zylith-text-tertiary">
                {quotePending ? "..." : quoteOut !== null ? "OK" : "—"}
              </span>
            </div>
            {slippageError && (
              <div className="text-[10px] text-amber-300 uppercase tracking-[0.1em]">
                {slippageError}
              </div>
            )}
          </div>

          {/* Execute button - diagonal cut, internal glow */}
          <button
            className="
              w-full py-3 mt-1
              text-[11px] font-semibold uppercase tracking-[0.15em]
              text-zylith-text-primary
              surface-2 accent-inner cut-diagonal
              transition-all duration-600 ease-heavy
              hover:accent-focus
              disabled:opacity-40 disabled:cursor-not-allowed
            "
            onClick={wallet.account ? handleSwap : wallet.connect}
            disabled={
              !!configError ||
              !!slippageError ||
              swapPending ||
              (!notesLoaded && !!wallet.account)
            }
          >
            {swapLabel}
          </button>
          {swapError && (
            <div className="text-[10px] text-red-400 uppercase tracking-[0.1em]">
              {swapError}
            </div>
          )}
          {quoteError && !swapError && (
            <div className="text-[10px] text-amber-300 uppercase tracking-[0.1em]">
              {quoteError}
            </div>
          )}
        </div>

      </div>

      <div className="w-full max-w-[480px] mt-5 space-y-2">
        <div className="surface-1 edge-subtle p-3 space-y-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zylith-text-tertiary">
            Deposit Shielded Balance
          </div>
          <div className="flex items-center gap-2">
            <input
              type="text"
              inputMode="decimal"
              placeholder="0.00"
              className="flex-1 surface-2 inner-highlight px-3 py-2 text-sm font-medium text-zylith-text-primary outline-none"
              value={depositAmount}
              onChange={(event) => setDepositAmount(event.target.value)}
            />
            <button
              type="button"
              onClick={() =>
                setDepositTokenId((value) => (value === 0 ? 1 : 0))
              }
              className="surface-3 edge-subtle px-2.5 py-1.5 text-[11px] font-medium text-zylith-text-primary transition-all duration-400 ease-heavy hover:edge-medium"
            >
              {depositTokenId === 0 ? tokenSymbols.token0 : tokenSymbols.token1}
            </button>
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
            onClick={wallet.account ? handleDeposit : wallet.connect}
            disabled={
              !!configError ||
              depositPending ||
              (!notesLoaded && !!wallet.account)
            }
          >
            {depositLabel}
          </button>
          {depositError && (
            <div className="text-[10px] text-red-400 uppercase tracking-[0.1em]">
              {depositError}
            </div>
          )}
        </div>

        <div className="surface-1 edge-subtle p-3 space-y-3">
          <div className="text-[10px] uppercase tracking-[0.15em] text-zylith-text-tertiary">
            Withdraw to Wallet
          </div>
          <div className="flex items-center gap-2">
            <select
              className="flex-1 surface-2 inner-highlight px-3 py-2 text-sm font-medium text-zylith-text-primary bg-transparent outline-none"
              value={withdrawNoteId ?? ""}
              onChange={(event) => setWithdrawNoteId(event.target.value || null)}
            >
              {withdrawNotes.length === 0 && (
                <option value="">No notes available</option>
              )}
              {withdrawNotes.map((note) => (
                <option key={note.id} value={note.id}>
                  {formatUnits(note.amount)} {withdrawTokenId === 0 ? tokenSymbols.token0 : tokenSymbols.token1}
                </option>
              ))}
            </select>
            <button
              type="button"
              onClick={() =>
                setWithdrawTokenId((value) => (value === 0 ? 1 : 0))
              }
              className="surface-3 edge-subtle px-2.5 py-1.5 text-[11px] font-medium text-zylith-text-primary transition-all duration-400 ease-heavy hover:edge-medium"
            >
              {withdrawTokenId === 0 ? tokenSymbols.token0 : tokenSymbols.token1}
            </button>
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
            onClick={wallet.account ? handleWithdraw : wallet.connect}
            disabled={
              !!configError ||
              withdrawPending ||
              withdrawNotes.length === 0 ||
              (!notesLoaded && !!wallet.account)
            }
          >
            {withdrawPending ? "Withdrawing..." : "Withdraw"}
          </button>
          {withdrawError && (
            <div className="text-[10px] text-red-400 uppercase tracking-[0.1em]">
              {withdrawError}
            </div>
          )}
        </div>

      </div>
    </div>
  );
}
