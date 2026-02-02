use std::collections::HashMap;
use std::error::Error;
use std::fs;
use std::net::{IpAddr, SocketAddr};
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::time::{Duration, Instant};

use axum::body::Body;
use axum::extract::{ConnectInfo, DefaultBodyLimit, State};
use axum::http::{header, HeaderName, HeaderValue, Method, Request, StatusCode};
use axum::middleware::{from_fn_with_state, Next};
use axum::response::{IntoResponse, Response};
use axum::routing::{get, post};
use axum::{Json, Router};
use num_bigint::BigUint;
use num_traits::Num;
use serde::{Deserialize, Serialize};
use std::sync::Mutex;
use tokio::sync::Semaphore;
use tower_http::cors::{Any, CorsLayer};
use tower_http::timeout::TimeoutLayer;
use tower_http::trace::TraceLayer;
use tracing::{error, info};
use tracing_subscriber::EnvFilter;
use url::Url;

use async_trait::async_trait;
use starknet::accounts::{Account, ConnectedAccount, ExecutionEncoder, ExecutionEncoding};
use starknet::core::types::{BlockId, BlockTag, Call, Felt, FunctionCall, U256};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
use starknet::providers::Provider;

use zylith_client::{
    compute_commitment, generate_note_with_token_id, generate_nullifier_hash, parse_felt,
    quote_liquidity_amounts, ClientError,
    LiquidityAddProveRequest, LiquidityClaimProveRequest, LiquidityProveResult,
    LiquidityRemoveProveRequest, MerklePath, Note, PoolConfig, PositionNote, SignedAmount,
    SwapProveRequest, SwapStepQuote, ZylithClient, ZylithConfig, MAX_INPUT_NOTES,
};
use zylith_prover::{
    prove_deposit as prove_deposit_proof, prove_withdraw as prove_withdraw_proof,
    DepositWitnessInputs, WithdrawWitnessInputs, WitnessValue,
};

#[derive(Clone)]
struct AppState {
    account: ReadOnlyAccount<JsonRpcClient<HttpTransport>>,
    config: Arc<AppConfig>,
    limiter: Arc<Semaphore>,
    rate_limiter: Arc<RateLimiter>,
}

#[derive(Debug, Deserialize)]
struct RawConfig {
    rpc_url: String,
    asp_url: String,
    pool_address: String,
    shielded_notes_address: String,
    token0: String,
    token1: String,
    chain_id: Option<String>,
    bind_addr: String,
    artifacts_dir: String,
    max_concurrent_proofs: usize,
    request_timeout_secs: u64,
    max_body_bytes: usize,
    cors_allow_origins: Vec<String>,
    rate_limit_per_minute: u64,
    rate_limit_burst: u64,
    api_key: Option<String>,
    trust_proxy: Option<bool>,
}

#[derive(Clone)]
struct AppConfig {
    asp_url: String,
    pool_address: Felt,
    shielded_notes_address: Felt,
    token0: Felt,
    token1: Felt,
    chain_id: Felt,
    bind_addr: SocketAddr,
    artifacts_dir: PathBuf,
    max_concurrent_proofs: usize,
    request_timeout: Duration,
    max_body_bytes: usize,
    cors_allow_origins: Vec<String>,
    rate_limit_per_minute: u64,
    rate_limit_burst: u64,
    api_key: Option<String>,
    trust_proxy: bool,
}

#[derive(Debug, Serialize)]
struct HealthResponse {
    status: &'static str,
}

#[derive(Debug, Deserialize)]
struct NoteInput {
    secret: String,
    nullifier: String,
    amount: String,
    token: String,
}

#[derive(Debug, Serialize)]
struct NoteOutput {
    secret: String,
    nullifier: String,
    amount: String,
    token: String,
}

#[derive(Debug, Deserialize)]
struct PositionNoteInput {
    secret: String,
    nullifier: String,
    tick_lower: i32,
    tick_upper: i32,
    liquidity: String,
    fee_growth_inside_0: String,
    fee_growth_inside_1: String,
}

#[derive(Debug, Serialize)]
struct PositionNoteOutput {
    secret: String,
    nullifier: String,
    tick_lower: i32,
    tick_upper: i32,
    liquidity: String,
    fee_growth_inside_0: String,
    fee_growth_inside_1: String,
}

#[derive(Debug, Deserialize)]
struct SwapProofRequest {
    notes: Vec<NoteInput>,
    zero_for_one: bool,
    exact_out: bool,
    amount_out: Option<String>,
    sqrt_ratio_limit: Option<String>,
    output_note: Option<NoteInput>,
    change_note: Option<NoteInput>,
}

#[derive(Debug, Serialize)]
struct SwapProofResponse {
    proof: Vec<String>,
    input_proofs: Vec<MerklePathResponse>,
    output_proofs: Vec<MerklePathResponse>,
    output_note: Option<NoteOutput>,
    change_note: Option<NoteOutput>,
    amount_out: String,
    amount_in_consumed: String,
}

#[derive(Debug, Deserialize)]
struct LiquidityAddProofRequest {
    token0_notes: Vec<NoteInput>,
    token1_notes: Vec<NoteInput>,
    position_note: Option<PositionNoteInput>,
    tick_lower: i32,
    tick_upper: i32,
    liquidity_delta: String,
    output_position_note: Option<PositionNoteInput>,
    output_note_token0: Option<NoteInput>,
    output_note_token1: Option<NoteInput>,
}

#[derive(Debug, Deserialize)]
struct LiquidityRemoveProofRequest {
    position_note: PositionNoteInput,
    liquidity_delta: String,
    output_position_note: Option<PositionNoteInput>,
    output_note_token0: Option<NoteInput>,
    output_note_token1: Option<NoteInput>,
}

#[derive(Debug, Deserialize)]
struct LiquidityClaimProofRequest {
    position_note: PositionNoteInput,
    output_position_note: Option<PositionNoteInput>,
    output_note_token0: Option<NoteInput>,
    output_note_token1: Option<NoteInput>,
}

#[derive(Debug, Serialize)]
struct LiquidityProofResponse {
    proof: Vec<String>,
    proofs_token0: Vec<MerklePathResponse>,
    proofs_token1: Vec<MerklePathResponse>,
    proof_position: Option<MerklePathResponse>,
    insert_proof_position: Option<MerklePathResponse>,
    output_proof_token0: Option<MerklePathResponse>,
    output_proof_token1: Option<MerklePathResponse>,
    output_note_token0: Option<NoteOutput>,
    output_note_token1: Option<NoteOutput>,
    output_position_note: Option<PositionNoteOutput>,
}

#[derive(Debug, Deserialize)]
struct DepositProofRequest {
    note: NoteInput,
    token_id: u8,
    auto_generate: Option<bool>,
}

#[derive(Debug, Serialize)]
struct DepositProofResponse {
    proof: Vec<String>,
    insertion_proof: MerklePathResponse,
    commitment: String,
    note: Option<NoteOutput>,
}

