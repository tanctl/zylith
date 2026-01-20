//! Zylith Association Set Provider (ASP): listens to ShieldedNotes events, maintains Merkle trees, and serves paths to clients.

mod events;
mod generated_constants;
mod merkle;
mod storage;

use std::collections::{HashMap, VecDeque};
use std::env;
use std::error::Error;
use std::net::SocketAddr;
use std::path::PathBuf;
use std::sync::Arc;

use axum::extract::{ConnectInfo, Path, Query, State};
use axum::http::{HeaderMap, StatusCode};
use axum::middleware::{self, Next};
use axum::response::IntoResponse;
use axum::routing::{get, post};
use axum::{Json, Router};
use serde::{Deserialize, Serialize};
use tokio::sync::{mpsc, RwLock};

use starknet::core::types::{BlockId, BlockTag, FieldElement as Felt, FunctionCall};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
use starknet::providers::Provider;
use url::Url;

use crate::events::{IndexerCommand, IndexerService, RateLimiter, RootCacheEntry, ROOT_CACHE_LIMIT};
use crate::merkle::MerkleTree;
use crate::storage::Storage;

#[derive(Clone)]
struct AppState {
    storage: Arc<Storage>,
    trees: Arc<RwLock<HashMap<String, MerkleTree>>>,
    resync_tx: mpsc::Sender<IndexerCommand>,
    rate_limiter: Arc<RateLimiter>,
    finality_depth: u64,
    sync_token: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Config {
    starknet_rpc_url: String,
    shielded_notes_address: String,
    start_block: u64,
    postgres_url: String,
    server_port: u16,
    finality_depth: u64,
    sync_token: Option<String>,
}

#[derive(Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Serialize)]
struct RootsResponse {
    roots: Vec<RootEntry>,
}

#[derive(Serialize)]
struct RootEntry {
    token: String,
    root: String,
}

#[derive(Deserialize)]
struct RootQuery {
    token: Option<String>,
}

#[derive(Serialize)]
struct RootAtResponse {
    token: String,
    root_index: u64,
    root: String,
    leaf_count: u64,
}

#[derive(Deserialize)]
struct PathRequest {
    commitment: String,
    root_index: Option<u64>,
    root_hash: Option<String>,
}

#[derive(Serialize)]
struct PathResponse {
    token: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Deserialize)]
struct InsertPathRequest {
    token: String,
}

#[derive(Serialize)]
struct InsertPathResponse {
    token: String,
    root: String,
    commitment: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Serialize)]
struct CommitmentResponse {
    token: String,
    leaf_index: u64,
}

#[derive(Serialize)]
struct CommitmentIndexResponse {
    token: String,
    leaf_index: u64,
    commitment: String,
}

#[derive(Serialize)]
struct SyncResponse {
    status: &'static str,
}

const MAX_ROOT_LOOKUP_STEPS: u64 = 512;

