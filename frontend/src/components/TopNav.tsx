import { useCallback, useEffect, useRef, useState } from "react";
import { Link, useLocation } from "react-router-dom";
import { useWallet } from "./WalletProvider";
import { exportVaultBackup, importVaultBackup, type VaultBackup } from "../lib/vault";

const links = [
  { href: "/swap", label: "SWAP" },
  { href: "/positions", label: "POSITIONS" },
];

export default function TopNav() {
  const location = useLocation();
  const wallet = useWallet();
  const label = wallet.address
    ? `${wallet.address.slice(0, 6)}…${wallet.address.slice(-4)}`
    : "Connect";
  const [walletMenuOpen, setWalletMenuOpen] = useState(false);
  const [backupPending, setBackupPending] = useState(false);
  const [backupError, setBackupError] = useState("");
  const menuRef = useRef<HTMLDivElement | null>(null);

  useEffect(() => {
    if (!walletMenuOpen) {
      return;
    }
    const handleClick = (event: MouseEvent) => {
      if (!menuRef.current) {
        return;
      }
      if (!menuRef.current.contains(event.target as Node)) {
        setWalletMenuOpen(false);
      }
    };
    document.addEventListener("mousedown", handleClick);
    return () => {
      document.removeEventListener("mousedown", handleClick);
    };
  }, [walletMenuOpen]);

  const handleExportVault = useCallback(async () => {
    setBackupError("");
    if (!wallet.vaultKey) {
      setBackupError("Connect your wallet");
      return;
    }
    try {
      setBackupPending(true);
      const backup = await exportVaultBackup();
      if (!backup) {
        throw new Error("Vault is empty");
      }
      const blob = new Blob([JSON.stringify(backup, null, 2)], {
        type: "application/json",
      });
      const url = URL.createObjectURL(blob);
      const link = document.createElement("a");
      link.href = url;
      link.download = `zylith-vault-${wallet.address ?? "backup"}.json`;
      link.click();
      URL.revokeObjectURL(url);
    } catch (err) {
      setBackupError(err instanceof Error ? err.message : "Export failed");
    } finally {
      setBackupPending(false);
    }
  }, [wallet.address, wallet.vaultKey]);

  const handleImportVault = useCallback(
    async (file: File) => {
      setBackupError("");
      if (!wallet.vaultKey) {
        setBackupError("Connect your wallet");
        return;
      }
      try {
        setBackupPending(true);
        const text = await file.text();
        const parsed = JSON.parse(text) as VaultBackup;
        await importVaultBackup(parsed);
        wallet.bumpVaultRevision();
      } catch (err) {
        setBackupError(err instanceof Error ? err.message : "Import failed");
      } finally {
        setBackupPending(false);
      }
    },
    [wallet],
  );

  return (
    <header className="w-full surface-0 edge-subtle">
      <div className="mx-auto flex h-12 w-full items-center justify-between px-10">
        {/* Logo - understated, no decoration */}
        <div className="flex items-center gap-1 text-[10px] font-medium uppercase tracking-[0.35em] text-zylith-text-primary select-none">
          <img
            src="/zylith.png"
            alt=""
            aria-hidden="true"
            className="h-6 w-6 object-contain"
          />
          <span>ZYLITH</span>
        </div>

        {/* Navigation - angular, precision */}
        <nav className="flex items-center gap-1">
          {links.map((link) => {
            const active = location.pathname === link.href;
            return (
              <Link
                key={link.href}
                to={link.href}
                className={`
                  relative px-3 py-1.5 text-[11px] font-medium uppercase tracking-[0.15em]
                  transition-all duration-400 ease-heavy
                  ${active
                    ? "text-zylith-text-primary accent-inner"
                    : "text-zylith-text-secondary hover:text-zylith-text-primary"
                  }
                `}
              >
                {link.label}
              </Link>
            );
          })}
        </nav>

        {/* Wallet connection placeholder */}
        <div className="relative flex items-center gap-2" ref={menuRef}>
          <button
            onClick={wallet.address ? wallet.disconnect : wallet.connect}
            className="
              px-3 py-1.5 text-[10px] font-medium uppercase tracking-[0.12em]
              text-zylith-text-primary
              surface-1 edge-subtle
              transition-all duration-400 ease-heavy
              hover:edge-medium
            "
          >
            {label}
          </button>
          <button
            type="button"
            onClick={() => setWalletMenuOpen((open) => !open)}
            className="
              px-2 py-1.5 text-[10px] font-medium uppercase tracking-[0.12em]
              text-zylith-text-secondary
              surface-1 edge-subtle
              transition-all duration-400 ease-heavy
              hover:text-zylith-text-primary hover:edge-medium
            "
          >
            Settings
          </button>
          {walletMenuOpen && (
            <div className="absolute right-0 top-full z-30 mt-2 w-56 space-y-2 surface-1 edge-subtle p-3">
              <div className="text-[9px] uppercase tracking-[0.15em] text-zylith-text-tertiary">
                Vault Backup
              </div>
              <button
                type="button"
                onClick={handleExportVault}
                disabled={backupPending || !wallet.vaultKey}
                className="
                  w-full py-2
                  text-[10px] font-semibold uppercase tracking-[0.15em]
                  text-zylith-text-primary
                  surface-2 accent-inner cut-diagonal
                  transition-all duration-600 ease-heavy
                  hover:accent-focus
                  disabled:opacity-40 disabled:cursor-not-allowed
                "
              >
                {backupPending ? "Working..." : "Export Vault"}
              </button>
              <label
                className="
                  w-full py-2 text-center
                  text-[10px] font-semibold uppercase tracking-[0.15em]
                  text-zylith-text-primary
                  surface-2 accent-inner cut-diagonal
                  transition-all duration-600 ease-heavy
                  hover:accent-focus
                  cursor-pointer
                  block
                "
              >
                Import Vault
                <input
                  type="file"
                  accept="application/json"
                  className="hidden"
                  onChange={(event) => {
                    const file = event.target.files?.[0];
                    if (file) {
                      void handleImportVault(file);
                      event.currentTarget.value = "";
                    }
                  }}
                  disabled={backupPending || !wallet.vaultKey}
                />
              </label>
              {!wallet.vaultKey && (
                <div className="text-[10px] uppercase tracking-[0.12em] text-zylith-text-tertiary">
                  Connect wallet to manage backups.
                </div>
              )}
              {backupError && (
                <div className="text-[10px] text-red-400 uppercase tracking-[0.1em]">
                  {backupError}
                </div>
              )}
            </div>
          )}
        </div>
      </div>
    </header>
  );
}