#[derive(Debug, Deserialize)]
struct WithdrawProofRequest {
    note: NoteInput,
    token_id: u8,
    recipient: String,
    root_index: Option<u64>,
    root_hash: Option<String>,
}

#[derive(Debug, Serialize)]
struct WithdrawProofResponse {
    proof: Vec<String>,
    merkle_proof: MerklePathResponse,
    commitment: String,
    nullifier: String,
}

#[derive(Debug, Deserialize)]
struct SwapQuoteRequest {
    amount: String,
    zero_for_one: bool,
    exact_out: bool,
    sqrt_ratio_limit: Option<String>,
}

#[derive(Debug, Serialize)]
struct SwapQuoteResponse {
    amount_in: String,
    amount_out: String,
    sqrt_price_end: String,
    tick_end: i32,
    liquidity_end: String,
    is_limited: bool,
}

#[derive(Debug, Deserialize)]
struct LiquidityQuoteRequest {
    tick_lower: i32,
    tick_upper: i32,
    liquidity_delta: String,
}

#[derive(Debug, Serialize)]
struct LiquidityQuoteResponse {
    amount0: String,
    amount1: String,
    sqrt_ratio_lower: String,
    sqrt_ratio_upper: String,
}

#[derive(Debug, Serialize)]
struct PoolConfigResponse {
    pool_address: String,
    shielded_notes_address: String,
    token0: String,
    token1: String,
    fee: String,
    tick_spacing: String,
    min_sqrt_ratio: String,
    max_sqrt_ratio: String,
    max_input_notes: usize,
}

#[derive(Debug, Serialize)]
struct MerklePathResponse {
    token: String,
    root: String,
    commitment: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    error: String,
}

#[derive(Debug)]
enum ApiError {
    BadRequest(String),
    Upstream(String),
    Prover(String),
    QueueFull,
    RateLimited,
    Unauthorized,
    Internal(String),
}

const RATE_LIMIT_BUCKET_TTL: Duration = Duration::from_secs(600);
const RATE_LIMIT_MAX_BUCKETS: usize = 10_000;

#[derive(Debug)]
struct RateLimiter {
    buckets: Mutex<HashMap<IpAddr, RateBucket>>,
    rate_per_sec: f64,
    burst: f64,
}

#[derive(Debug, Clone)]
struct RateBucket {
    tokens: f64,
    last_refill: Instant,
}

impl RateLimiter {
    fn new(per_minute: u64, burst: u64) -> Self {
        let rate_per_sec = per_minute as f64 / 60.0;
        Self {
            buckets: Mutex::new(HashMap::new()),
            rate_per_sec,
            burst: burst as f64,
        }
    }

    fn allow(&self, ip: IpAddr) -> bool {
        let now = Instant::now();
        let mut buckets = self
            .buckets
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        if buckets.len() >= RATE_LIMIT_MAX_BUCKETS {
            prune_rate_limit_buckets(&mut buckets, now);
        }
        let bucket = buckets
            .entry(ip)
            .or_insert_with(|| RateBucket {
                tokens: self.burst,
                last_refill: now,
            });
        let elapsed = now.duration_since(bucket.last_refill).as_secs_f64();
        bucket.tokens = (bucket.tokens + elapsed * self.rate_per_sec).min(self.burst);
        bucket.last_refill = now;
        if bucket.tokens < 1.0 {
            return false;
        }
        bucket.tokens -= 1.0;
        true
    }
}

fn prune_rate_limit_buckets(buckets: &mut HashMap<IpAddr, RateBucket>, now: Instant) {
    buckets.retain(|_, bucket| now.duration_since(bucket.last_refill) <= RATE_LIMIT_BUCKET_TTL);
    if buckets.len() <= RATE_LIMIT_MAX_BUCKETS {
        return;
    }
    let mut entries: Vec<(IpAddr, Instant)> = buckets
        .iter()
        .map(|(ip, bucket)| (*ip, bucket.last_refill))
        .collect();
    entries.sort_by_key(|(_, instant)| *instant);
    let over = buckets.len().saturating_sub(RATE_LIMIT_MAX_BUCKETS);
    for (ip, _) in entries.into_iter().take(over) {
        buckets.remove(&ip);
    }
}

impl From<ClientError> for ApiError {
    fn from(err: ClientError) -> Self {
        match err {
            ClientError::InvalidInput(msg) => ApiError::BadRequest(msg),
            ClientError::Crypto(msg) => ApiError::BadRequest(msg),
            ClientError::Serde(msg) => ApiError::BadRequest(msg),
            ClientError::Rpc(msg) => ApiError::Upstream(msg),
            ClientError::Asp(msg) => ApiError::Upstream(msg),
            ClientError::Prover(msg) => ApiError::Prover(msg),
            ClientError::Io(msg) => ApiError::Internal(msg),
            ClientError::NotImplemented(msg) => ApiError::Internal(msg),
        }
    }
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let (status, message) = match self {
            ApiError::BadRequest(msg) => (StatusCode::BAD_REQUEST, msg),
            ApiError::Upstream(msg) => (StatusCode::BAD_GATEWAY, msg),
            ApiError::Prover(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
            ApiError::QueueFull => (StatusCode::TOO_MANY_REQUESTS, "proof queue full".to_string()),
            ApiError::RateLimited => {
                (StatusCode::TOO_MANY_REQUESTS, "rate limit exceeded".to_string())
            }
            ApiError::Unauthorized => (StatusCode::UNAUTHORIZED, "unauthorized".to_string()),
            ApiError::Internal(msg) => (StatusCode::INTERNAL_SERVER_ERROR, msg),
        };
        (status, Json(ErrorResponse { error: message })).into_response()
    }
}

#[derive(Debug, thiserror::Error)]
#[error("read-only account cannot sign")]
struct ReadOnlySignError;

#[derive(Clone)]
struct ReadOnlyAccount<P> {
    provider: P,
    address: Felt,
    chain_id: Felt,
    encoding: ExecutionEncoding,
}

impl<P> ReadOnlyAccount<P>
where
    P: Clone,
{
    fn new(provider: P, chain_id: Felt, encoding: ExecutionEncoding) -> Self {
        Self {
            provider,
            address: Felt::ZERO,
            chain_id,
            encoding,
        }
    }
}

#[async_trait]
impl<P> Account for ReadOnlyAccount<P>
where
    P: Send + Sync,
{
    type SignError = ReadOnlySignError;

    fn address(&self) -> Felt {
        self.address
    }

    fn chain_id(&self) -> Felt {
        self.chain_id
    }

    async fn sign_execution_v3(
        &self,
        _execution: &starknet::accounts::RawExecutionV3,
        _query_only: bool,
    ) -> Result<Vec<Felt>, Self::SignError> {
        Err(ReadOnlySignError)
    }

    async fn sign_declaration_v3(
        &self,
        _declaration: &starknet::accounts::RawDeclarationV3,
        _query_only: bool,
    ) -> Result<Vec<Felt>, Self::SignError> {
        Err(ReadOnlySignError)
    }

    fn is_signer_interactive(
        &self,
        _context: starknet::signers::SignerInteractivityContext<'_>,
    ) -> bool {
        false
    }
}

