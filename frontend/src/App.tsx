import { BrowserRouter, Navigate, Route, Routes } from "react-router-dom";

import TopNav from "./components/TopNav";
import { useWallet, WalletProvider } from "./components/WalletProvider";
import SwapPage from "./pages/Swap";
import PositionsPage from "./pages/Positions";

function BlockingOverlay({ message }: { message: string }) {
  const isVaultError = message.toLowerCase().includes("vault");
  const title = isVaultError ? "Vault Storage Error" : "Session Blocked";
  const helper = isVaultError
    ? "This session is blocked to prevent note loss. Fix browser storage and reload."
    : "Resolve the issue, then reconnect your wallet.";
  return (
    <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/70 px-4">
      <div className="w-full max-w-md surface-1 edge-subtle p-6 space-y-4">
        <div className="text-xs uppercase tracking-[0.2em] text-red-300">
          {title}
        </div>
        <p className="text-sm text-zylith-text-primary">{message}</p>
        <p className="text-xs text-zylith-text-tertiary">
          {helper}
        </p>
        <button
          type="button"
          className="
            w-full py-2
            text-[10px] font-semibold uppercase tracking-[0.15em]
            text-zylith-text-primary
            surface-2 accent-inner cut-diagonal
            transition-all duration-600 ease-heavy
            hover:accent-focus
          "
          onClick={() => window.location.reload()}
        >
          Reload
        </button>
      </div>
    </div>
  );
}

function WalletConnectModal() {
  const wallet = useWallet();
  if (!wallet.walletSelectorOpen) {
    return null;
  }
  const hasWallets = wallet.walletOptions.length > 0;
  return (
    <div className="fixed inset-0 z-40 flex items-center justify-center bg-black/60 px-4">
      <div className="w-full max-w-md surface-1 edge-subtle p-5 space-y-4">
        <div className="text-xs uppercase tracking-[0.2em] text-zylith-text-tertiary">
          Connect Wallet
        </div>
        {hasWallets ? (
          <div className="space-y-2">
            {wallet.walletOptions.map((option) => (
              <button
                key={option.id}
                type="button"
                className="
                  w-full flex items-center justify-between px-3 py-2
                  text-[11px] font-medium uppercase tracking-[0.12em]
                  text-zylith-text-primary
                  surface-2 edge-subtle
                  transition-all duration-400 ease-heavy
                  hover:edge-medium
                "
                onClick={() => wallet.selectWallet(option)}
              >
                <span>{option.name}</span>
                <span className="text-[9px] text-zylith-text-tertiary">
                  {option.id.toUpperCase()}
                </span>
              </button>
            ))}
          </div>
        ) : (
          <div className="space-y-3 text-sm text-zylith-text-primary">
            <p>No Starknet wallet detected.</p>
            <p className="text-xs text-zylith-text-tertiary">
              Install Argent X or Braavos and refresh, then try again.
            </p>
          </div>
        )}
        {wallet.error && !wallet.blockingError && (
          <div className="text-[10px] text-red-300 uppercase tracking-[0.12em]">
            {wallet.error}
          </div>
        )}
        <div className="flex items-center gap-2">
          {!hasWallets && (
            <button
              type="button"
              className="
                flex-1 py-2
                text-[10px] font-semibold uppercase tracking-[0.15em]
                text-zylith-text-primary
                surface-2 accent-inner cut-diagonal
                transition-all duration-600 ease-heavy
                hover:accent-focus
              "
              onClick={wallet.connect}
            >
              Retry Scan
            </button>
          )}
          <button
            type="button"
            className="
              flex-1 py-2
              text-[10px] font-semibold uppercase tracking-[0.15em]
              text-zylith-text-primary
              surface-2 edge-subtle
              transition-all duration-600 ease-heavy
              hover:edge-medium
            "
            onClick={wallet.closeWalletSelector}
          >
            Close
          </button>
        </div>
      </div>
    </div>
  );
}

function AppShell() {
  const wallet = useWallet();
  return (
    <>
      {wallet.blockingError && <BlockingOverlay message={wallet.blockingError} />}
      <WalletConnectModal />
      <TopNav />
      <main className="mx-auto w-full max-w-5xl px-4 py-8">
        <Routes>
          <Route path="/" element={<Navigate to="/swap" replace />} />
          <Route path="/swap" element={<SwapPage />} />
          <Route path="/positions" element={<PositionsPage />} />
        </Routes>
      </main>
    </>
  );
}

export default function App() {
  return (
    <BrowserRouter>
      <WalletProvider>
        <AppShell />
      </WalletProvider>
    </BrowserRouter>
  );
}
