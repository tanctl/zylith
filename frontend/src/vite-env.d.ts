/// <reference types="vite/client" />

interface ImportMetaEnv {
  readonly VITE_POOL_ADDRESS?: string;
  readonly VITE_SHIELDED_NOTES?: string;
  readonly VITE_TOKEN0?: string;
  readonly VITE_TOKEN1?: string;
  readonly VITE_PROVER_URL?: string;
  readonly VITE_PROVER_API_KEY?: string;
  readonly VITE_EXPECTED_CHAIN_ID?: string;
  readonly VITE_RPC_URL?: string;
}

interface ImportMeta {
  readonly env: ImportMetaEnv;
}