impl<P> ExecutionEncoder for ReadOnlyAccount<P>
where
    P: Send + Sync,
{
    fn encode_calls(&self, calls: &[Call]) -> Vec<Felt> {
        let mut execute_calldata: Vec<Felt> = vec![calls.len().into()];

        match self.encoding {
            ExecutionEncoding::Legacy => {
                let mut concated_calldata: Vec<Felt> = vec![];
                for call in calls {
                    execute_calldata.push(call.to);
                    execute_calldata.push(call.selector);
                    execute_calldata.push(concated_calldata.len().into());
                    execute_calldata.push(call.calldata.len().into());
                    concated_calldata.extend_from_slice(&call.calldata);
                }
                execute_calldata.push(concated_calldata.len().into());
                execute_calldata.extend_from_slice(&concated_calldata);
            }
            ExecutionEncoding::New => {
                for call in calls {
                    execute_calldata.push(call.to);
                    execute_calldata.push(call.selector);
                    execute_calldata.push(call.calldata.len().into());
                    execute_calldata.extend_from_slice(&call.calldata);
                }
            }
        }

        execute_calldata
    }
}

#[async_trait]
impl<P> ConnectedAccount for ReadOnlyAccount<P>
where
    P: starknet::providers::Provider + Sync + Send,
{
    type Provider = P;

    fn provider(&self) -> &Self::Provider {
        &self.provider
    }

    fn block_id(&self) -> BlockId {
        BlockId::Tag(BlockTag::Latest)
    }
}

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(EnvFilter::from_default_env())
        .init();

    if let Err(err) = run().await {
        error!("{err}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn Error>> {
    let config_path = std::env::var("ZYLITH_BACKEND_CONFIG")
        .map(PathBuf::from)
        .unwrap_or_else(|_| PathBuf::from("config.toml"));
    let raw = load_config(&config_path)?;

    let rpc_url = Url::parse(&raw.rpc_url)?;
    let provider = JsonRpcClient::new(HttpTransport::new(rpc_url.clone()));
    let chain_id = match &raw.chain_id {
        Some(value) => parse_felt(value).map_err(|e| format!("invalid chain_id: {e}"))?,
        None => provider
            .chain_id()
            .await
            .map_err(|e| format!("failed to fetch chain_id: {e}"))?,
    };

    let config = finalize_config(raw, &config_path, rpc_url, chain_id)?;
    validate_artifacts(&config.artifacts_dir)?;

    let account = ReadOnlyAccount::new(provider, config.chain_id, ExecutionEncoding::New);
    let state = AppState {
        account,
        config: Arc::new(config.clone()),
        limiter: Arc::new(Semaphore::new(config.max_concurrent_proofs)),
        rate_limiter: Arc::new(RateLimiter::new(
            config.rate_limit_per_minute,
            config.rate_limit_burst,
        )),
    };
    validate_onchain_config(&state).await?;

    let cors = build_cors(&config.cors_allow_origins)?;
    let app = Router::new()
        .route("/health", get(health))
        .route("/pool/config", get(pool_config))
        .route("/quote/swap", post(quote_swap))
        .route("/quote/liquidity/add", post(quote_liquidity_add))
        .route("/proofs/swap", post(prove_swap))
        .route("/proofs/deposit", post(prove_deposit))
        .route("/proofs/liquidity/add", post(prove_liquidity_add))
        .route("/proofs/liquidity/remove", post(prove_liquidity_remove))
        .route("/proofs/liquidity/claim", post(prove_liquidity_claim))
        .route("/proofs/withdraw", post(prove_withdraw))
        .layer(from_fn_with_state(state.clone(), rate_limit))
        .layer(from_fn_with_state(state.clone(), require_api_key))
        .with_state(state)
        .layer(DefaultBodyLimit::max(config.max_body_bytes))
        .layer(TraceLayer::new_for_http())
        .layer(TimeoutLayer::new(config.request_timeout))
        .layer(cors);

    info!("zylith backend listening on {}", config.bind_addr);
    let listener = tokio::net::TcpListener::bind(config.bind_addr).await?;
    axum::serve(listener, app.into_make_service_with_connect_info::<SocketAddr>()).await?;
    Ok(())
}

fn load_config(path: &Path) -> Result<RawConfig, Box<dyn Error>> {
    let contents = fs::read_to_string(path)?;
    let config: RawConfig = toml::from_str(&contents)?;
    Ok(config)
}

fn finalize_config(
    raw: RawConfig,
    config_path: &Path,
    _rpc_url: Url,
    chain_id: Felt,
) -> Result<AppConfig, Box<dyn Error>> {
    let base_dir = config_path
        .parent()
        .map(Path::to_path_buf)
        .unwrap_or_else(|| PathBuf::from("."));
    let artifacts_dir = resolve_path(&base_dir, &raw.artifacts_dir);
    let asp_url = Url::parse(&raw.asp_url).map_err(|e| format!("asp_url: {e}"))?;

    let bind_addr = raw
        .bind_addr
        .parse::<SocketAddr>()
        .map_err(|e| format!("invalid bind_addr: {e}"))?;
    let pool_address = parse_felt(&raw.pool_address).map_err(|e| format!("pool_address: {e}"))?;
    let shielded_notes_address =
        parse_felt(&raw.shielded_notes_address).map_err(|e| format!("shielded_notes_address: {e}"))?;
    let token0 = parse_felt(&raw.token0).map_err(|e| format!("token0: {e}"))?;
    let token1 = parse_felt(&raw.token1).map_err(|e| format!("token1: {e}"))?;

    if pool_address == Felt::ZERO {
        return Err("pool_address cannot be zero".into());
    }
    if shielded_notes_address == Felt::ZERO {
        return Err("shielded_notes_address cannot be zero".into());
    }
    if token0 == Felt::ZERO || token1 == Felt::ZERO {
        return Err("token0/token1 cannot be zero".into());
    }
    if token0 == token1 {
        return Err("token0 and token1 must be different".into());
    }
    if raw.max_concurrent_proofs == 0 {
        return Err("max_concurrent_proofs must be >= 1".into());
    }
    if raw.request_timeout_secs == 0 {
        return Err("request_timeout_secs must be >= 1".into());
    }
    if raw.max_body_bytes == 0 {
        return Err("max_body_bytes must be >= 1".into());
    }
    if raw.cors_allow_origins.is_empty() {
        return Err("cors_allow_origins must not be empty".into());
    }
    if raw.rate_limit_per_minute == 0 {
        return Err("rate_limit_per_minute must be >= 1".into());
    }
    if raw.rate_limit_burst == 0 {
        return Err("rate_limit_burst must be >= 1".into());
    }
    let api_key = raw
        .api_key
        .and_then(|value| {
            let trimmed = value.trim();
            if trimmed.is_empty() {
                None
            } else {
                Some(trimmed.to_string())
            }
        });
    let trust_proxy = raw.trust_proxy.unwrap_or(false);
    if api_key.is_none() && !is_dev_mode() {
        return Err("api_key must be set unless ENV=dev or ENV=test".into());
    }

    Ok(AppConfig {
        asp_url: asp_url.to_string(),
        pool_address,
        shielded_notes_address,
        token0,
        token1,
        chain_id,
        bind_addr,
        artifacts_dir,
        max_concurrent_proofs: raw.max_concurrent_proofs,
        request_timeout: Duration::from_secs(raw.request_timeout_secs),
        max_body_bytes: raw.max_body_bytes,
        cors_allow_origins: raw.cors_allow_origins,
        rate_limit_per_minute: raw.rate_limit_per_minute,
        rate_limit_burst: raw.rate_limit_burst,
        api_key,
        trust_proxy,
    })
}

fn is_dev_mode() -> bool {
    match std::env::var("ENV") {
        Ok(value) => matches!(value.as_str(), "dev" | "test"),
        Err(_) => false,
    }
}

fn resolve_path(base: &Path, value: &str) -> PathBuf {
    let path = PathBuf::from(value);
    if path.is_absolute() {
        path
    } else {
        base.join(path)
    }
}

fn validate_artifacts(root: &Path) -> Result<(), Box<dyn Error>> {
    let required = [
        ("private_deposit", "private_deposit.wasm"),
        ("private_deposit", "private_deposit_final.zkey"),
        ("private_deposit", "verification_key.json"),
        ("private_swap", "private_swap.wasm"),
        ("private_swap", "private_swap_final.zkey"),
        ("private_swap", "verification_key.json"),
        ("private_swap_exact_out", "private_swap_exact_out.wasm"),
        ("private_swap_exact_out", "private_swap_exact_out_final.zkey"),
        ("private_swap_exact_out", "verification_key.json"),
        ("private_liquidity", "private_liquidity.wasm"),
        ("private_liquidity", "private_liquidity_final.zkey"),
        ("private_liquidity", "verification_key.json"),
        ("private_withdraw", "private_withdraw.wasm"),
        ("private_withdraw", "private_withdraw_final.zkey"),
        ("private_withdraw", "verification_key.json"),
    ];
    for (dir, file) in required {
        let path = root.join(dir).join(file);
        if !path.exists() {
            return Err(format!("missing artifact {}", path.display()).into());
        }
    }
    Ok(())
}

fn build_cors(origins: &[String]) -> Result<CorsLayer, Box<dyn Error>> {
    let base = CorsLayer::new()
        .allow_methods([Method::GET, Method::POST, Method::OPTIONS])
        .allow_headers([header::CONTENT_TYPE, HeaderName::from_static("x-api-key")]);
    if origins.iter().any(|o| o == "*") {
        return Ok(base.allow_origin(Any));
    }
    let mut values = Vec::with_capacity(origins.len());
    for origin in origins {
        let value = HeaderValue::from_str(origin)?;
        values.push(value);
    }
    Ok(base.allow_origin(values))
}

async fn health() -> Json<HealthResponse> {
    Json(HealthResponse { status: "ok" })
}

async fn rate_limit(
    State(state): State<AppState>,
    ConnectInfo(addr): ConnectInfo<SocketAddr>,
    req: Request<Body>,
    next: Next,
) -> Response {
    if req.method() == Method::OPTIONS {
        return next.run(req).await;
    }
    let ip = client_ip(&req, addr, state.config.trust_proxy);
    if !state.rate_limiter.allow(ip) {
        return ApiError::RateLimited.into_response();
    }
    next.run(req).await
}

fn client_ip(req: &Request<Body>, addr: SocketAddr, trust_proxy: bool) -> IpAddr {
    if !trust_proxy {
        return addr.ip();
    }
    if let Some(value) = req.headers().get("x-forwarded-for") {
        if let Ok(value) = value.to_str() {
            for part in value.split(',') {
                let trimmed = part.trim();
                if trimmed.is_empty() {
                    continue;
                }
                if let Ok(ip) = trimmed.parse::<IpAddr>() {
                    return ip;
                }
                if let Ok(sock) = trimmed.parse::<SocketAddr>() {
                    return sock.ip();
                }
            }
        }
    }
    if let Some(value) = req.headers().get("x-real-ip") {
        if let Ok(value) = value.to_str() {
            if let Ok(ip) = value.trim().parse::<IpAddr>() {
                return ip;
            }
            if let Ok(sock) = value.trim().parse::<SocketAddr>() {
                return sock.ip();
            }
        }
    }
    addr.ip()
}

async fn require_api_key(
    State(state): State<AppState>,
    req: Request<Body>,
    next: Next,
) -> Response {
    if req.method() == Method::OPTIONS {
        return next.run(req).await;
    }
    if let Some(expected) = state.config.api_key.as_deref() {
        let provided = req
            .headers()
            .get("x-api-key")
            .and_then(|value| value.to_str().ok());
        if provided != Some(expected) {
            return ApiError::Unauthorized.into_response();
        }
    }
    next.run(req).await
}

async fn pool_config(
    State(state): State<AppState>,
) -> Result<Json<PoolConfigResponse>, ApiError> {
    let client = build_client(&state);
    let config = client.get_pool_config().await?;
    Ok(Json(pool_config_response(config, &state.config)))
}

async fn quote_swap(
    State(state): State<AppState>,
    Json(request): Json<SwapQuoteRequest>,
) -> Result<Json<SwapQuoteResponse>, ApiError> {
    let amount = parse_u128(&request.amount)?;
    if amount == 0 {
        return Err(ApiError::BadRequest("amount must be greater than zero".to_string()));
    }
    let client = build_client(&state);
    let pool_config = client.get_pool_config().await?;
    let sqrt_ratio_limit = request
        .sqrt_ratio_limit
        .map(|value| parse_u256(&value))
        .transpose()?
        .unwrap_or_else(|| default_sqrt_ratio_limit(&pool_config, request.zero_for_one));
    let is_token1 = if request.exact_out {
        request.zero_for_one
    } else {
        !request.zero_for_one
    };
    let quote = client
        .swap_client()
        .quote_swap_steps(zylith_client::SwapQuoteRequest {
            amount: SignedAmount {
                mag: amount,
                sign: request.exact_out,
            },
            is_token1,
            sqrt_ratio_limit,
            skip_ahead: 0,
        })
        .await?;
    let (amount_in, amount_out) = summarize_quote_amounts(&quote.steps)?;
    Ok(Json(SwapQuoteResponse {
        amount_in: amount_in.to_string(),
        amount_out: amount_out.to_string(),
        sqrt_price_end: u256_to_hex(quote.sqrt_price_end),
        tick_end: quote.tick_end,
        liquidity_end: quote.liquidity_end.to_string(),
        is_limited: quote.is_limited,
    }))
}

async fn quote_liquidity_add(
    State(state): State<AppState>,
    Json(request): Json<LiquidityQuoteRequest>,
) -> Result<Json<LiquidityQuoteResponse>, ApiError> {
    let liquidity_delta = parse_u128(&request.liquidity_delta)?;
    if liquidity_delta == 0 {
        return Err(ApiError::BadRequest(
            "liquidity_delta must be greater than zero".to_string(),
        ));
    }
    if request.tick_lower >= request.tick_upper {
        return Err(ApiError::BadRequest(
            "tick_lower must be less than tick_upper".to_string(),
        ));
    }
    let client = build_client(&state);
    let pool_config = client.get_pool_config().await?;
    let tick_spacing = pool_config.tick_spacing as i32;
    if tick_spacing == 0 {
        return Err(ApiError::BadRequest("tick_spacing is zero".to_string()));
    }
    if request.tick_lower % tick_spacing != 0 || request.tick_upper % tick_spacing != 0 {
        return Err(ApiError::BadRequest(
            "ticks must align to tick spacing".to_string(),
        ));
    }
    let pool_state = client.get_pool_state().await?;
    let swap_client = client.swap_client();
    let sqrt_ratio_lower = swap_client
        .get_sqrt_ratio_at_tick(request.tick_lower)
        .await?;
    let sqrt_ratio_upper = swap_client
        .get_sqrt_ratio_at_tick(request.tick_upper)
        .await?;
    if sqrt_ratio_lower == U256::from(0u128) || sqrt_ratio_upper == U256::from(0u128) {
        return Err(ApiError::BadRequest(
            "sqrt ratio is zero; pool not initialized".to_string(),
        ));
    }
    let (amount0, amount1) = quote_liquidity_amounts(
        pool_state.sqrt_price,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity_delta,
        true,
    )?;
    Ok(Json(LiquidityQuoteResponse {
        amount0: amount0.to_string(),
        amount1: amount1.to_string(),
        sqrt_ratio_lower: u256_to_hex(sqrt_ratio_lower),
        sqrt_ratio_upper: u256_to_hex(sqrt_ratio_upper),
    }))
}

async fn prove_swap(
    State(state): State<AppState>,
    Json(request): Json<SwapProofRequest>,
) -> Result<Json<SwapProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    if request.notes.is_empty() {
        return Err(ApiError::BadRequest("notes cannot be empty".to_string()));
    }
    let notes = parse_notes(request.notes, &state.config)?;
    let output_note = parse_note_option(request.output_note, &state.config)?;
    let change_note = parse_note_option(request.change_note, &state.config)?;
    let amount_out = request
        .amount_out
        .map(|value| parse_u128(&value))
        .transpose()?;
    if request.exact_out {
        match amount_out {
            Some(value) if value == 0 => {
                return Err(ApiError::BadRequest(
                    "amount_out must be greater than zero".to_string(),
                ));
            }
            None => {
                return Err(ApiError::BadRequest(
                    "amount_out is required for exact_out".to_string(),
                ));
            }
            _ => {}
        }
    } else if amount_out.is_some() {
        return Err(ApiError::BadRequest(
            "amount_out is only valid for exact_out".to_string(),
        ));
    }
    let sqrt_ratio_limit = request
        .sqrt_ratio_limit
        .map(|value| parse_u256(&value))
        .transpose()?;

    let circuit_dir = if request.exact_out {
        state.config.artifacts_dir.join("private_swap_exact_out")
    } else {
        state.config.artifacts_dir.join("private_swap")
    };
    let client = build_client(&state);
    let result = client
        .prove_swap(SwapProveRequest {
            notes,
            zero_for_one: request.zero_for_one,
            exact_out: request.exact_out,
            amount_out,
            sqrt_ratio_limit,
            output_note,
            change_note,
            circuit_dir: Some(circuit_dir),
        })
        .await?;

    Ok(Json(SwapProofResponse {
        proof: result.proof.to_calldata(),
        input_proofs: result
            .input_proofs
            .into_iter()
            .map(merkle_path_response)
            .collect(),
        output_proofs: result
            .output_proofs
            .into_iter()
            .map(merkle_path_response)
            .collect(),
        output_note: result.output_note.map(note_output),
        change_note: result.change_note.map(note_output),
        amount_out: result.amount_out.to_string(),
        amount_in_consumed: result.amount_in_consumed.to_string(),
    }))
}

