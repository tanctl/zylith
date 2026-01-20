//! event indexer for ShieldedNotes

use std::collections::{HashMap, VecDeque};
use std::net::IpAddr;
use std::sync::Arc;

use tokio::sync::{mpsc, RwLock};
use tokio::time::{Duration, Interval};

use starknet::core::types::{BlockId, EmittedEvent, EventFilter, FieldElement as Felt};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
use starknet::providers::Provider;

use crate::merkle::{MerkleError, MerkleTree};
use crate::storage::{CommitmentRecord, RootRecord, Storage, StorageError};

pub const ROOT_CACHE_LIMIT: usize = 256;
const MAX_ROOT_LOOKUP_STEPS: u64 = 512;

#[derive(Debug, Clone)]
pub struct RootCacheEntry {
    pub root_hash: String,
    pub leaf_count: u64,
}

#[derive(Debug)]
pub enum IndexerCommand {
    Resync,
}

pub struct IndexerService {
    provider: JsonRpcClient<HttpTransport>,
    storage: Arc<Storage>,
    trees: Arc<RwLock<HashMap<String, MerkleTree>>>,
    roots_cache: Arc<RwLock<HashMap<String, VecDeque<RootCacheEntry>>>>,
    shielded_notes: Felt,
    start_block: u64,
    tree_height: usize,
    finality_depth: u64,
    interval: Interval,
    command_rx: mpsc::Receiver<IndexerCommand>,
    known_tokens: Vec<String>,
}

impl IndexerService {
    pub fn new(
        provider: JsonRpcClient<HttpTransport>,
        storage: Arc<Storage>,
        trees: Arc<RwLock<HashMap<String, MerkleTree>>>,
        roots_cache: Arc<RwLock<HashMap<String, VecDeque<RootCacheEntry>>>>,
        shielded_notes: Felt,
        start_block: u64,
        tree_height: usize,
        finality_depth: u64,
        command_rx: mpsc::Receiver<IndexerCommand>,
        known_tokens: Vec<String>,
    ) -> Self {
        Self {
            provider,
            storage,
            trees,
            roots_cache,
            shielded_notes,
            start_block,
            tree_height,
            finality_depth,
            interval: tokio::time::interval(Duration::from_secs(12)),
            command_rx,
            known_tokens,
        }
    }

