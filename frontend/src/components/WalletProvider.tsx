import {
  createContext,
  useCallback,
  useContext,
  useMemo,
  useState,
} from "react";
import {
  getStarknet,
  type StarknetWindowObject,
} from "@starknet-io/get-starknet-core";
import type { AccountInterface, TypedData } from "starknet";
import { RpcProvider, WalletAccount } from "starknet";

import { expectedChainId, normalizeChainId } from "../lib/zylith";
import { loadVaultKey, saveVaultKey } from "../lib/vault";

type WalletStatus = "disconnected" | "connecting" | "connected" | "error";

type WalletOption = {
  id: string;
  name: string;
  kind: "standard" | "legacy";
  wallet?: StarknetWindowObject;
};

type WalletState = {
  status: WalletStatus;
  address: string | null;
  chainId: string | null;
  account: AccountInterface | null;
  vaultKey: CryptoKey | null;
  vaultRevision: number;
  error: string | null;
  blockingError: string | null;
  walletOptions: WalletOption[];
  walletSelectorOpen: boolean;
  connect: () => Promise<void>;
  selectWallet: (wallet: WalletOption) => Promise<void>;
  closeWalletSelector: () => void;
  bumpVaultRevision: () => void;
  reportVaultError: (message: string) => void;
  disconnect: () => void;
};

const WalletContext = createContext<WalletState | null>(null);
const VAULT_PERSISTENCE_ERROR =
  "Vault storage is unavailable. Encrypted notes could be lost. Please enable IndexedDB or use a supported browser.";
const WALLET_NOT_FOUND_ERROR =
  "No Starknet wallet detected. Install Argent X or Braavos and refresh.";
const WALLET_DISCOVERY_ERROR =
  "Wallet discovery blocked. Try a different browser or disable strict CSP.";
const WALLET_CHANGED_ERROR =
  "Wallet account or network changed. Please reconnect.";
const RPC_URL = import.meta.env.VITE_RPC_URL ?? "http://127.0.0.1:5050";

function normalizeHex(value: string) {
  const prefixed = value.startsWith("0x") ? value : `0x${value}`;
  return prefixed.toLowerCase();
}

function isWalletObject(value: unknown): value is StarknetWindowObject {
  if (!value || typeof value !== "object") {
    return false;
  }
  const candidate = value as Partial<StarknetWindowObject>;
  return (
    typeof candidate.request === "function" ||
    typeof candidate.enable === "function"
  );
}

function discoverInjectedWallets(): WalletOption[] {
  const options: WalletOption[] = [];
  const seen = new Set<string>();
  const win = window as Window & Record<string, unknown>;
  for (const key in win) {
    if (!key.startsWith("starknet")) {
      continue;
    }
    const candidate = win[key];
    if (!isWalletObject(candidate)) {
      continue;
    }
    const wallet = candidate as StarknetWindowObject;
    const id = wallet.id || key;
    if (seen.has(id)) {
      continue;
    }
    seen.add(id);
    options.push({
      id,
      name: wallet.name || (key === "starknet" ? "Starknet (Injected)" : key),
      kind: "standard",
      wallet,
    });
  }
  return options;
}

function vaultTypedData(address: string, chainId: string): TypedData {
  return {
    types: {
      StarkNetDomain: [
        { name: "name", type: "string" },
        { name: "version", type: "string" },
        { name: "chainId", type: "felt" },
      ],
      Message: [
        { name: "statement", type: "string" },
        { name: "address", type: "felt" },
        { name: "chain_id", type: "felt" },
      ],
    },
    primaryType: "Message",
    domain: {
      name: "Zylith Vault",
      version: "1",
      chainId,
    },
    message: {
      statement: "Zylith note vault v1",
      address,
      chain_id: chainId,
    },
  };
}