async fn prove_deposit(
    State(state): State<AppState>,
    Json(request): Json<DepositProofRequest>,
) -> Result<Json<DepositProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    if request.token_id > 1 {
        return Err(ApiError::BadRequest("token_id must be 0 or 1".to_string()));
    }
    let expected_token = if request.token_id == 0 {
        state.config.token0
    } else {
        state.config.token1
    };
    let auto_generate = request.auto_generate.unwrap_or(false);
    let (note, response_note) = if auto_generate {
        let amount = parse_u128(&request.note.amount)?;
        if amount == 0 {
            return Err(ApiError::BadRequest(
                "note amount must be greater than zero".to_string(),
            ));
        }
        let token = parse_felt(&request.note.token)
            .map_err(|e| ApiError::BadRequest(e.to_string()))?;
        if token != expected_token {
            return Err(ApiError::BadRequest("note token mismatch".to_string()));
        }
        let note = generate_note_with_token_id(amount, expected_token, request.token_id)?;
        (note.clone(), Some(note_output(note)))
    } else {
        let note = parse_note(request.note, &state.config)?;
        if note.token != expected_token {
            return Err(ApiError::BadRequest("note token mismatch".to_string()));
        }
        (note, None)
    };

    let commitment = compute_commitment(&note, request.token_id)?;
    let tag = vk_tag("DEPOSIT")?;
    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(tag.to_string()));
    values.insert(
        "commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(commitment)),
    );
    values.insert("amount".to_string(), WitnessValue::U128(note.amount));
    values.insert(
        "token_id".to_string(),
        WitnessValue::U128(request.token_id as u128),
    );
    values.insert(
        "secret".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.secret)),
    );
    values.insert(
        "nullifier_seed".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.nullifier)),
    );

    let witness = DepositWitnessInputs { values };
    let circuit_dir = state.config.artifacts_dir.join("private_deposit");
    let proof = prove_deposit_proof(witness, &circuit_dir)
        .await
        .map_err(|e| ApiError::Prover(e.to_string()))?;

    let client = build_client(&state);
    let insertion_proof = client
        .swap_client()
        .fetch_insertion_path(expected_token)
        .await?;

    Ok(Json(DepositProofResponse {
        proof: proof.to_calldata(),
        insertion_proof: merkle_path_response(insertion_proof),
        commitment: felt_to_hex(commitment),
        note: response_note,
    }))
}