    pub async fn run(mut self) {
        loop {
            tokio::select! {
                _ = self.interval.tick() => {
                    if let Err(err) = self.sync_once().await {
                        match err {
                            StorageError::Desync(reason) | StorageError::Invariant(reason) => {
                                println!("[asp] desync detected: {reason}");
                                if let Err(err) = self.resync().await {
                                    println!("[asp] resync error: {:?}", err);
                                }
                            }
                            other => {
                                println!("[asp] sync error: {:?}", other);
                            }
                        }
                    }
                }
                cmd = self.command_rx.recv() => {
                    if let Some(cmd) = cmd {
                        match cmd {
                            IndexerCommand::Resync => {
                                if let Err(err) = self.resync().await {
                                    println!("[asp] resync error: {:?}", err);
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    async fn resync(&self) -> Result<(), StorageError> {
        println!("[asp] resync requested");
        self.storage.reset().await?;
        let mut trees = self.trees.write().await;
        trees.clear();
        let mut roots_cache = self.roots_cache.write().await;
        roots_cache.clear();
        drop(roots_cache);
        drop(trees);
        self.sync_once().await?;
        Ok(())
    }

    async fn sync_once(&self) -> Result<(), StorageError> {
        let last_block = self.storage.get_last_block().await?;
        let finality_depth = self.finality_depth;
        let latest = self.provider.block_number().await.map_err(|err| {
            StorageError::Db(format!("starknet block_number error: {err}"))
        })?;
        let safe_latest = latest.saturating_sub(finality_depth);
        if let Some(block) = last_block {
            if block > safe_latest {
                return Err(StorageError::Desync(format!(
                    "reorg deeper than finality depth detected (last_indexed={}, safe_latest={}, finality_depth={})",
                    block, safe_latest, finality_depth
                )));
            }
        }

        let from_block = match last_block {
            Some(block) if block > self.start_block => block,
            Some(block) => block,
            None => self.start_block,
        };

        if last_block.is_some() {
            let rebuilt = self.storage.load_trees(self.tree_height).await?;
            let mut trees = self.trees.write().await;
            *trees = rebuilt;
            self.ensure_known_trees(&mut trees);
            let recent_roots = self.storage.load_recent_roots(ROOT_CACHE_LIMIT).await?;
            let mut roots_cache = self.roots_cache.write().await;
            roots_cache.clear();
            for (token, entries) in recent_roots {
                let mut deque = VecDeque::new();
                for (_root_index, root_hash, _block_number, leaf_count) in entries {
                    deque.push_back(RootCacheEntry { root_hash, leaf_count });
                }
                roots_cache.insert(token, deque);
            }
        } else {
            let mut trees = self.trees.write().await;
            self.ensure_known_trees(&mut trees);
        }

        if from_block > safe_latest {
            return Ok(());
        }

        let mut continuation: Option<String> = None;
        loop {
            let filter = EventFilter {
                from_block: Some(BlockId::Number(from_block)),
                to_block: Some(BlockId::Number(safe_latest)),
                address: Some(self.shielded_notes),
                keys: None,
            };
            let page = self
                .provider
                .get_events(filter, continuation.clone(), 1000)
                .await
                .map_err(|err| StorageError::Db(format!("starknet get_events error: {err}")))?;
            for emitted in page.events {
                self.process_event(emitted).await?;
            }
            continuation = page.continuation_token;
            if continuation.is_none() {
                break;
            }
        }

        self.storage.set_last_block(safe_latest).await?;
        Ok(())
    }

    async fn process_event(&self, emitted: EmittedEvent) -> Result<(), StorageError> {
        let block_number = emitted.block_number.unwrap_or_default();
        if emitted.keys.is_empty() {
            return Ok(());
        }

        let deposit_key = selector("Deposit");
        let root_key = selector("RootUpdated");
        let position_commitment_key = selector("PositionCommitmentInserted");
        let position_root_key = selector("PositionRootUpdated");
        let nullifier_key = selector("NullifierUsed");
        let nullifier_marked_key = selector("NullifierMarked");
        let key = emitted.keys[0];

        if key == deposit_key {
            self.handle_deposit(&emitted.data, block_number).await?;
        } else if key == root_key {
            self.handle_root_updated(&emitted.data, block_number).await?;
        } else if key == position_commitment_key {
            self.handle_position_commitment(&emitted.data, block_number).await?;
        } else if key == position_root_key {
            self.handle_position_root_updated(&emitted.data, block_number).await?;
        } else if key == nullifier_key || key == nullifier_marked_key {
            self.handle_nullifier_used(&emitted.data, block_number).await?;
        }
        Ok(())
    }

    async fn handle_deposit(&self, data: &[Felt], block_number: u64) -> Result<(), StorageError> {
        if data.len() < 4 {
            return Ok(());
        }
        let commitment = data[0];
        let leaf_index = felt_to_u64(&data[1])?;
        let token = data[2];
        let timestamp = felt_to_u64(&data[3])?;

        let token_hex = felt_to_hex(&token);
        let commitment_hex = felt_to_hex(&commitment);
        let record = CommitmentRecord {
            token: token_hex.clone(),
            leaf_index,
            commitment: commitment_hex.clone(),
            timestamp,
            block_number,
        };
        let inserted = self.storage.insert_commitment(record).await?;
        let mut trees = self.trees.write().await;
        let tree = trees
            .entry(token_hex.clone())
            .or_insert_with(|| MerkleTree::new(self.tree_height));
        let new_root = match tree.insert_at(leaf_index, commitment) {
            Ok((_, root)) => root,
            Err(MerkleError::LeafMismatch { .. }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle leaf mismatch for deposit {}",
                    commitment_hex
                )));
            }
            Err(MerkleError::IndexGap { expected, got }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle index gap for deposit expected {expected} got {got}"
                )));
            }
            Err(MerkleError::TreeFull { max }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle tree full for deposit max_leaves={max}"
                )));
            }
            Err(MerkleError::InvalidLeaf { reason }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle invalid leaf for deposit reason={reason}"
                )));
            }
        };
        let leaf_count = tree.next_index();
        let new_root_hex = felt_to_hex(&new_root);
        drop(trees);
        self.storage
            .update_root_leaf_count(&token_hex, &new_root_hex, leaf_count)
            .await?;
        self.update_root_cache_leaf_count(&token_hex, &new_root_hex, leaf_count)
            .await;
        if let Some(entry) = self
            .roots_cache
            .read()
            .await
            .get(&token_hex)
            .and_then(|entries| entries.iter().find(|entry| entry.leaf_count == leaf_count))
        {
            if entry.root_hash != felt_to_hex(&new_root) {
                return Err(StorageError::Desync(format!(
                    "root mismatch token={} expected={} onchain={}",
                    token_hex,
                    felt_to_hex(&new_root),
                    entry.root_hash
                )));
            }
        }
        if inserted {
            println!(
                "[asp] deposit token={} index={} commitment={}",
                token_hex, leaf_index, commitment_hex
            );
        }
        Ok(())
    }

    async fn handle_root_updated(&self, data: &[Felt], block_number: u64) -> Result<(), StorageError> {
        if data.len() < 4 {
            return Ok(());
        }
        let old_root = data[0];
        let new_root = data[1];
        let root_index = felt_to_u64(&data[2])?;
        let token = data[3];

        let token_hex = felt_to_hex(&token);
        let last_flushed = self.storage.get_latest_leaf_count(&token_hex).await?.unwrap_or(0);
        let (leaf_count, expected_root) = {
            let mut trees = self.trees.write().await;
            let tree = trees
                .entry(token_hex.clone())
                .or_insert_with(|| MerkleTree::new(self.tree_height));
            let leaf_count = resolve_leaf_count_for_root(tree, new_root, last_flushed);
            let expected_root = leaf_count.and_then(|count| tree.root_at(count));
            (leaf_count, expected_root)
        };
        let (leaf_count, leaf_count_resolved) = match leaf_count {
            Some(count) => (count, true),
            None => {
                println!(
                    "[asp] warning: root leaf count unresolved token={} root={}",
                    token_hex,
                    felt_to_hex(&new_root)
                );
                (0, false)
            }
        };
        let new_root_hex = felt_to_hex(&new_root);
        let record = RootRecord {
            token: token_hex.clone(),
            root_index,
            root_hash: new_root_hex.clone(),
            block_number,
            leaf_count,
        };
        let inserted = self.storage.insert_root(record).await?;
        let mut roots_cache = self.roots_cache.write().await;
        let entry = roots_cache.entry(token_hex.clone()).or_insert_with(VecDeque::new);
        entry.push_front(RootCacheEntry {
            root_hash: new_root_hex.clone(),
            leaf_count,
        });
        if entry.len() > ROOT_CACHE_LIMIT {
            entry.truncate(ROOT_CACHE_LIMIT);
        }
        drop(roots_cache);

        if let Some(expected_root) = expected_root {
            if expected_root != new_root {
                return Err(StorageError::Desync(format!(
                    "root mismatch token={} expected={} onchain={}",
                    token_hex,
                    felt_to_hex(&expected_root),
                    new_root_hex
                )));
            }
        }
        if inserted {
            if leaf_count_resolved {
                println!(
                    "[asp] root updated token={} index={} new_root={}",
                    token_hex, root_index, new_root_hex
                );
            } else {
                println!(
                    "[asp] root updated token={} index={} new_root={} leaf_count=pending",
                    token_hex, root_index, new_root_hex
                );
            }
        }
        let _ = old_root;
        Ok(())
    }

    async fn handle_position_commitment(
        &self,
        data: &[Felt],
        block_number: u64,
    ) -> Result<(), StorageError> {
        if data.len() < 3 {
            return Ok(());
        }
        let commitment = data[0];
        let leaf_index = felt_to_u64(&data[1])?;
        let timestamp = felt_to_u64(&data[2])?;
        let token_hex = "position".to_string();
        let commitment_hex = felt_to_hex(&commitment);
        let record = CommitmentRecord {
            token: token_hex.clone(),
            leaf_index,
            commitment: commitment_hex.clone(),
            timestamp,
            block_number,
        };
        let inserted = self.storage.insert_commitment(record).await?;
        let mut trees = self.trees.write().await;
        let tree = trees
            .entry(token_hex.clone())
            .or_insert_with(|| MerkleTree::new(self.tree_height));
        let new_root = match tree.insert_at(leaf_index, commitment) {
            Ok((_, root)) => root,
            Err(MerkleError::LeafMismatch { .. }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle leaf mismatch for position commitment {}",
                    commitment_hex
                )));
            }
            Err(MerkleError::IndexGap { expected, got }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle index gap for position commitment expected {expected} got {got}"
                )));
            }
            Err(MerkleError::TreeFull { max }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle tree full for position commitment max_leaves={max}"
                )));
            }
            Err(MerkleError::InvalidLeaf { reason }) => {
                return Err(StorageError::Invariant(format!(
                    "merkle invalid leaf for position commitment reason={reason}"
                )));
            }
        };
        let leaf_count = tree.next_index();
        let new_root_hex = felt_to_hex(&new_root);
        drop(trees);
        self.storage
            .update_root_leaf_count(&token_hex, &new_root_hex, leaf_count)
            .await?;
        self.update_root_cache_leaf_count(&token_hex, &new_root_hex, leaf_count)
            .await;
        if let Some(entry) = self
            .roots_cache
            .read()
            .await
            .get(&token_hex)
            .and_then(|entries| entries.iter().find(|entry| entry.leaf_count == leaf_count))
        {
            if entry.root_hash != felt_to_hex(&new_root) {
                return Err(StorageError::Desync(format!(
                    "root mismatch token={} expected={} onchain={}",
                    token_hex,
                    felt_to_hex(&new_root),
                    entry.root_hash
                )));
            }
        }
        if inserted {
            println!(
                "[asp] position commitment index={} commitment={}",
                leaf_index, commitment_hex
            );
        }
        Ok(())
    }

    async fn handle_position_root_updated(
        &self,
        data: &[Felt],
        block_number: u64,
    ) -> Result<(), StorageError> {
        if data.len() < 3 {
            return Ok(());
        }
        let old_root = data[0];
        let new_root = data[1];
        let root_index = felt_to_u64(&data[2])?;
        let token_hex = "position".to_string();
        let last_flushed = self.storage.get_latest_leaf_count(&token_hex).await?.unwrap_or(0);
        let (leaf_count, expected_root) = {
            let mut trees = self.trees.write().await;
            let tree = trees
                .entry(token_hex.clone())
                .or_insert_with(|| MerkleTree::new(self.tree_height));
            let leaf_count = resolve_leaf_count_for_root(tree, new_root, last_flushed);
            let expected_root = leaf_count.and_then(|count| tree.root_at(count));
            (leaf_count, expected_root)
        };
        let (leaf_count, leaf_count_resolved) = match leaf_count {
            Some(count) => (count, true),
            None => {
                println!(
                    "[asp] warning: position root leaf count unresolved root={}",
                    felt_to_hex(&new_root)
                );
                (0, false)
            }
        };
        let new_root_hex = felt_to_hex(&new_root);
        let record = RootRecord {
            token: token_hex.clone(),
            root_index,
            root_hash: new_root_hex.clone(),
            block_number,
            leaf_count,
        };
        let inserted = self.storage.insert_root(record).await?;
        let mut roots_cache = self.roots_cache.write().await;
        let entry = roots_cache.entry(token_hex.clone()).or_insert_with(VecDeque::new);
        entry.push_front(RootCacheEntry {
            root_hash: new_root_hex.clone(),
            leaf_count,
        });
        if entry.len() > ROOT_CACHE_LIMIT {
            entry.truncate(ROOT_CACHE_LIMIT);
        }
        drop(roots_cache);

        if let Some(expected_root) = expected_root {
            if expected_root != new_root {
                return Err(StorageError::Desync(format!(
                    "root mismatch token={} expected={} onchain={}",
                    token_hex,
                    felt_to_hex(&expected_root),
                    new_root_hex
                )));
            }
        }
        if inserted {
            if leaf_count_resolved {
                println!(
                    "[asp] root updated token={} index={} new_root={}",
                    token_hex, root_index, new_root_hex
                );
            } else {
                println!(
                    "[asp] root updated token={} index={} new_root={} leaf_count=pending",
                    token_hex, root_index, new_root_hex
                );
            }
        }
        let _ = old_root;
        Ok(())
    }

    async fn handle_nullifier_used(
        &self,
        data: &[Felt],
        block_number: u64,
    ) -> Result<(), StorageError> {
        if data.is_empty() {
            return Ok(());
        }
        let nullifier = data[0];
        let nullifier_hex = felt_to_hex(&nullifier);
        self.storage.insert_nullifier(&nullifier_hex, block_number).await?;
        println!("[asp] nullifier used {}", nullifier_hex);
        Ok(())
    }

    fn ensure_known_trees(&self, trees: &mut HashMap<String, MerkleTree>) {
        for token in &self.known_tokens {
            trees
                .entry(token.clone())
                .or_insert_with(|| MerkleTree::new(self.tree_height));
        }
    }

    async fn update_root_cache_leaf_count(
        &self,
        token_hex: &str,
        root_hash: &str,
        leaf_count: u64,
    ) {
        let mut roots_cache = self.roots_cache.write().await;
        if let Some(entries) = roots_cache.get_mut(token_hex) {
            for entry in entries.iter_mut() {
                if entry.root_hash == root_hash && entry.leaf_count == 0 {
                    entry.leaf_count = leaf_count;
                }
            }
        }
    }

}

