export type TokenNote = {
  id: string;
  type: "token";
  token: string;
  amount: string;
  secret: string;
  nullifier: string;
  state: "unspent" | "spent" | "pending";
  pending_tx?: string;
  pending_action?: "spend" | "receive";
  created_at: number;
};

export type PositionNote = {
  id: string;
  type: "position";
  tick_lower: number;
  tick_upper: number;
  liquidity: string;
  fee_growth_inside_0: string;
  fee_growth_inside_1: string;
  secret: string;
  nullifier: string;
  state: "unspent" | "spent" | "pending";
  pending_tx?: string;
  pending_action?: "spend" | "receive";
  created_at: number;
};

export type VaultNote = TokenNote | PositionNote;

type VaultBlob = {
  version: number;
  nonce: string;
  ciphertext: string;
};

export type VaultBackup = VaultBlob;

const DB_NAME = "zylith-vault";
const STORE_NAME = "vault";
const RECORD_KEY = "notes";
const KEY_PREFIX = "vault-key:";
const VAULT_VERSION = 1;
let vaultWriteQueue: Promise<void> = Promise.resolve();

function openDb(): Promise<IDBDatabase> {
  return new Promise((resolve, reject) => {
    const request = indexedDB.open(DB_NAME, 1);
    request.onupgradeneeded = () => {
      const db = request.result;
      if (!db.objectStoreNames.contains(STORE_NAME)) {
        db.createObjectStore(STORE_NAME);
      }
    };
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => reject(request.error);
  });
}

function readVaultValue<T>(db: IDBDatabase, key: string): Promise<T | null> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readonly");
    const store = tx.objectStore(STORE_NAME);
    const request = store.get(key);
    request.onsuccess = () => {
      resolve(request.result ?? null);
    };
    request.onerror = () => reject(request.error);
  });
}

function writeVaultValue<T>(db: IDBDatabase, key: string, value: T): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    const store = tx.objectStore(STORE_NAME);
    const request = store.put(value, key);
    request.onsuccess = () => resolve();
    request.onerror = () => reject(request.error);
  });
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  for (const byte of bytes) {
    binary += String.fromCharCode(byte);
  }
  return btoa(binary);
}

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

function isCryptoKeyLike(value: unknown): value is CryptoKey {
  if (!value || typeof value !== "object") {
    return false;
  }
  const tag = Object.prototype.toString.call(value);
  if (tag === "[object CryptoKey]") {
    return true;
  }
  const candidate = value as {
    type?: unknown;
    extractable?: unknown;
    usages?: unknown;
    algorithm?: { name?: unknown };
  };
  return (
    typeof candidate.type === "string" &&
    typeof candidate.extractable === "boolean" &&
    Array.isArray(candidate.usages) &&
    typeof candidate.algorithm?.name === "string"
  );
}

function enqueueVaultWrite<T>(task: () => Promise<T>): Promise<T> {
  const next = vaultWriteQueue.then(task, task);
  vaultWriteQueue = next.then(
    () => undefined,
    () => undefined,
  );
  return next;
}

async function encryptNotes(
  key: CryptoKey,
  notes: VaultNote[],
): Promise<VaultBlob> {
  const data = new TextEncoder().encode(JSON.stringify(notes));
  const nonce = crypto.getRandomValues(new Uint8Array(12));
  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    data,
  );
  return {
    version: VAULT_VERSION,
    nonce: bytesToBase64(nonce),
    ciphertext: bytesToBase64(new Uint8Array(ciphertext)),
  };
}

async function decryptNotes(
  key: CryptoKey,
  blob: VaultBlob,
): Promise<VaultNote[]> {
  if (blob.version !== VAULT_VERSION) {
    throw new Error("Vault format mismatch. Restore from a compatible backup.");
  }
  const nonce = base64ToBytes(blob.nonce);
  const ciphertext = base64ToBytes(blob.ciphertext);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: nonce },
    key,
    ciphertext,
  );
  const decoded = new TextDecoder().decode(plaintext);
  return JSON.parse(decoded) as VaultNote[];
}

export async function loadVaultNotes(key: CryptoKey): Promise<VaultNote[]> {
  const db = await openDb();
  const blob = await readVaultValue<VaultBlob>(db, RECORD_KEY);
  if (!blob) {
    return [];
  }
  return decryptNotes(key, blob);
}

export async function saveVaultNotes(
  key: CryptoKey,
  notes: VaultNote[],
): Promise<void> {
  const db = await openDb();
  const blob = await encryptNotes(key, notes);
  await writeVaultValue(db, RECORD_KEY, blob);
}

export async function upsertVaultNotes(
  key: CryptoKey,
  updater: (notes: VaultNote[]) => VaultNote[],
): Promise<VaultNote[]> {
  return enqueueVaultWrite(async () => {
    const current = await loadVaultNotes(key);
    const next = updater(current);
    await saveVaultNotes(key, next);
    return next;
  });
}

export function createTokenNote(
  token: string,
  amount: string,
  secret: string,
  nullifier: string,
  state: "unspent" | "spent" | "pending" = "unspent",
  pending_tx?: string,
  pending_action?: "spend" | "receive",
): TokenNote {
  return {
    id: crypto.randomUUID(),
    type: "token",
    token,
    amount,
    secret,
    nullifier,
    state,
    pending_tx,
    pending_action,
    created_at: Date.now(),
  };
}

export function createPositionNote(
  input: Omit<PositionNote, "id" | "type" | "created_at">,
): PositionNote {
  return {
    id: crypto.randomUUID(),
    type: "position",
    created_at: Date.now(),
    ...input,
  };
}

export function generateSecretHex(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(32));
  return `0x${Array.from(bytes)
    .map((b) => b.toString(16).padStart(2, "0"))
    .join("")}`;
}

export async function exportVaultBackup(): Promise<VaultBackup | null> {
  const db = await openDb();
  return readVaultValue<VaultBlob>(db, RECORD_KEY);
}

export async function importVaultBackup(backup: VaultBackup): Promise<void> {
  if (!backup || backup.version !== VAULT_VERSION) {
    throw new Error("Invalid vault backup");
  }
  const db = await openDb();
  await writeVaultValue(db, RECORD_KEY, backup);
}

function vaultKeyId(address: string, chainId: string): string {
  return `${KEY_PREFIX}${address}:${chainId}`;
}

export async function loadVaultKey(
  address: string,
  chainId: string,
): Promise<CryptoKey | null> {
  const db = await openDb();
  const stored = await readVaultValue<unknown>(db, vaultKeyId(address, chainId));
  if (stored && !isCryptoKeyLike(stored)) {
    throw new Error("Vault key storage is unavailable");
  }
  if (!stored) {
    return null;
  }
  return stored as CryptoKey;
}

export async function saveVaultKey(
  address: string,
  chainId: string,
  key: CryptoKey,
): Promise<void> {
  const db = await openDb();
  await writeVaultValue(db, vaultKeyId(address, chainId), key);
}