async fn prove_liquidity_add(
    State(state): State<AppState>,
    Json(request): Json<LiquidityAddProofRequest>,
) -> Result<Json<LiquidityProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    let token0_notes =
        parse_notes_for_token(request.token0_notes, &state.config, state.config.token0)?;
    let token1_notes =
        parse_notes_for_token(request.token1_notes, &state.config, state.config.token1)?;
    let position_note = parse_position_note_option(request.position_note)?;
    let output_position_note = parse_position_note_option(request.output_position_note)?;
    let output_note_token0 =
        parse_note_option_for_token(request.output_note_token0, &state.config, state.config.token0)?;
    let output_note_token1 =
        parse_note_option_for_token(request.output_note_token1, &state.config, state.config.token1)?;
    let liquidity_delta = parse_u128(&request.liquidity_delta)?;
    if liquidity_delta == 0 {
        return Err(ApiError::BadRequest(
            "liquidity_delta must be greater than zero".to_string(),
        ));
    }
    if request.tick_lower >= request.tick_upper {
        return Err(ApiError::BadRequest(
            "tick_lower must be less than tick_upper".to_string(),
        ));
    }
    let pool_config = build_client(&state).get_pool_config().await?;
    let tick_spacing = pool_config.tick_spacing as i32;
    if tick_spacing == 0 {
        return Err(ApiError::BadRequest("tick_spacing is zero".to_string()));
    }
    if request.tick_lower % tick_spacing != 0 || request.tick_upper % tick_spacing != 0 {
        return Err(ApiError::BadRequest(
            "ticks must align to tick spacing".to_string(),
        ));
    }
    if let Some(note) = &position_note {
        if note.tick_lower != request.tick_lower || note.tick_upper != request.tick_upper {
            return Err(ApiError::BadRequest(
                "position_note tick bounds must match request".to_string(),
            ));
        }
    }
    if let Some(note) = &output_position_note {
        if note.tick_lower != request.tick_lower || note.tick_upper != request.tick_upper {
            return Err(ApiError::BadRequest(
                "output_position_note tick bounds must match request".to_string(),
            ));
        }
    }

    let client = build_client(&state);
    let result = client
        .prove_liquidity_add(LiquidityAddProveRequest {
            token0_notes,
            token1_notes,
            position_note,
            tick_lower: request.tick_lower,
            tick_upper: request.tick_upper,
            liquidity_delta,
            output_position_note,
            output_note_token0,
            output_note_token1,
            circuit_dir: Some(state.config.artifacts_dir.join("private_liquidity")),
        })
        .await?;
    Ok(Json(liquidity_response(result)))
}