fn resolve_leaf_count_for_root(
    tree: &MerkleTree,
    root: Felt,
    last_flushed: u64,
) -> Option<u64> {
    let current = tree.next_index();
    if tree.root() == root {
        return Some(current);
    }
    if current <= last_flushed {
        return None;
    }
    let pending = current.saturating_sub(last_flushed);
    if pending > MAX_ROOT_LOOKUP_STEPS {
        return None;
    }
    let mut leaf_count = last_flushed.saturating_add(1);
    while leaf_count <= current {
        if let Some(candidate) = tree.root_at(leaf_count) {
            if candidate == root {
                return Some(leaf_count);
            }
        }
        leaf_count += 1;
    }
    None
}

fn selector(name: &str) -> Felt {
    get_selector_from_name(name).expect("selector")
}

fn felt_to_hex(value: &Felt) -> String {
    format!("0x{:x}", value)
}

fn felt_to_u64(value: &Felt) -> Result<u64, StorageError> {
    let bytes = value.to_bytes_be();
    if bytes[..24].iter().any(|b| *b != 0) {
        return Err(StorageError::Invariant("felt overflow".to_string()));
    }
    let mut tail = [0u8; 8];
    tail.copy_from_slice(&bytes[24..]);
    Ok(u64::from_be_bytes(tail))
}

pub struct RateLimiter {
    limit: u32,
    window: Duration,
    entries: tokio::sync::Mutex<HashMap<IpAddr, (u32, tokio::time::Instant)>>,
}

impl RateLimiter {
    pub fn new(limit: u32, window: Duration) -> Self {
        Self {
            limit,
            window,
            entries: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    pub async fn allow(&self, ip: IpAddr) -> bool {
        let mut entries = self.entries.lock().await;
        let now = tokio::time::Instant::now();
        entries.retain(|_, (_, seen)| now.duration_since(*seen) < self.window);
        let entry = entries.entry(ip).or_insert((0, now));
        if now.duration_since(entry.1) >= self.window {
            *entry = (0, now);
        }
        if entry.0 >= self.limit {
            return false;
        }
        entry.0 += 1;
        true
    }
}