async function deriveVaultKey(
  account: AccountInterface,
  address: string,
  chainId: string,
): Promise<CryptoKey> {
  const typedData = vaultTypedData(address, chainId);
  // vault key derivation depends on deterministic wallet signatures, variance across wallets can break unlocks
  const signature = await account.signMessage(typedData);
  // starknet-js v6.x Signature can be array or object - normalize to string array
  const signatureArray = Array.isArray(signature)
    ? signature.map((felt) => normalizeHex(felt.toString()))
    : [normalizeHex(signature.r.toString()), normalizeHex(signature.s.toString())];
  const material = new TextEncoder().encode(
    `${address}:${chainId}:${signatureArray.join(",")}`,
  );
  const hash = await crypto.subtle.digest("SHA-256", material);
  return crypto.subtle.importKey("raw", hash, "AES-GCM", false, [
    "encrypt",
    "decrypt",
  ]);
}

export function WalletProvider({ children }: { children: React.ReactNode }) {
  const [status, setStatus] = useState<WalletStatus>("disconnected");
  const [address, setAddress] = useState<string | null>(null);
  const [chainId, setChainId] = useState<string | null>(null);
  const [account, setAccount] = useState<AccountInterface | null>(null);
  const [activeWallet, setActiveWallet] = useState<StarknetWindowObject | null>(null);
  const [vaultKey, setVaultKey] = useState<CryptoKey | null>(null);
  const [vaultRevision, setVaultRevision] = useState(0);
  const [error, setError] = useState<string | null>(null);
  const [blockingError, setBlockingError] = useState<string | null>(null);
  const [walletOptions, setWalletOptions] = useState<WalletOption[]>([]);
  const [walletSelectorOpen, setWalletSelectorOpen] = useState(false);

  const handleWalletChange = useCallback(() => {
    setStatus("error");
    setError(WALLET_CHANGED_ERROR);
    setBlockingError(WALLET_CHANGED_ERROR);
    setAccount(null);
    setAddress(null);
    setChainId(null);
    setVaultKey(null);
    setWalletSelectorOpen(false);
  }, []);

  const connectWithWallet = useCallback(
    async (wallet: StarknetWindowObject) => {
      setError(null);
      setBlockingError(null);
      setStatus("connecting");
      try {
        const requestAccounts = async (): Promise<string[]> => {
          if (typeof wallet.request === "function") {
            const accounts = await wallet.request({
              type: "wallet_requestAccounts",
            });
            if (Array.isArray(accounts) && accounts.length > 0) {
              return accounts.map((account) => account.toString());
            }
          }
          if (typeof wallet.enable === "function") {
            const accounts = await wallet.enable();
            if (Array.isArray(accounts) && accounts.length > 0) {
              return accounts.map((account) => account.toString());
            }
          }
          return [];
        };
        const accounts = await requestAccounts();
        const connectedWallet = wallet;
        const provider = new RpcProvider({ nodeUrl: RPC_URL });
        const connectedAccount = new WalletAccount(provider, connectedWallet);
        let walletAddressRaw = accounts[0] ?? "";
        const walletAddressFallback =
          ((connectedWallet as { selectedAddress?: string }).selectedAddress as string | undefined) ??
          connectedAccount.address;
        const walletAddress = walletAddressRaw || walletAddressFallback;
        if (!walletAddress) {
          throw new Error("Wallet account unavailable");
        }
        let walletChainId = "";
        try {
          const chainIdValue = await connectedWallet.request({
            type: "wallet_requestChainId",
          });
          walletChainId = chainIdValue?.toString() ?? "";
        } catch {
          const chainIdValue = await connectedAccount.getChainId();
          walletChainId = chainIdValue?.toString() ?? "";
        }
        if (!walletChainId) {
          throw new Error("Unable to read chainId");
        }
        const normalizedChainId = normalizeChainId(walletChainId);
        if (expectedChainId && normalizedChainId !== expectedChainId) {
          throw new Error(`Wrong network. Expected ${expectedChainId}`);
        }
        const providerChainId = await provider.getChainId();
        const providerNormalized = normalizeChainId(
          providerChainId?.toString() ?? "",
        );
        if (providerNormalized && providerNormalized !== normalizedChainId) {
          throw new Error("RPC provider network does not match wallet network");
        }
        const addressNormalized =
          walletAddress.startsWith("0x") ? walletAddress : `0x${walletAddress}`;
        const normalizedAddress = addressNormalized.toLowerCase();
        let key: CryptoKey | null = null;
        try {
          key = await loadVaultKey(normalizedAddress, normalizedChainId);
          if (!key && addressNormalized !== normalizedAddress) {
            key = await loadVaultKey(addressNormalized, normalizedChainId);
            if (key) {
              await saveVaultKey(normalizedAddress, normalizedChainId, key);
            }
          }
        } catch {
          throw new Error(VAULT_PERSISTENCE_ERROR);
        }
        if (!key) {
          key = await deriveVaultKey(
            connectedAccount,
            normalizedAddress,
            normalizedChainId,
          );
          try {
            await saveVaultKey(normalizedAddress, normalizedChainId, key);
          } catch {
            throw new Error(VAULT_PERSISTENCE_ERROR);
          }
        }

        connectedWallet.off?.("accountsChanged", handleWalletChange);
        connectedWallet.off?.("networkChanged", handleWalletChange);
        connectedWallet.on?.("accountsChanged", handleWalletChange);
        connectedWallet.on?.("networkChanged", handleWalletChange);

        setAccount(connectedAccount);
        setAddress(normalizedAddress);
        setChainId(normalizedChainId);
        setActiveWallet(connectedWallet);
        setVaultKey(key);
        setStatus("connected");
        setWalletSelectorOpen(false);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : "Wallet connection failed";
        if (message === VAULT_PERSISTENCE_ERROR) {
          setBlockingError(message);
        }
        setError(message);
        setStatus("error");
        setAccount(null);
        setAddress(null);
        setChainId(null);
        setVaultKey(null);
      }
    },
    [handleWalletChange],
  );

  const connectWithLegacy = useCallback(async () => {
    setError(null);
    setBlockingError(null);
    setStatus("connecting");
    try {
      const starknetWindow = (window as typeof window & {
        starknet?: {
          enable: () => Promise<string[]>;
          account?: AccountInterface;
          selectedAddress?: string;
          chainId?: string;
        };
      }).starknet;

      if (!starknetWindow) {
        throw new Error(WALLET_NOT_FOUND_ERROR);
      }

      await starknetWindow.enable();
      const connectedAccount = starknetWindow.account;
      if (!connectedAccount) {
        throw new Error("Wallet account unavailable");
      }
      const walletAddressRaw =
        starknetWindow.selectedAddress ?? connectedAccount.address;
      const walletAddress = walletAddressRaw.toString();
      const chainIdValue = await connectedAccount.getChainId?.();
      const walletChainIdRaw =
        (chainIdValue ? chainIdValue.toString() : null) ??
        starknetWindow.chainId ??
        "";
      if (!walletChainIdRaw) {
        throw new Error("Unable to read chainId");
      }
      const normalizedChainId = normalizeChainId(walletChainIdRaw);
      if (expectedChainId && normalizedChainId !== expectedChainId) {
        throw new Error(`Wrong network. Expected ${expectedChainId}`);
      }
      const provider = (connectedAccount as unknown as { provider?: RpcProvider }).provider;
      if (provider?.getChainId) {
        const providerChainId = await provider.getChainId();
        const providerNormalized = normalizeChainId(
          providerChainId?.toString() ?? "",
        );
        if (providerNormalized && providerNormalized !== normalizedChainId) {
          throw new Error("RPC provider network does not match wallet network");
        }
      }
      const addressNormalized =
        walletAddress.startsWith("0x") ? walletAddress : `0x${walletAddress}`;
      const normalizedAddress = addressNormalized.toLowerCase();
      let key: CryptoKey | null = null;
      try {
        key = await loadVaultKey(normalizedAddress, normalizedChainId);
        if (!key && addressNormalized !== normalizedAddress) {
          key = await loadVaultKey(addressNormalized, normalizedChainId);
          if (key) {
            await saveVaultKey(normalizedAddress, normalizedChainId, key);
          }
        }
      } catch {
        throw new Error(VAULT_PERSISTENCE_ERROR);
      }
      if (!key) {
        key = await deriveVaultKey(
          connectedAccount,
          normalizedAddress,
          normalizedChainId,
        );
        try {
          await saveVaultKey(normalizedAddress, normalizedChainId, key);
        } catch {
          throw new Error(VAULT_PERSISTENCE_ERROR);
        }
      }

      starknetWindow.off?.("accountsChanged", handleWalletChange);
      starknetWindow.off?.("networkChanged", handleWalletChange);
      starknetWindow.on?.("accountsChanged", handleWalletChange);
      starknetWindow.on?.("networkChanged", handleWalletChange);

      setAccount(connectedAccount);
      setAddress(normalizedAddress);
      setChainId(normalizedChainId);
      setActiveWallet(starknetWindow as unknown as StarknetWindowObject);
      setVaultKey(key);
      setStatus("connected");
      setWalletSelectorOpen(false);
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Wallet connection failed";
      if (message === VAULT_PERSISTENCE_ERROR) {
        setBlockingError(message);
      }
      setError(message);
      setStatus("error");
      setAccount(null);
      setAddress(null);
      setChainId(null);
      setVaultKey(null);
    }
  }, [handleWalletChange]);

  const connect = useCallback(async () => {
    try {
      setError(null);
      setBlockingError(null);
      setStatus("connecting");
      let options: WalletOption[] = [];
      let discoveryFailed = false;
      try {
        const connector = getStarknet();
        const wallets = await connector.getAvailableWallets();
        options = wallets.map((wallet) => ({
          id: wallet.id,
          name: wallet.name,
          kind: "standard",
          wallet,
        }));
      } catch {
        discoveryFailed = true;
      }
      if (options.length === 0) {
        options = discoverInjectedWallets();
        if (discoveryFailed && options.length > 0) {
          setError(WALLET_DISCOVERY_ERROR);
        }
      }
      setWalletOptions(options);
      setWalletSelectorOpen(true);
      if (options.length === 0) {
        setError(WALLET_NOT_FOUND_ERROR);
        setStatus("error");
      } else {
        setStatus("disconnected");
      }
    } catch (err) {
      const message =
        err instanceof Error ? err.message : "Wallet connection failed";
      if (message === VAULT_PERSISTENCE_ERROR) {
        setBlockingError(message);
      }
      setError(message);
      setStatus("error");
    }
  }, []);

  const selectWallet = useCallback(
    async (wallet: WalletOption) => {
      if (wallet.kind === "standard" && wallet.wallet) {
        await connectWithWallet(wallet.wallet);
      } else {
        await connectWithLegacy();
      }
    },
    [connectWithWallet, connectWithLegacy],
  );

  const closeWalletSelector = useCallback(() => {
    setWalletSelectorOpen(false);
  }, []);

  const disconnect = useCallback(() => {
    if (activeWallet) {
      activeWallet.off?.("accountsChanged", handleWalletChange);
      activeWallet.off?.("networkChanged", handleWalletChange);
    }
    setStatus("disconnected");
    setAddress(null);
    setChainId(null);
    setAccount(null);
    setActiveWallet(null);
    setVaultKey(null);
    setVaultRevision(0);
    setError(null);
    setBlockingError(null);
    setWalletOptions([]);
    setWalletSelectorOpen(false);
  }, [activeWallet, handleWalletChange]);

  const bumpVaultRevision = useCallback(() => {
    setVaultRevision((value) => value + 1);
  }, []);

  const reportVaultError = useCallback((message: string) => {
    setBlockingError(message);
    setError(message);
    setStatus("error");
  }, []);

  const value = useMemo(
    () => ({
      status,
      address,
      chainId,
      account,
      vaultKey,
      vaultRevision,
      error,
      blockingError,
      walletOptions,
      walletSelectorOpen,
      connect,
      selectWallet,
      closeWalletSelector,
      bumpVaultRevision,
      reportVaultError,
      disconnect,
    }),
    [
      status,
      address,
      chainId,
      account,
      vaultKey,
      vaultRevision,
      error,
      blockingError,
      walletOptions,
      walletSelectorOpen,
      connect,
      selectWallet,
      closeWalletSelector,
      bumpVaultRevision,
      reportVaultError,
      disconnect,
    ],
  );

  return (
    <WalletContext.Provider value={value}>
      {children}
    </WalletContext.Provider>
  );
}

export function useWallet() {
  const ctx = useContext(WalletContext);
  if (!ctx) {
    throw new Error("useWallet must be used within WalletProvider");
  }
  return ctx;
}