async fn prove_liquidity_remove(
    State(state): State<AppState>,
    Json(request): Json<LiquidityRemoveProofRequest>,
) -> Result<Json<LiquidityProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    let position_note = parse_position_note(request.position_note)?;
    let output_position_note = parse_position_note_option(request.output_position_note)?;
    let output_note_token0 =
        parse_note_option_for_token(request.output_note_token0, &state.config, state.config.token0)?;
    let output_note_token1 =
        parse_note_option_for_token(request.output_note_token1, &state.config, state.config.token1)?;
    if let Some(note) = &output_position_note {
        if note.tick_lower != position_note.tick_lower || note.tick_upper != position_note.tick_upper {
            return Err(ApiError::BadRequest(
                "output_position_note tick bounds must match position_note".to_string(),
            ));
        }
    }
    let liquidity_delta = parse_u128(&request.liquidity_delta)?;
    if liquidity_delta == 0 {
        return Err(ApiError::BadRequest(
            "liquidity_delta must be greater than zero".to_string(),
        ));
    }

    let client = build_client(&state);
    let result = client
        .prove_liquidity_remove(LiquidityRemoveProveRequest {
            position_note,
            liquidity_delta,
            output_position_note,
            output_note_token0,
            output_note_token1,
            circuit_dir: Some(state.config.artifacts_dir.join("private_liquidity")),
        })
        .await?;
    Ok(Json(liquidity_response(result)))
}

async fn prove_liquidity_claim(
    State(state): State<AppState>,
    Json(request): Json<LiquidityClaimProofRequest>,
) -> Result<Json<LiquidityProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    let position_note = parse_position_note(request.position_note)?;
    let output_position_note = parse_position_note_option(request.output_position_note)?;
    let output_note_token0 =
        parse_note_option_for_token(request.output_note_token0, &state.config, state.config.token0)?;
    let output_note_token1 =
        parse_note_option_for_token(request.output_note_token1, &state.config, state.config.token1)?;
    if let Some(note) = &output_position_note {
        if note.tick_lower != position_note.tick_lower || note.tick_upper != position_note.tick_upper {
            return Err(ApiError::BadRequest(
                "output_position_note tick bounds must match position_note".to_string(),
            ));
        }
    }

    let client = build_client(&state);
    let result = client
        .prove_liquidity_claim(LiquidityClaimProveRequest {
            position_note,
            output_position_note,
            output_note_token0,
            output_note_token1,
            circuit_dir: Some(state.config.artifacts_dir.join("private_liquidity")),
        })
        .await?;
    Ok(Json(liquidity_response(result)))
}

async fn prove_withdraw(
    State(state): State<AppState>,
    Json(request): Json<WithdrawProofRequest>,
) -> Result<Json<WithdrawProofResponse>, ApiError> {
    let _permit = state.limiter.try_acquire().map_err(|_| ApiError::QueueFull)?;
    if request.token_id > 1 {
        return Err(ApiError::BadRequest("token_id must be 0 or 1".to_string()));
    }
    let note = parse_note(request.note, &state.config)?;
    let token_expected = if request.token_id == 0 {
        state.config.token0
    } else {
        state.config.token1
    };
    if note.token != token_expected {
        return Err(ApiError::BadRequest("note token mismatch".to_string()));
    }
    if request.root_index.is_some() && request.root_hash.is_some() {
        return Err(ApiError::BadRequest(
            "root_index and root_hash are mutually exclusive".to_string(),
        ));
    }
    let recipient =
        parse_felt(&request.recipient).map_err(|e| ApiError::BadRequest(e.to_string()))?;
    let commitment = compute_commitment(&note, request.token_id)?;
    let nullifier = generate_nullifier_hash(&note, request.token_id)?;
    let tag = vk_tag("WITHDRAW")?;
    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(tag.to_string()));
    values.insert(
        "commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(commitment)),
    );
    values.insert(
        "nullifier".to_string(),
        WitnessValue::Scalar(felt_to_decimal(nullifier)),
    );
    values.insert("amount".to_string(), WitnessValue::U128(note.amount));
    values.insert(
        "token_id".to_string(),
        WitnessValue::U128(request.token_id as u128),
    );
    values.insert(
        "recipient".to_string(),
        WitnessValue::Scalar(felt_to_decimal(recipient)),
    );
    values.insert(
        "secret".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.secret)),
    );
    values.insert(
        "nullifier_seed".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.nullifier)),
    );

    let witness = WithdrawWitnessInputs { values };
    let circuit_dir = state.config.artifacts_dir.join("private_withdraw");
    let proof = prove_withdraw_proof(witness, &circuit_dir)
        .await
        .map_err(|e| ApiError::Prover(e.to_string()))?;

    let client = build_client(&state);
    let root_hash = request
        .root_hash
        .map(|value| parse_felt(&value).map_err(|e| ApiError::BadRequest(e.to_string())))
        .transpose()?;
    let merkle_proof = client
        .swap_client()
        .fetch_merkle_path(commitment, request.root_index, root_hash)
        .await?;

    Ok(Json(WithdrawProofResponse {
        proof: proof.to_calldata(),
        merkle_proof: merkle_path_response(merkle_proof),
        commitment: felt_to_hex(commitment),
        nullifier: felt_to_hex(nullifier),
    }))
}

