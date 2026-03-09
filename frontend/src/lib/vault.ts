import { normalizeFelt } from "./zylith";

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

export type VaultScope = {
  address: string;
  chainId: string;
};

export type VaultBackup = VaultBlob & {
  address: string;
  chainId: string;
  recovery?: VaultBlob;
};

export type PendingVaultOperation = {
  id: string;
  tx_hash?: string;
  spend_note_ids: string[];
  receive_notes: VaultNote[];
};

const DB_NAME = "zylith-vault";
const STORE_NAME = "vault";
const LEGACY_RECORD_KEY = "notes";
const NOTES_PREFIX = "notes:";
const KEY_PREFIX = "vault-key:";
const RECOVERY_PREFIX = "zylith-vault-recovery:";
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

function deleteVaultValue(db: IDBDatabase, key: string): Promise<void> {
  return new Promise((resolve, reject) => {
    const tx = db.transaction(STORE_NAME, "readwrite");
    const store = tx.objectStore(STORE_NAME);
    const request = store.delete(key);
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

function isVaultBlob(value: unknown): value is VaultBlob {
  return (
    isObjectRecord(value) &&
    value.version === VAULT_VERSION &&
    typeof value.nonce === "string" &&
    typeof value.ciphertext === "string"
  );
}

function isObjectRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null;
}

function isNoteState(value: unknown): value is TokenNote["state"] {
  return value === "unspent" || value === "spent" || value === "pending";
}

function isPendingAction(value: unknown): value is NonNullable<TokenNote["pending_action"]> {
  return value === "spend" || value === "receive";
}

function isOptionalPendingAction(value: unknown): value is TokenNote["pending_action"] {
  return value === undefined || isPendingAction(value);
}

function isBaseVaultNote(value: unknown): value is Record<string, unknown> {
  if (!isObjectRecord(value)) {
    return false;
  }
  return (
    typeof value.id === "string" &&
    typeof value.secret === "string" &&
    typeof value.nullifier === "string" &&
    isNoteState(value.state) &&
    isOptionalPendingAction(value.pending_action) &&
    (value.pending_tx === undefined || typeof value.pending_tx === "string") &&
    Number.isFinite(value.created_at)
  );
}

function isTokenNote(value: unknown): value is TokenNote {
  if (!isBaseVaultNote(value)) {
    return false;
  }
  return (
    value.type === "token" &&
    typeof value.token === "string" &&
    typeof value.amount === "string"
  );
}

function isPositionNote(value: unknown): value is PositionNote {
  if (!isBaseVaultNote(value)) {
    return false;
  }
  return (
    value.type === "position" &&
    Number.isInteger(value.tick_lower) &&
    Number.isInteger(value.tick_upper) &&
    typeof value.liquidity === "string" &&
    typeof value.fee_growth_inside_0 === "string" &&
    typeof value.fee_growth_inside_1 === "string"
  );
}

function isVaultNote(value: unknown): value is VaultNote {
  return isTokenNote(value) || isPositionNote(value);
}

function assertVaultNotes(value: unknown): asserts value is VaultNote[] {
  if (!Array.isArray(value) || !value.every(isVaultNote)) {
    throw new Error("Invalid vault backup");
  }
}

function isPendingVaultOperation(value: unknown): value is PendingVaultOperation {
  if (!isObjectRecord(value)) {
    return false;
  }
  return (
    typeof value.id === "string" &&
    (value.tx_hash === undefined || typeof value.tx_hash === "string") &&
    Array.isArray(value.spend_note_ids) &&
    value.spend_note_ids.every((entry) => typeof entry === "string") &&
    Array.isArray(value.receive_notes) &&
    value.receive_notes.every(isVaultNote)
  );
}

function assertPendingVaultOperations(value: unknown): asserts value is PendingVaultOperation[] {
  if (!Array.isArray(value) || !value.every(isPendingVaultOperation)) {
    throw new Error("Vault recovery storage is unavailable");
  }
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
  return encryptPayload(key, notes);
}

async function encryptPayload<T>(key: CryptoKey, payload: T): Promise<VaultBlob> {
  const data = new TextEncoder().encode(JSON.stringify(payload));
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
  const notes = await decryptPayload<unknown>(key, blob);
  assertVaultNotes(notes);
  return notes;
}

async function decryptPayload<T>(key: CryptoKey, blob: VaultBlob): Promise<T> {
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
  return JSON.parse(decoded) as T;
}

function vaultNotesId(scope: VaultScope): string {
  return `${NOTES_PREFIX}${scope.address}:${scope.chainId}`;
}

function vaultKeyId(address: string, chainId: string): string {
  return `${KEY_PREFIX}${address}:${chainId}`;
}

function vaultRecoveryId(scope: VaultScope): string {
  return `${RECOVERY_PREFIX}${scope.address}:${scope.chainId}`;
}

function localStorageHandle(): Storage | null {
  try {
    return window.localStorage;
  } catch {
    return null;
  }
}

function noteWithPendingReceive(note: VaultNote, txRef: string): VaultNote {
  return {
    ...note,
    state: "pending",
    pending_tx: txRef,
    pending_action: "receive",
  };
}

function applyVaultOperation(
  notes: VaultNote[],
  operation: PendingVaultOperation,
): { notes: VaultNote[]; changed: boolean } {
  const txRef = operation.tx_hash ?? operation.id;
  const spendIds = new Set(operation.spend_note_ids);
  const receiveNotes = new Map(
    operation.receive_notes.map((note) => [note.id, noteWithPendingReceive(note, txRef)]),
  );
  let changed = false;
  const next = notes.map((note) => {
    if (spendIds.has(note.id)) {
      const pendingNote: VaultNote = {
        ...note,
        state: "pending",
        pending_tx: txRef,
        pending_action: "spend",
      };
      if (
        note.state !== pendingNote.state ||
        note.pending_tx !== pendingNote.pending_tx ||
        note.pending_action !== pendingNote.pending_action
      ) {
        changed = true;
      }
      return pendingNote;
    }
    const receiveNote = receiveNotes.get(note.id);
    if (!receiveNote) {
      return note;
    }
    receiveNotes.delete(note.id);
    if (
      note.state !== receiveNote.state ||
      note.pending_tx !== receiveNote.pending_tx ||
      note.pending_action !== receiveNote.pending_action
    ) {
      changed = true;
    }
    return receiveNote;
  });
  for (const receiveNote of receiveNotes.values()) {
    next.push(receiveNote);
    changed = true;
  }
  return { notes: next, changed };
}

function revertVaultOperation(
  notes: VaultNote[],
  operation: PendingVaultOperation,
): { notes: VaultNote[]; changed: boolean } {
  const receiveIds = new Set(operation.receive_notes.map((note) => note.id));
  let changed = false;
  const next: VaultNote[] = [];
  for (const note of notes) {
    if (
      receiveIds.has(note.id) &&
      note.state === "pending" &&
      note.pending_tx === operation.id &&
      note.pending_action === "receive"
    ) {
      changed = true;
      continue;
    }
    if (
      note.state === "pending" &&
      note.pending_tx === operation.id &&
      note.pending_action === "spend"
    ) {
      next.push({
        ...note,
        state: "unspent",
        pending_tx: undefined,
        pending_action: undefined,
      });
      changed = true;
      continue;
    }
    next.push(note);
  }
  return { notes: next, changed };
}

async function loadPendingVaultOperations(
  scope: VaultScope,
  key: CryptoKey,
): Promise<PendingVaultOperation[]> {
  const storage = localStorageHandle();
  if (!storage) {
    return [];
  }
  const raw = storage.getItem(vaultRecoveryId(scope));
  if (!raw) {
    return [];
  }
  let blob: VaultBlob;
  try {
    blob = JSON.parse(raw) as VaultBlob;
  } catch {
    throw new Error("Vault recovery storage is unavailable");
  }
  try {
    const operations = await decryptPayload<unknown>(key, blob);
    assertPendingVaultOperations(operations);
    return operations;
  } catch {
    throw new Error("Vault recovery storage is unavailable");
  }
}

async function decryptPendingVaultOperations(
  key: CryptoKey,
  blob: VaultBlob,
): Promise<PendingVaultOperation[]> {
  const operations = await decryptPayload<unknown>(key, blob);
  assertPendingVaultOperations(operations);
  return operations;
}

async function savePendingVaultOperations(
  scope: VaultScope,
  key: CryptoKey,
  operations: PendingVaultOperation[],
): Promise<void> {
  const storage = localStorageHandle();
  if (!storage) {
    throw new Error("Vault recovery storage is unavailable");
  }
  if (operations.length === 0) {
    storage.removeItem(vaultRecoveryId(scope));
    return;
  }
  const blob = await encryptPayload(key, operations);
  storage.setItem(vaultRecoveryId(scope), JSON.stringify(blob));
}

async function reconcileVaultOperations(
  scope: VaultScope,
  key: CryptoKey,
  notes: VaultNote[],
): Promise<VaultNote[]> {
  const operations = await loadPendingVaultOperations(scope, key);
  if (operations.length === 0) {
    return notes;
  }
  let next = notes;
  let changed = false;
  let pruned = false;
  const activeOperations: PendingVaultOperation[] = [];
  for (const operation of operations) {
    const isTracked = next.some(
      (note) =>
        note.state === "pending" &&
        (note.pending_tx === operation.id ||
          (operation.tx_hash !== undefined && note.pending_tx === operation.tx_hash)),
    );
    if (!isTracked) {
      if (operation.tx_hash === undefined) {
        activeOperations.push(operation);
        const applied = applyVaultOperation(next, operation);
        next = applied.notes;
        changed = changed || applied.changed;
        continue;
      }
      pruned = true;
      continue;
    }
    activeOperations.push(operation);
    const applied = applyVaultOperation(next, operation);
    next = applied.notes;
    changed = changed || applied.changed;
  }
  if (pruned) {
    await savePendingVaultOperations(scope, key, activeOperations);
  }
  if (changed) {
    await saveVaultNotesUnsafe(scope, key, next);
  }
  return next;
}

async function loadVaultNotesUnsafe(
  scope: VaultScope,
  key: CryptoKey,
): Promise<VaultNote[]> {
  const db = await openDb();
  const blob = await readVaultValue<VaultBlob>(db, vaultNotesId(scope));
  let notes: VaultNote[] = [];
  if (blob) {
    try {
      notes = await decryptNotes(key, blob);
    } catch {
      throw new Error("Vault storage is unavailable");
    }
  } else {
    const legacyBlob = await readVaultValue<VaultBlob>(db, LEGACY_RECORD_KEY);
    if (legacyBlob) {
      try {
        notes = await decryptNotes(key, legacyBlob);
        await writeVaultValue(db, vaultNotesId(scope), legacyBlob);
      } catch {
        notes = [];
      }
    }
  }
  return reconcileVaultOperations(scope, key, notes);
}

async function saveVaultNotesUnsafe(
  scope: VaultScope,
  key: CryptoKey,
  notes: VaultNote[],
): Promise<void> {
  const db = await openDb();
  const blob = await encryptNotes(key, notes);
  await writeVaultValue(db, vaultNotesId(scope), blob);
}

async function upsertVaultNotesUnsafe(
  scope: VaultScope,
  key: CryptoKey,
  updater: (notes: VaultNote[]) => VaultNote[],
): Promise<VaultNote[]> {
  const current = await loadVaultNotesUnsafe(scope, key);
  const next = updater(current);
  await saveVaultNotesUnsafe(scope, key, next);
  return next;
}

export async function loadVaultNotes(
  scope: VaultScope,
  key: CryptoKey,
): Promise<VaultNote[]> {
  return enqueueVaultWrite(() => loadVaultNotesUnsafe(scope, key));
}

export async function saveVaultNotes(
  scope: VaultScope,
  key: CryptoKey,
  notes: VaultNote[],
): Promise<void> {
  return enqueueVaultWrite(() => saveVaultNotesUnsafe(scope, key, notes));
}

export async function upsertVaultNotes(
  scope: VaultScope,
  key: CryptoKey,
  updater: (notes: VaultNote[]) => VaultNote[],
): Promise<VaultNote[]> {
  return enqueueVaultWrite(() => upsertVaultNotesUnsafe(scope, key, updater));
}

export async function stageVaultOperation(
  scope: VaultScope,
  key: CryptoKey,
  operation: PendingVaultOperation,
): Promise<VaultNote[]> {
  return enqueueVaultWrite(async () => {
    const operations = await loadPendingVaultOperations(scope, key);
    const nextOperations = operations.filter((entry) => entry.id !== operation.id);
    nextOperations.push({
      ...operation,
      tx_hash: operation.tx_hash,
    });
    await savePendingVaultOperations(scope, key, nextOperations);
    try {
      return await upsertVaultNotesUnsafe(
        scope,
        key,
        (notes) => applyVaultOperation(notes, operation).notes,
      );
    } catch (err) {
      await savePendingVaultOperations(scope, key, operations);
      throw err;
    }
  });
}

export async function bindVaultOperationTx(
  scope: VaultScope,
  key: CryptoKey,
  operationId: string,
  txHash: string,
): Promise<VaultNote[]> {
  return enqueueVaultWrite(async () => {
    const operations = await loadPendingVaultOperations(scope, key);
    const nextOperations = operations.map((entry) =>
      entry.id === operationId ? { ...entry, tx_hash: txHash } : entry,
    );
    await savePendingVaultOperations(scope, key, nextOperations);
    const operation = nextOperations.find((entry) => entry.id === operationId);
    if (!operation) {
      throw new Error("Vault recovery operation not found");
    }
    return upsertVaultNotesUnsafe(scope, key, (notes) => applyVaultOperation(notes, operation).notes);
  });
}

export async function abortVaultOperation(
  scope: VaultScope,
  key: CryptoKey,
  operationId: string,
): Promise<VaultNote[]> {
  return enqueueVaultWrite(async () => {
    const operations = await loadPendingVaultOperations(scope, key);
    const operation = operations.find((entry) => entry.id === operationId);
    if (!operation) {
      return loadVaultNotesUnsafe(scope, key);
    }
    const nextOperations = operations.filter((entry) => entry.id !== operationId);
    await savePendingVaultOperations(scope, key, nextOperations);
    return upsertVaultNotesUnsafe(scope, key, (notes) => revertVaultOperation(notes, operation).notes);
  });
}

export async function clearVaultOperationsByTx(
  scope: VaultScope,
  key: CryptoKey,
  txHashes: Iterable<string>,
): Promise<void> {
  return enqueueVaultWrite(async () => {
    const hashes = new Set(txHashes);
    if (hashes.size === 0) {
      return;
    }
    const operations = await loadPendingVaultOperations(scope, key);
    const nextOperations = operations.filter((entry) => !entry.tx_hash || !hashes.has(entry.tx_hash));
    if (nextOperations.length === operations.length) {
      return;
    }
    await savePendingVaultOperations(scope, key, nextOperations);
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
    token: normalizeFelt(token),
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

export async function exportVaultBackup(
  scope: VaultScope,
  key: CryptoKey,
): Promise<VaultBackup | null> {
  return enqueueVaultWrite(async () => {
    const notes = await loadVaultNotesUnsafe(scope, key);
    if (notes.length === 0) {
      return null;
    }
    const backup = await encryptNotes(key, notes);
    const operations = await loadPendingVaultOperations(scope, key);
    const recovery =
      operations.length > 0 ? await encryptPayload(key, operations) : undefined;
    return {
      ...backup,
      address: scope.address,
      chainId: scope.chainId,
      recovery,
    };
  });
}

export async function importVaultBackup(
  scope: VaultScope,
  key: CryptoKey,
  backup: VaultBackup | VaultBlob,
): Promise<void> {
  const scopedBackup = backup as Partial<VaultBackup>;
  if (
    !isVaultBlob(backup) ||
    (scopedBackup.address !== undefined && scopedBackup.address !== scope.address) ||
    (scopedBackup.chainId !== undefined && scopedBackup.chainId !== scope.chainId) ||
    (scopedBackup.recovery !== undefined && !isVaultBlob(scopedBackup.recovery))
  ) {
    throw new Error("Invalid vault backup");
  }
  let notes: VaultNote[];
  let recoveryOperations: PendingVaultOperation[];
  try {
    notes = await decryptNotes(key, backup);
    recoveryOperations =
      scopedBackup.recovery !== undefined
        ? await decryptPendingVaultOperations(key, scopedBackup.recovery)
        : [];
  } catch (err) {
    if (err instanceof Error && err.message === "Invalid vault backup") {
      throw err;
    }
    throw new Error("Invalid vault backup");
  }
  return enqueueVaultWrite(async () => {
    const operations = await loadPendingVaultOperations(scope, key);
    if (operations.length !== 0) {
      throw new Error("Resolve pending vault operations before importing a backup");
    }
    const db = await openDb();
    const previousBlob = await readVaultValue<VaultBlob>(db, vaultNotesId(scope));
    await saveVaultNotesUnsafe(scope, key, notes);
    try {
      await savePendingVaultOperations(scope, key, recoveryOperations);
    } catch (err) {
      if (previousBlob) {
        await writeVaultValue(db, vaultNotesId(scope), previousBlob);
      } else {
        await deleteVaultValue(db, vaultNotesId(scope));
      }
      throw err;
    }
  });
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