#[tokio::main]
async fn main() {
    if let Err(err) = run().await {
        eprintln!("[asp] fatal: {err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn Error>> {
    let config_path = std::env::var("ZYLITH_ASP_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("config.toml"));
    let config = load_config(&config_path).map_err(to_io_error)?;

    let storage = Arc::new(Storage::new(&config.postgres_url).await?);
    let tree_height = MerkleTree::default_height();
    let trees = Arc::new(RwLock::new(
        storage.load_trees(tree_height).await?,
    ));

    let recent_roots = storage
        .load_recent_roots(ROOT_CACHE_LIMIT)
        .await
        ?;
    let mut roots_cache: HashMap<String, VecDeque<RootCacheEntry>> = HashMap::new();
    for (token, entries) in recent_roots {
        let mut deque = VecDeque::new();
        for (_root_index, root_hash, _block_number, leaf_count) in entries {
            deque.push_back(RootCacheEntry {
                root_hash,
                leaf_count,
            });
        }
        roots_cache.insert(token, deque);
    }
    let roots_cache = Arc::new(RwLock::new(roots_cache));

    let (resync_tx, resync_rx) = mpsc::channel(4);
    let rpc_url = Url::parse(&config.starknet_rpc_url)
        .map_err(|err| to_io_error(format!("invalid starknet_rpc_url: {err}")))?;
    let provider = JsonRpcClient::new(HttpTransport::new(rpc_url));
    let shielded_notes = Felt::from_hex_be(&config.shielded_notes_address)
        .map_err(|err| to_io_error(format!("invalid shielded_notes_address: {err}")))?;
    let mut known_tokens = vec!["position".to_string()];
    match fetch_token_address(&provider, shielded_notes, "get_token0").await {
        Ok(token0) => known_tokens.push(felt_to_hex(&token0)),
        Err(err) => println!("[asp] warning: unable to fetch token0: {err}"),
    }
    match fetch_token_address(&provider, shielded_notes, "get_token1").await {
        Ok(token1) => known_tokens.push(felt_to_hex(&token1)),
        Err(err) => println!("[asp] warning: unable to fetch token1: {err}"),
    }
    known_tokens.sort();
    known_tokens.dedup();

    {
        let mut trees = trees.write().await;
        ensure_known_trees(&mut trees, tree_height, &known_tokens);
    }

    let indexer = IndexerService::new(
        provider,
        storage.clone(),
        trees.clone(),
        roots_cache.clone(),
        shielded_notes,
        config.start_block,
        tree_height,
        config.finality_depth,
        resync_rx,
        known_tokens,
    );
    tokio::spawn(async move { indexer.run().await });

    let rate_limiter = Arc::new(RateLimiter::new(100, std::time::Duration::from_secs(60)));
    let state = AppState {
        storage,
        trees,
        resync_tx,
        rate_limiter,
        finality_depth: config.finality_depth,
        sync_token: config.sync_token.clone(),
    };

    let app = Router::new()
        .route("/health", get(health))
        .route("/root", get(get_root))
        .route("/root/latest", get(get_root_latest))
        .route("/root/:index", get(get_root_at))
        .route("/path", post(get_path))
        .route("/insert_path", post(get_insert_path))
        .route("/commitment/:hash", get(get_commitment))
        .route("/commitment_by_index/:token/:index", get(get_commitment_by_index))
        .route("/sync", get(trigger_sync))
        .with_state(state.clone())
        .layer(middleware::from_fn_with_state(state, rate_limit));

    let addr = SocketAddr::from(([0, 0, 0, 0], config.server_port));
    println!("[asp] listening on {addr}");

    let listener = tokio::net::TcpListener::bind(addr).await?;
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>())
        .await?;
    Ok(())
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

async fn get_root(State(state): State<AppState>) -> Result<Json<RootsResponse>, StatusCode> {
    let max_block = finality_block(&state).await?;
    let trees = state.trees.read().await;
    let mut roots = Vec::new();
    for (token, tree) in trees.iter() {
        let root_hash = if state.finality_depth == 0 {
            match state
                .storage
                .get_latest_root(token)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            {
                Some((_, root_hash, _leaf_count)) => root_hash,
                None => tree
                    .root_at(0)
                    .map(|root| felt_to_hex(&root))
                    .unwrap_or_else(|| felt_to_hex(&tree.root())),
            }
        } else {
            match state
                .storage
                .get_latest_root_before(token, max_block)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            {
                Some((_, root_hash, _leaf_count, _block)) => root_hash,
                None => tree
                    .root_at(0)
                    .map(|root| felt_to_hex(&root))
                    .unwrap_or_else(|| felt_to_hex(&tree.root())),
            }
        };
        roots.push(RootEntry {
            token: token.clone(),
            root: root_hash,
        });
    }
    Ok(Json(RootsResponse { roots }))
}

async fn get_root_at(
    Path(index): Path<u64>,
    Query(query): Query<RootQuery>,
    State(state): State<AppState>,
) -> Result<Json<RootAtResponse>, StatusCode> {
    let token = query.token.ok_or(StatusCode::BAD_REQUEST)?;
    let max_block = finality_block(&state).await?;
    let (root_hash, root_leaf_count) = if state.finality_depth == 0 {
        let root = state
            .storage
            .get_root_at(&token, index)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .ok_or(StatusCode::NOT_FOUND)?;
        (root.0, root.1)
    } else {
        let root = state
            .storage
            .get_root_at_with_block(&token, index)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
            .ok_or(StatusCode::NOT_FOUND)?;
        if root.2 > max_block {
            return Err(StatusCode::NOT_FOUND);
        }
        (root.0, root.1)
    };
    let leaf_count = if root_leaf_count == 0 && index != 0 {
        let trees = state.trees.read().await;
        let tree = trees.get(&token).ok_or(StatusCode::NOT_FOUND)?;
        resolve_leaf_count_for_root_hash(
            state.storage.as_ref(),
            tree,
            &token,
            &root_hash,
            max_block,
            state.finality_depth != 0,
        )
            .await?
            .ok_or(StatusCode::NOT_FOUND)?
    } else {
        root_leaf_count
    };
    Ok(Json(RootAtResponse {
        token,
        root_index: index,
        root: root_hash,
        leaf_count,
    }))
}

async fn get_root_latest(
    Query(query): Query<RootQuery>,
    State(state): State<AppState>,
) -> Result<Json<RootAtResponse>, StatusCode> {
    let token = query.token.ok_or(StatusCode::BAD_REQUEST)?;
    let trees = state.trees.read().await;
    let tree = trees.get(&token).ok_or(StatusCode::NOT_FOUND)?;
    let tree_snapshot = tree.clone();
    let mut leaf_count = tree_snapshot.next_index();
    let root = tree_snapshot.root();
    let root_hex = felt_to_hex(&root);
    drop(trees);
    let max_block = finality_block(&state).await?;
    let mut root_index = 0u64;
    if state.finality_depth == 0 {
        if let Some((latest_index, latest_hash, latest_leaf_count)) = state
            .storage
            .get_latest_root(&token)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        {
            let expected_root = parse_felt(&latest_hash)?;
            if expected_root == root {
                root_index = latest_index;
                if latest_leaf_count != 0 {
                    leaf_count = latest_leaf_count;
                } else if leaf_count == 0 && root_index != 0 {
                    if let Some(resolved) = resolve_leaf_count_for_root_hash(
                        state.storage.as_ref(),
                        &tree_snapshot,
                        &token,
                        &latest_hash,
                        max_block,
                        false,
                    )
                    .await?
                    {
                        leaf_count = resolved;
                    }
                }
                if leaf_count == 0 && root_index != 0 {
                    root_index = 0;
                }
            }
        }
    } else if let Some((latest_index, latest_hash, latest_leaf_count, _block)) = state
        .storage
        .get_latest_root_before(&token, max_block)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
    {
        let expected_root = parse_felt(&latest_hash)?;
        if expected_root == root {
            root_index = latest_index;
            if latest_leaf_count != 0 {
                leaf_count = latest_leaf_count;
            } else if leaf_count == 0 && root_index != 0 {
                if let Some(resolved) = resolve_leaf_count_for_root_hash(
                    state.storage.as_ref(),
                    &tree_snapshot,
                    &token,
                    &latest_hash,
                    max_block,
                    true,
                )
                .await?
                {
                    leaf_count = resolved;
                }
            }
            if leaf_count == 0 && root_index != 0 {
                root_index = 0;
            }
        }
    }

    Ok(Json(RootAtResponse {
        token,
        root_index,
        root: root_hex,
        leaf_count,
    }))
}

async fn get_path(
    State(state): State<AppState>,
    Json(payload): Json<PathRequest>,
) -> Result<Json<PathResponse>, StatusCode> {
    if payload.root_index.is_some() && payload.root_hash.is_some() {
        return Err(StatusCode::BAD_REQUEST);
    }
    let mut max_block = finality_block(&state).await?;
    let commitment = payload.commitment;
    let found = state
        .storage
        .get_commitment(&commitment)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;
    let (token, leaf_index, commitment_block) = found;
    if commitment_block > max_block {
        max_block = commitment_block;
    }
    let trees = state.trees.read().await;
    let tree = trees.get(&token).ok_or(StatusCode::NOT_FOUND)?;
    let (expected_root, leaf_count) = if let Some(root_index) = payload.root_index {
        if state.finality_depth == 0 {
            let root = state
                .storage
                .get_root_at(&token, root_index)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
                .ok_or(StatusCode::NOT_FOUND)?;
            let expected_root = parse_felt(&root.0)?;
            let leaf_count = if root.1 == 0 {
                resolve_leaf_count_for_root_hash(
                    state.storage.as_ref(),
                    tree,
                    &token,
                    &root.0,
                    max_block,
                    false,
                )
                .await?
            } else {
                Some(root.1)
            };
            (Some(expected_root), leaf_count)
        } else {
            let root = state
                .storage
                .get_root_at_with_block(&token, root_index)
                .await
                .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
                .ok_or(StatusCode::NOT_FOUND)?;
            if root.2 > max_block {
                return Err(StatusCode::NOT_FOUND);
            }
            let expected_root = parse_felt(&root.0)?;
            let leaf_count = if root.1 == 0 {
                resolve_leaf_count_for_root_hash(
                    state.storage.as_ref(),
                    tree,
                    &token,
                    &root.0,
                    max_block,
                    true,
                )
                .await?
            } else {
                Some(root.1)
            };
            (Some(expected_root), leaf_count)
        }
    } else if let Some(root_hash) = payload.root_hash.as_deref() {
        let expected_root = parse_felt(root_hash)?;
        let leaf_count = resolve_leaf_count_for_root_hash(
            state.storage.as_ref(),
            tree,
            &token,
            root_hash,
            max_block,
            state.finality_depth != 0,
        )
        .await?;
        (Some(expected_root), leaf_count)
    } else {
        (Some(tree.root()), Some(tree.next_index()))
    };
    let leaf_count = leaf_count.ok_or(StatusCode::NOT_FOUND)?;
    if leaf_count == 0 {
        return Err(StatusCode::NOT_FOUND);
    }
    let (path, indices) = {
        if let Some(root) = expected_root {
            if let Some(expected) = tree.root_at(leaf_count) {
                if expected != root {
                    return Err(StatusCode::INTERNAL_SERVER_ERROR);
                }
            }
        }
        tree.get_path_at(leaf_index, leaf_count)
            .ok_or(StatusCode::NOT_FOUND)?
    };
    let path_hex = path.into_iter().map(|felt| felt_to_hex(&felt)).collect();
    Ok(Json(PathResponse {
        token,
        leaf_index,
        path: path_hex,
        indices,
    }))
}

async fn get_insert_path(
    State(state): State<AppState>,
    Json(payload): Json<InsertPathRequest>,
) -> Result<Json<InsertPathResponse>, StatusCode> {
    let trees = state.trees.read().await;
    let tree = trees.get(&payload.token).ok_or(StatusCode::NOT_FOUND)?;
    let leaf_count = tree.next_index();
    let root_hash = felt_to_hex(&tree.root());
    let (leaf_index, path, indices) = tree
        .insertion_path_at(leaf_count)
        .ok_or(StatusCode::BAD_REQUEST)?;
    let path_hex = path.into_iter().map(|felt| felt_to_hex(&felt)).collect();
    Ok(Json(InsertPathResponse {
        token: payload.token,
        root: root_hash,
        commitment: felt_to_hex(&merkle::zero_leaf_hash()),
        leaf_index,
        path: path_hex,
        indices,
    }))
}

async fn resolve_leaf_count_for_root_hash(
    storage: &Storage,
    tree: &MerkleTree,
    token: &str,
    root_hash: &str,
    max_block: u64,
    enforce_block: bool,
) -> Result<Option<u64>, StatusCode> {
    if enforce_block {
        let stored = storage
            .get_root_by_hash_with_block(token, root_hash)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        if let Some((root_index, leaf_count, block_number)) = stored {
            if block_number > max_block {
                return Ok(None);
            }
            if leaf_count != 0 || root_index == 0 {
                return Ok(Some(leaf_count));
            }
        }
    } else {
        let stored = storage
            .get_root_by_hash(token, root_hash)
            .await
            .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?;
        if let Some((root_index, leaf_count)) = stored {
            if leaf_count != 0 || root_index == 0 {
                return Ok(Some(leaf_count));
            }
        }
    }

    let root_felt = parse_felt(root_hash)?;
    if tree.root() == root_felt {
        return Ok(Some(tree.next_index()));
    }

    let last_flushed = storage
        .get_latest_leaf_count(token)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .unwrap_or(0);
    let current_leaf_count = tree.next_index();
    let pending = current_leaf_count.saturating_sub(last_flushed);
    if pending > MAX_ROOT_LOOKUP_STEPS {
        return Ok(None);
    }
    if current_leaf_count <= last_flushed {
        return Ok(None);
    }
    let mut leaf_count = last_flushed + 1;
    while leaf_count <= current_leaf_count {
        if let Some(root) = tree.root_at(leaf_count) {
            if root == root_felt {
                return Ok(Some(leaf_count));
            }
        }
        leaf_count += 1;
    }
    Ok(None)
}

async fn get_commitment(
    Path(hash): Path<String>,
    State(state): State<AppState>,
) -> Result<Json<CommitmentResponse>, StatusCode> {
    let max_block = finality_block(&state).await?;
    let found = state
        .storage
        .get_commitment(&hash)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;
    if found.2 > max_block {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(CommitmentResponse {
        token: found.0,
        leaf_index: found.1,
    }))
}

async fn get_commitment_by_index(
    Path((token, index)): Path<(String, u64)>,
    State(state): State<AppState>,
) -> Result<Json<CommitmentIndexResponse>, StatusCode> {
    let max_block = finality_block(&state).await?;
    let found = state
        .storage
        .get_commitment_by_index(&token, index)
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .ok_or(StatusCode::NOT_FOUND)?;
    if state.finality_depth != 0 && found.1 > max_block {
        return Err(StatusCode::NOT_FOUND);
    }
    Ok(Json(CommitmentIndexResponse {
        token,
        leaf_index: index,
        commitment: found.0,
    }))
}

async fn trigger_sync(
    State(state): State<AppState>,
    headers: HeaderMap,
) -> Result<Json<SyncResponse>, StatusCode> {
    if let Some(expected) = state.sync_token.as_deref() {
        let provided = headers
            .get("x-sync-token")
            .and_then(|value| value.to_str().ok());
        if provided != Some(expected) {
            return Err(StatusCode::UNAUTHORIZED);
        }
    }
    state
        .resync_tx
        .send(IndexerCommand::Resync)
        .await
        .map_err(|_| StatusCode::SERVICE_UNAVAILABLE)?;
    Ok(Json(SyncResponse { status: "queued" }))
}

async fn rate_limit(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: axum::http::Request<axum::body::Body>,
    next: Next,
) -> Result<impl IntoResponse, StatusCode> {
    if !state.rate_limiter.allow(addr.ip()).await {
        return Err(StatusCode::TOO_MANY_REQUESTS);
    }
    Ok(next.run(req).await)
}

async fn finality_block(state: &AppState) -> Result<u64, StatusCode> {
    let latest = state
        .storage
        .get_last_block()
        .await
        .map_err(|_| StatusCode::INTERNAL_SERVER_ERROR)?
        .unwrap_or(0);
    Ok(latest.saturating_sub(state.finality_depth))
}

fn load_config(path: &PathBuf) -> Result<Config, String> {
    let contents = std::fs::read_to_string(path)
        .map_err(|err| format!("read config: {err}"))?;
    let mut map: HashMap<String, String> = HashMap::new();
    for raw_line in contents.lines() {
        let line = strip_comments(raw_line).trim().to_string();
        if line.is_empty() {
            continue;
        }
        let (key, value) = line
            .split_once('=')
            .ok_or_else(|| format!("invalid config line: {line}"))?;
        let key = key.trim().to_string();
        let mut value = value.trim().trim_end_matches(',').to_string();
        if value.starts_with('"') && value.ends_with('"') && value.len() >= 2 {
            value = value[1..value.len() - 1].to_string();
        }
        map.insert(key, value);
    }

    let starknet_rpc_url = get_required(&map, "starknet_rpc_url")?;
    let shielded_notes_address = get_required(&map, "shielded_notes_address")?;
    let start_block = parse_u64(&get_required(&map, "start_block")?, "start_block")?;
    let postgres_url = get_required(&map, "postgres_url")?;
    let server_port = parse_u16(&get_required(&map, "server_port")?, "server_port")?;
    let finality_depth = parse_u64(&get_required(&map, "finality_depth")?, "finality_depth")?;
    let sync_token = map
        .get("sync_token")
        .cloned()
        .and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        });
    if sync_token.is_none() && !is_dev_mode() {
        return Err("sync_token must be set unless ENV=dev or ENV=test".to_string());
    }

    Ok(Config {
        starknet_rpc_url,
        shielded_notes_address,
        start_block,
        postgres_url,
        server_port,
        finality_depth,
        sync_token,
    })
}

fn is_dev_mode() -> bool {
    match env::var("ENV") {
        Ok(value) => matches!(value.as_str(), "dev" | "test"),
        Err(_) => false,
    }
}

fn strip_comments(raw_line: &str) -> String {
    let mut out = String::new();
    let mut chars = raw_line.chars().peekable();
    let mut in_string = false;
    let mut escaped = false;
    while let Some(ch) = chars.next() {
        if in_string {
            if escaped {
                escaped = false;
                out.push(ch);
                continue;
            }
            if ch == '\\' {
                escaped = true;
                out.push(ch);
                continue;
            }
            if ch == '"' {
                in_string = false;
            }
            out.push(ch);
            continue;
        }
        if ch == '"' {
            in_string = true;
            out.push(ch);
            continue;
        }
        if ch == '#' {
            break;
        }
        if ch == '/' {
            if let Some('/') = chars.peek() {
                break;
            }
        }
        out.push(ch);
    }
    out
}

fn get_required(map: &HashMap<String, String>, key: &str) -> Result<String, String> {
    map.get(key)
        .cloned()
        .ok_or_else(|| format!("missing config key: {key}"))
}

fn parse_u64(value: &str, key: &str) -> Result<u64, String> {
    value
        .parse::<u64>()
        .map_err(|err| format!("invalid {key}: {err}"))
}

fn parse_u16(value: &str, key: &str) -> Result<u16, String> {
    value
        .parse::<u16>()
        .map_err(|err| format!("invalid {key}: {err}"))
}

fn to_io_error(message: impl Into<String>) -> std::io::Error {
    std::io::Error::new(std::io::ErrorKind::Other, message.into())
}

async fn fetch_token_address(
    provider: &JsonRpcClient<HttpTransport>,
    shielded_notes: Felt,
    entrypoint: &str,
) -> Result<Felt, String> {
    let call = FunctionCall {
        contract_address: shielded_notes,
        entry_point_selector: get_selector_from_name(entrypoint)
            .map_err(|err| format!("selector {entrypoint}: {err}"))?,
        calldata: Vec::new(),
    };
    let result = provider
        .call(call, BlockId::Tag(BlockTag::Latest))
        .await
        .map_err(|err| format!("call {entrypoint}: {err}"))?;
    result
        .get(0)
        .copied()
        .ok_or_else(|| format!("call {entrypoint}: empty response"))
}

fn ensure_known_trees(
    trees: &mut HashMap<String, MerkleTree>,
    height: usize,
    known_tokens: &[String],
) {
    for token in known_tokens {
        trees
            .entry(token.clone())
            .or_insert_with(|| MerkleTree::new(height));
    }
}

fn felt_to_hex(value: &Felt) -> String {
    format!("0x{:x}", value)
}

fn parse_felt(value: &str) -> Result<Felt, StatusCode> {
    Felt::from_hex_be(value).map_err(|_| StatusCode::BAD_REQUEST)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::storage::CommitmentRecord;
    use starknet_crypto::poseidon_hash;
    use std::env;
    use std::time::Duration;

    #[tokio::test]
    async fn root_latest_matches_path() {
        let db_url = match env::var("ZYLITH_ASP_TEST_DB") {
            Ok(value) => value,
            Err(_) => {
                eprintln!("ZYLITH_ASP_TEST_DB not set; skipping integration test");
                return;
            }
        };

        let storage = Storage::new(&db_url).await.expect("storage");
        storage.reset().await.expect("reset");

        let tree_height = MerkleTree::default_height();
        let mut tree = MerkleTree::new(tree_height);
        let token = "0x1".to_string();
        let commitments = [Felt::from(123u64), Felt::from(456u64)];

        for (index, commitment) in commitments.iter().enumerate() {
            tree.insert_at(index as u64, *commitment).expect("insert");
            let record = CommitmentRecord {
                token: token.clone(),
                leaf_index: index as u64,
                commitment: felt_to_hex(commitment),
                timestamp: 1,
                block_number: 1,
            };
            storage
                .insert_commitment(record)
                .await
                .expect("insert commitment");
        }

        let mut trees = HashMap::new();
        trees.insert(token.clone(), tree);
        let trees = Arc::new(RwLock::new(trees));
        let (resync_tx, _resync_rx) = mpsc::channel(1);
        let state = AppState {
            storage: Arc::new(storage),
            trees,
            resync_tx,
            rate_limiter: Arc::new(RateLimiter::new(100, Duration::from_secs(60))),
            finality_depth: 0,
        };

        let Json(root_response) = get_root_latest(
            Query(RootQuery {
                token: Some(token.clone()),
            }),
            State(state.clone()),
        )
        .await
        .expect("root latest");
        assert_eq!(root_response.token, token);
        assert_eq!(root_response.root_index, commitments.len() as u64);
        let root = parse_felt(&root_response.root).expect("root");

        let commitment_hex = felt_to_hex(&commitments[1]);
        let Json(path_response) = get_path(
            State(state),
            Json(PathRequest {
                commitment: commitment_hex,
                root_index: None,
                root_hash: None,
            }),
        )
        .await
        .expect("path");
        assert_eq!(path_response.token, token);
        assert_eq!(path_response.leaf_index, 1);

        let path: Vec<Felt> = path_response
            .path
            .iter()
            .map(|value| Felt::from_hex_be(value).expect("path element"))
            .collect();
        let mut current = commitments[1];
        for (sibling, is_right) in path.iter().zip(path_response.indices.iter()) {
            let (left, right) = if *is_right {
                (*sibling, current)
            } else {
                (current, *sibling)
            };
            current = poseidon_hash(left, right);
        }

        assert_eq!(current, root);
    }
}