fn build_client(state: &AppState) -> ZylithClient<ReadOnlyAccount<JsonRpcClient<HttpTransport>>> {
    ZylithClient::new(ZylithConfig {
        account: state.account.clone(),
        asp_url: state.config.asp_url.clone(),
        pool_address: state.config.pool_address,
        shielded_notes_address: state.config.shielded_notes_address,
        token0: state.config.token0,
        token1: state.config.token1,
    })
}

async fn validate_onchain_config(state: &AppState) -> Result<(), Box<dyn Error>> {
    let client = build_client(state);
    let pool_config = client
        .get_pool_config()
        .await
        .map_err(|e| format!("failed to fetch pool config: {e}"))?;
    if pool_config.token0 != state.config.token0 || pool_config.token1 != state.config.token1 {
        return Err(format!(
            "pool token mismatch: expected ({}, {}) got ({}, {})",
            felt_to_hex(state.config.token0),
            felt_to_hex(state.config.token1),
            felt_to_hex(pool_config.token0),
            felt_to_hex(pool_config.token1),
        )
        .into());
    }

    let provider = state.account.provider();
    let notes_token0 = call_contract_felt(provider, state.config.shielded_notes_address, "get_token0")
        .await
        .map_err(|e| format!("failed to read ShieldedNotes token0: {e}"))?;
    let notes_token1 = call_contract_felt(provider, state.config.shielded_notes_address, "get_token1")
        .await
        .map_err(|e| format!("failed to read ShieldedNotes token1: {e}"))?;
    if notes_token0 != state.config.token0 || notes_token1 != state.config.token1 {
        return Err(format!(
            "shielded notes token mismatch: expected ({}, {}) got ({}, {})",
            felt_to_hex(state.config.token0),
            felt_to_hex(state.config.token1),
            felt_to_hex(notes_token0),
            felt_to_hex(notes_token1),
        )
        .into());
    }
    Ok(())
}

async fn call_contract_felt<P: Provider + Sync>(
    provider: &P,
    contract_address: Felt,
    entrypoint: &str,
) -> Result<Felt, Box<dyn Error>> {
    let selector = get_selector_from_name(entrypoint)
        .map_err(|err| format!("selector {entrypoint}: {err}"))?;
    let call = FunctionCall {
        contract_address,
        entry_point_selector: selector,
        calldata: Vec::new(),
    };
    let result = provider
        .call(call, BlockId::Tag(BlockTag::Latest))
        .await
        .map_err(|err| format!("call {entrypoint}: {err}"))?;
    result
        .first()
        .copied()
        .ok_or_else(|| format!("call {entrypoint}: empty response").into())
}

fn parse_notes(inputs: Vec<NoteInput>, config: &AppConfig) -> Result<Vec<Note>, ApiError> {
    if inputs.len() > MAX_INPUT_NOTES {
        return Err(ApiError::BadRequest(format!(
            "notes length exceeds max {MAX_INPUT_NOTES}"
        )));
    }
    inputs
        .into_iter()
        .map(|note| parse_note(note, config))
        .collect()
}

fn parse_notes_for_token(
    inputs: Vec<NoteInput>,
    config: &AppConfig,
    expected_token: Felt,
) -> Result<Vec<Note>, ApiError> {
    if inputs.len() > MAX_INPUT_NOTES {
        return Err(ApiError::BadRequest(format!(
            "notes length exceeds max {MAX_INPUT_NOTES}"
        )));
    }
    let mut parsed = Vec::with_capacity(inputs.len());
    for input in inputs {
        let note = parse_note(input, config)?;
        if note.token != expected_token {
            return Err(ApiError::BadRequest(
                "note token does not match expected token".to_string(),
            ));
        }
        parsed.push(note);
    }
    Ok(parsed)
}

fn parse_note_option(input: Option<NoteInput>, config: &AppConfig) -> Result<Option<Note>, ApiError> {
    match input {
        Some(note) => Ok(Some(parse_note(note, config)?)),
        None => Ok(None),
    }
}

fn parse_note_option_for_token(
    input: Option<NoteInput>,
    config: &AppConfig,
    expected_token: Felt,
) -> Result<Option<Note>, ApiError> {
    match input {
        Some(note) => {
            let parsed = parse_note(note, config)?;
            if parsed.token != expected_token {
                return Err(ApiError::BadRequest(
                    "note token does not match expected token".to_string(),
                ));
            }
            Ok(Some(parsed))
        }
        None => Ok(None),
    }
}

fn parse_note(input: NoteInput, config: &AppConfig) -> Result<Note, ApiError> {
    let secret = parse_bytes32(&input.secret)?;
    let nullifier = parse_bytes32(&input.nullifier)?;
    let amount = parse_u128(&input.amount)?;
    if amount == 0 {
        return Err(ApiError::BadRequest(
            "note amount must be greater than zero".to_string(),
        ));
    }
    let token = parse_felt(&input.token).map_err(|e| ApiError::BadRequest(e.to_string()))?;
    validate_note_token(token, config)?;
    Ok(Note {
        secret,
        nullifier,
        amount,
        token,
    })
}

fn validate_note_token(token: Felt, config: &AppConfig) -> Result<(), ApiError> {
    if token != config.token0 && token != config.token1 {
        return Err(ApiError::BadRequest(
            "note token must be token0 or token1".to_string(),
        ));
    }
    Ok(())
}

fn parse_position_note_option(
    input: Option<PositionNoteInput>,
) -> Result<Option<PositionNote>, ApiError> {
    match input {
        Some(note) => Ok(Some(parse_position_note(note)?)),
        None => Ok(None),
    }
}

fn parse_position_note(input: PositionNoteInput) -> Result<PositionNote, ApiError> {
    let secret = parse_bytes32(&input.secret)?;
    let nullifier = parse_bytes32(&input.nullifier)?;
    if input.tick_lower >= input.tick_upper {
        return Err(ApiError::BadRequest(
            "tick_lower must be less than tick_upper".to_string(),
        ));
    }
    let liquidity = parse_u128(&input.liquidity)?;
    let fee_growth_inside_0 = parse_u256(&input.fee_growth_inside_0)?;
    let fee_growth_inside_1 = parse_u256(&input.fee_growth_inside_1)?;
    Ok(PositionNote {
        secret,
        nullifier,
        tick_lower: input.tick_lower,
        tick_upper: input.tick_upper,
        liquidity,
        fee_growth_inside_0,
        fee_growth_inside_1,
    })
}

fn note_output(note: Note) -> NoteOutput {
    NoteOutput {
        secret: bytes32_to_hex(&note.secret),
        nullifier: bytes32_to_hex(&note.nullifier),
        amount: note.amount.to_string(),
        token: felt_to_hex(note.token),
    }
}

fn position_note_output(note: PositionNote) -> PositionNoteOutput {
    PositionNoteOutput {
        secret: bytes32_to_hex(&note.secret),
        nullifier: bytes32_to_hex(&note.nullifier),
        tick_lower: note.tick_lower,
        tick_upper: note.tick_upper,
        liquidity: note.liquidity.to_string(),
        fee_growth_inside_0: u256_to_hex(note.fee_growth_inside_0),
        fee_growth_inside_1: u256_to_hex(note.fee_growth_inside_1),
    }
}

fn merkle_path_response(path: MerklePath) -> MerklePathResponse {
    MerklePathResponse {
        token: felt_to_hex(path.token),
        root: felt_to_hex(path.root),
        commitment: felt_to_hex(path.commitment),
        leaf_index: path.leaf_index,
        path: path.path.into_iter().map(felt_to_hex).collect(),
        indices: path.indices,
    }
}

fn liquidity_response(result: LiquidityProveResult) -> LiquidityProofResponse {
    LiquidityProofResponse {
        proof: result.proof.to_calldata(),
        proofs_token0: result
            .proofs_token0
            .into_iter()
            .map(merkle_path_response)
            .collect(),
        proofs_token1: result
            .proofs_token1
            .into_iter()
            .map(merkle_path_response)
            .collect(),
        proof_position: result.proof_position.map(merkle_path_response),
        insert_proof_position: result.insert_proof_position.map(merkle_path_response),
        output_proof_token0: result.output_proof_token0.map(merkle_path_response),
        output_proof_token1: result.output_proof_token1.map(merkle_path_response),
        output_note_token0: result.output_note_token0.map(note_output),
        output_note_token1: result.output_note_token1.map(note_output),
        output_position_note: result.output_position_note.map(position_note_output),
    }
}

fn pool_config_response(config: PoolConfig, app_config: &AppConfig) -> PoolConfigResponse {
    PoolConfigResponse {
        pool_address: felt_to_hex(app_config.pool_address),
        shielded_notes_address: felt_to_hex(app_config.shielded_notes_address),
        token0: felt_to_hex(config.token0),
        token1: felt_to_hex(config.token1),
        fee: config.fee.to_string(),
        tick_spacing: config.tick_spacing.to_string(),
        min_sqrt_ratio: u256_to_hex(config.min_sqrt_ratio),
        max_sqrt_ratio: u256_to_hex(config.max_sqrt_ratio),
        max_input_notes: MAX_INPUT_NOTES,
    }
}

fn default_sqrt_ratio_limit(config: &PoolConfig, zero_for_one: bool) -> U256 {
    if zero_for_one {
        config.min_sqrt_ratio
    } else {
        config.max_sqrt_ratio
    }
}

fn summarize_quote_amounts(steps: &[SwapStepQuote]) -> Result<(u128, u128), ApiError> {
    let mut total_in = 0u128;
    let mut total_out = 0u128;
    for step in steps {
        total_in = total_in
            .checked_add(step.amount_in)
            .ok_or_else(|| ApiError::BadRequest("amount_in overflow".to_string()))?;
        total_out = total_out
            .checked_add(step.amount_out)
            .ok_or_else(|| ApiError::BadRequest("amount_out overflow".to_string()))?;
    }
    Ok((total_in, total_out))
}

fn parse_u128(value: &str) -> Result<u128, ApiError> {
    if let Some(hex) = value.strip_prefix("0x") {
        u128::from_str_radix(hex, 16)
            .map_err(|_| ApiError::BadRequest("invalid u128".to_string()))
    } else {
        value
            .parse::<u128>()
            .map_err(|_| ApiError::BadRequest("invalid u128".to_string()))
    }
}

fn parse_u256(value: &str) -> Result<U256, ApiError> {
    let (radix, digits) = if let Some(hex) = value.strip_prefix("0x") {
        (16, hex)
    } else {
        (10, value)
    };
    let parsed =
        BigUint::from_str_radix(digits, radix).map_err(|_| ApiError::BadRequest("invalid u256".to_string()))?;
    let bytes = parsed.to_bytes_be();
    if bytes.len() > 32 {
        return Err(ApiError::BadRequest("u256 overflow".to_string()));
    }
    let mut padded = [0u8; 32];
    padded[32 - bytes.len()..].copy_from_slice(&bytes);
    let high = u128::from_be_bytes(padded[0..16].try_into().unwrap());
    let low = u128::from_be_bytes(padded[16..32].try_into().unwrap());
    Ok(U256::from_words(low, high))
}

fn parse_bytes32(value: &str) -> Result<[u8; 32], ApiError> {
    let hex = value.strip_prefix("0x").unwrap_or(value);
    if hex.len() != 64 {
        return Err(ApiError::BadRequest("expected 32-byte hex string".to_string()));
    }
    let bytes = hex::decode(hex).map_err(|_| ApiError::BadRequest("invalid hex".to_string()))?;
    let mut out = [0u8; 32];
    out.copy_from_slice(&bytes);
    Ok(out)
}

fn bytes32_to_hex(value: &[u8; 32]) -> String {
    format!("0x{}", hex::encode(value))
}

fn felt_to_hex(value: Felt) -> String {
    let bytes = value.to_bytes_be();
    let mut encoded = hex::encode(bytes);
    while encoded.starts_with('0') && encoded.len() > 1 {
        encoded.remove(0);
    }
    format!("0x{}", encoded)
}

fn u256_to_hex(value: U256) -> String {
    let mut buf = [0u8; 32];
    buf[0..16].copy_from_slice(&value.high().to_be_bytes());
    buf[16..32].copy_from_slice(&value.low().to_be_bytes());
    let mut encoded = hex::encode(buf);
    while encoded.starts_with('0') && encoded.len() > 1 {
        encoded.remove(0);
    }
    format!("0x{}", encoded)
}

fn bytes_to_decimal(value: &[u8; 32]) -> String {
    BigUint::from_bytes_be(value).to_str_radix(10)
}

fn felt_to_decimal(value: Felt) -> String {
    BigUint::from_bytes_be(&value.to_bytes_be()).to_str_radix(10)
}

fn vk_tag(tag: &str) -> Result<u64, ApiError> {
    match tag {
        "DEPOSIT" => Ok(0x4445504f534954),
        "WITHDRAW" => Ok(0x5749544844524157),
        _ => Err(ApiError::BadRequest("unknown verifier tag".to_string())),
    }
}
