use num_bigint::BigUint;
use serde::Deserialize;
use starknet::accounts::ConnectedAccount;
use starknet::core::types::{BlockId, BlockTag, Call, Felt, FunctionCall, U256};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::Provider;
use tokio::time::{sleep, Duration};

use crate::client::{PoolConfig, RetryConfig};
use crate::error::ClientError;
use crate::notes::{compute_commitment, Note};
use crate::utils::{felt_to_i32, felt_to_u128, parse_felt, Address};
use starknet_crypto::poseidon_hash;
use crate::generated_constants;
use zylith_prover::ProofCalldata;

pub type TxHash = Felt;

const ASP_TIMEOUT_SECS: u64 = 60;

fn asp_timeout() -> Result<Duration, ClientError> {
    if let Ok(value) = std::env::var("ZYLITH_ASP_TIMEOUT_SECS") {
        let secs = value
            .parse::<u64>()
            .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_ASP_TIMEOUT_SECS".to_string()))?;
        if secs == 0 {
            return Err(ClientError::InvalidInput(
                "ZYLITH_ASP_TIMEOUT_SECS must be > 0".to_string(),
            ));
        }
        Ok(Duration::from_secs(secs))
    } else {
        Ok(Duration::from_secs(ASP_TIMEOUT_SECS))
    }
}

pub(crate) fn asp_client() -> Result<reqwest::Client, ClientError> {
    let timeout = asp_timeout()?;
    reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|err| ClientError::Asp(err.to_string()))
}

#[derive(Debug, Clone)]
pub struct SwapRequest {
    pub notes: Vec<Note>,
    pub token_id: u8,
    pub amount_in: u128,
    pub zero_for_one: bool,
}

#[derive(Debug, Clone)]
pub struct SignedAmount {
    pub mag: u128,
    pub sign: bool,
}

#[derive(Debug, Clone)]
pub struct SwapQuoteRequest {
    pub amount: SignedAmount,
    pub is_token1: bool,
    pub sqrt_ratio_limit: U256,
    pub skip_ahead: u128,
}

#[derive(Debug, Clone)]
pub struct SwapResult {
    pub delta_amount0: SignedAmount,
    pub delta_amount1: SignedAmount,
    pub sqrt_price_after: U256,
    pub tick_after: i32,
    pub liquidity_after: u128,
}

#[derive(Debug, Clone)]
pub struct SwapStepQuote {
    pub sqrt_price_next: U256,
    pub sqrt_price_limit: U256,
    pub tick_next: i32,
    pub liquidity_net: U256,
    pub fee_growth_global_0: U256,
    pub fee_growth_global_1: U256,
    pub amount_in: u128,
    pub amount_out: u128,
    pub fee_amount: u128,
}

#[derive(Debug, Clone)]
pub struct SwapStepsQuote {
    pub sqrt_price_start: U256,
    pub sqrt_price_end: U256,
    pub tick_start: i32,
    pub tick_end: i32,
    pub liquidity_start: u128,
    pub liquidity_end: u128,
    pub fee_growth_global_0_before: U256,
    pub fee_growth_global_1_before: U256,
    pub fee_growth_global_0_after: U256,
    pub fee_growth_global_1_after: U256,
    pub is_limited: bool,
    pub steps: Vec<SwapStepQuote>,
}

#[derive(Debug, Clone)]
pub struct MerklePath {
    pub token: Address,
    pub root: Felt,
    pub commitment: Felt,
    pub leaf_index: u64,
    pub path: Vec<Felt>,
    pub indices: Vec<bool>,
}

#[derive(Clone)]
pub struct SwapClient<A: ConnectedAccount + Sync> {
    pub account: A,
    pub pool_address: Address,
    pub asp_url: String,
    pub retry: RetryConfig,
}

#[derive(Debug, Deserialize)]
struct PathResponse {
    token: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Debug, Deserialize)]
struct InsertPathResponse {
    token: String,
    root: String,
    commitment: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Debug, Deserialize)]
struct RootAtResponse {
    token: String,
    root_index: u64,
    root: String,
}

impl<A: ConnectedAccount + Sync> SwapClient<A> {
    pub fn new(account: A, pool_address: Address, asp_url: impl Into<String>) -> Self {
        Self {
            account,
            pool_address,
            asp_url: asp_url.into(),
            retry: RetryConfig::default(),
        }
    }

    pub fn prepare_swap(
        &self,
        notes: Vec<Note>,
        token_id: u8,
        zero_for_one: bool,
    ) -> Result<SwapRequest, ClientError> {
        if token_id > 1 {
            return Err(ClientError::InvalidInput("invalid token id".to_string()));
        }
        if notes.is_empty() {
            return Err(ClientError::InvalidInput("notes cannot be empty".to_string()));
        }
        if notes.len() > generated_constants::MAX_INPUT_NOTES {
            return Err(ClientError::InvalidInput("too many input notes".to_string()));
        }
        let mut amount_in: u128 = 0;
        for note in &notes {
            let _commitment = compute_commitment(note, token_id)?;
            amount_in = amount_in
                .checked_add(note.amount)
                .ok_or_else(|| ClientError::InvalidInput("note amount overflow".to_string()))?;
        }
        if amount_in == 0 {
            return Err(ClientError::InvalidInput("input amount is zero".to_string()));
        }
        Ok(SwapRequest {
            notes,
            token_id,
            amount_in,
            zero_for_one,
        })
    }

    pub async fn fetch_merkle_path(
        &self,
        commitment: Felt,
        root_index: Option<u64>,
        root_hash: Option<Felt>,
    ) -> Result<MerklePath, ClientError> {
        if root_index.is_some() && root_hash.is_some() {
            return Err(ClientError::InvalidInput(
                "root_index and root_hash are mutually exclusive".to_string(),
            ));
        }
        let mut payload = serde_json::Map::new();
        payload.insert("commitment".to_string(), serde_json::Value::String(felt_to_hex(commitment)));
        if let Some(index) = root_index {
            payload.insert(
                "root_index".to_string(),
                serde_json::Value::Number(serde_json::Number::from(index)),
            );
        }
        if let Some(hash) = root_hash {
            payload.insert("root_hash".to_string(), serde_json::Value::String(felt_to_hex(hash)));
        }

        let url = format!("{}/path", self.asp_url.trim_end_matches('/'));
        let client = asp_client()?;
        let response = client
            .post(url)
            .json(&payload)
            .send()
            .await
            .map_err(|err| ClientError::Asp(err.to_string()))?;

        if !response.status().is_success() {
            return Err(ClientError::Asp(format!(
                "asp path error: {}",
                response.status()
            )));
        }
        let body: PathResponse = response.json().await.map_err(ClientError::from)?;
        let token_label = body.token;
        let token = match parse_felt(&token_label) {
            Ok(token) => token,
            Err(_) => {
                if token_label == "position" {
                    Felt::ZERO
                } else {
                    return Err(ClientError::Asp("invalid token".to_string()));
                }
            }
        };
        let path = parse_hex_vec(&body.path)?;

        let computed_root = compute_merkle_root(commitment, &path, &body.indices)?;
        let root = if let Some(hash) = root_hash {
            hash
        } else if let Some(index) = root_index {
            fetch_root_at(&self.asp_url, &token_label, index).await?
        } else {
            computed_root
        };
        if (root_hash.is_some() || root_index.is_some()) && root != computed_root {
            return Err(ClientError::Asp("merkle path root mismatch".to_string()));
        }

        Ok(MerklePath {
            token,
            root,
            commitment,
            leaf_index: body.leaf_index,
            path,
            indices: body.indices,
        })
    }

    pub async fn fetch_insertion_path(&self, token: Address) -> Result<MerklePath, ClientError> {
        self.fetch_insertion_path_label(&felt_to_hex(token), token).await
    }

    pub async fn fetch_position_insertion_path(&self) -> Result<MerklePath, ClientError> {
        self.fetch_insertion_path_label("position", Felt::ZERO).await
    }

    pub async fn simulate_swap(
        &self,
        request: SwapQuoteRequest,
    ) -> Result<SwapResult, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let selector = get_selector_from_name("quote_swap")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let (limit_low, limit_high) = u256_to_felts(&request.sqrt_ratio_limit);
        let calldata = vec![
            Felt::from(request.amount.mag),
            bool_to_felt(request.amount.sign),
            bool_to_felt(request.is_token1),
            limit_low,
            limit_high,
            Felt::from(request.skip_ahead),
        ];
        let call = FunctionCall {
            contract_address: self.pool_address,
            entry_point_selector: selector,
            calldata,
        };
        let provider = self.account.provider();
        let result = with_retry(self.retry.clone(), || async {
            provider
                .call(call.clone(), BlockId::Tag(BlockTag::Latest))
                .await
                .map_err(|err| ClientError::Rpc(err.to_string()))
        })
        .await?;

        if result.len() < 8 {
            return Err(ClientError::Rpc("invalid swap quote".to_string()));
        }
        let amount0 = decode_signed_amount(&result[0], &result[1])?;
        let amount1 = decode_signed_amount(&result[2], &result[3])?;
        let sqrt_price_after = U256::from_words(felt_to_u128(&result[4])?, felt_to_u128(&result[5])?);
        let tick_after = felt_to_i32(&result[6])?;
        let liquidity_after = felt_to_u128(&result[7])?;
        Ok(SwapResult {
            delta_amount0: amount0,
            delta_amount1: amount1,
            sqrt_price_after,
            tick_after,
            liquidity_after,
        })
    }

    pub async fn quote_swap_steps(
        &self,
        request: SwapQuoteRequest,
    ) -> Result<SwapStepsQuote, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let selector = get_selector_from_name("quote_swap_steps")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let (limit_low, limit_high) = u256_to_felts(&request.sqrt_ratio_limit);
        let calldata = vec![
            Felt::from(request.amount.mag),
            bool_to_felt(request.amount.sign),
            bool_to_felt(request.is_token1),
            limit_low,
            limit_high,
            Felt::from(request.skip_ahead),
        ];
        let call = FunctionCall {
            contract_address: self.pool_address,
            entry_point_selector: selector,
            calldata,
        };
        let provider = self.account.provider();
        let result = with_retry(self.retry.clone(), || async {
            provider
                .call(call.clone(), BlockId::Tag(BlockTag::Latest))
                .await
                .map_err(|err| ClientError::Rpc(err.to_string()))
        })
        .await?;
        parse_swap_steps_quote(&result)
    }

    pub async fn get_sqrt_ratio_at_tick(&self, tick: i32) -> Result<U256, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let selector = get_selector_from_name("get_sqrt_ratio_at_tick")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = FunctionCall {
            contract_address: self.pool_address,
            entry_point_selector: selector,
            calldata: vec![i32_to_felt(tick)?],
        };
        let provider = self.account.provider();
        let result = with_retry(self.retry.clone(), || async {
            provider
                .call(call.clone(), BlockId::Tag(BlockTag::Latest))
                .await
                .map_err(|err| ClientError::Rpc(err.to_string()))
        })
        .await?;
        if result.len() < 2 {
            return Err(ClientError::Rpc("invalid sqrt ratio response".to_string()));
        }
        let low = felt_to_u128(&result[0])?;
        let high = felt_to_u128(&result[1])?;
        Ok(U256::from_words(low, high))
    }

    pub async fn execute_swap(
        &self,
        proof: ProofCalldata,
        proofs: &[MerklePath],
        output_proofs: &[MerklePath],
        exact_out: bool,
    ) -> Result<TxHash, ClientError> {
        if proofs.is_empty() {
            return Err(ClientError::InvalidInput("missing merkle proofs".to_string()));
        }
        if proofs.len() > generated_constants::MAX_INPUT_NOTES {
            return Err(ClientError::InvalidInput("too many merkle proofs".to_string()));
        }
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let mut full_calldata: Vec<Felt> = proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        full_calldata.extend(serialize_merkle_proofs(proofs)?);
        full_calldata.extend(serialize_merkle_proofs(output_proofs)?);

        let selector = if exact_out {
            get_selector_from_name("swap_private_exact_out")
        } else {
            get_selector_from_name("swap_private")
        }
        .map_err(|err| ClientError::InvalidInput(err.to_string()))?;

        let call = Call {
            to: self.pool_address,
            selector,
            calldata: full_calldata,
        };

        execute_with_retry(&self.account, call, self.retry.clone()).await
    }

    pub async fn get_pool_state(&self) -> Result<(U256, i32, u128), ClientError> {
        let provider = self.account.provider();
        let selector = get_selector_from_name("get_pool_state")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = FunctionCall {
            contract_address: self.pool_address,
            entry_point_selector: selector,
            calldata: Vec::new(),
        };
        let result = with_retry(self.retry.clone(), || async {
            provider
                .call(call.clone(), BlockId::Tag(BlockTag::Latest))
                .await
                .map_err(|err| ClientError::Rpc(err.to_string()))
        })
        .await?;

        if result.len() < 5 {
            return Err(ClientError::Rpc("invalid pool state".to_string()));
        }
        let sqrt_price = U256::from_words(felt_to_u128(&result[0])?, felt_to_u128(&result[1])?);
        let tick = felt_to_i32(&result[2])?;
        let liquidity = felt_to_u128(&result[3])?;
        Ok((sqrt_price, tick, liquidity))
    }

    pub async fn get_pool_config(&self) -> Result<PoolConfig, ClientError> {
        let selector = get_selector_from_name("get_pool_config")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = FunctionCall {
            contract_address: self.pool_address,
            entry_point_selector: selector,
            calldata: Vec::new(),
        };
        let provider = self.account.provider();
        let result = with_retry(self.retry.clone(), || async {
            provider
                .call(call.clone(), BlockId::Tag(BlockTag::Latest))
                .await
                .map_err(|err| ClientError::Rpc(err.to_string()))
        })
        .await?;
        if result.len() < 8 {
            return Err(ClientError::Rpc("invalid pool config".to_string()));
        }
        let token0 = result[0];
        let token1 = result[1];
        let fee = felt_to_u128(&result[2])?;
        let tick_spacing = felt_to_u128(&result[3])?;
        let min_sqrt_ratio =
            U256::from_words(felt_to_u128(&result[4])?, felt_to_u128(&result[5])?);
        let max_sqrt_ratio =
            U256::from_words(felt_to_u128(&result[6])?, felt_to_u128(&result[7])?);
        Ok(PoolConfig {
            token0,
            token1,
            fee,
            tick_spacing,
            min_sqrt_ratio,
            max_sqrt_ratio,
        })
    }
}

impl<A: ConnectedAccount + Sync> SwapClient<A> {
    async fn fetch_insertion_path_label(
        &self,
        token_label: &str,
        token: Address,
    ) -> Result<MerklePath, ClientError> {
        let mut payload = serde_json::Map::new();
        payload.insert(
            "token".to_string(),
            serde_json::Value::String(token_label.to_string()),
        );

        let url = format!("{}/insert_path", self.asp_url.trim_end_matches('/'));
        let mut attempt = 0usize;
        loop {
            let client = asp_client()?;
            let response = client
                .post(&url)
                .json(&payload)
                .send()
                .await
                .map_err(|err| ClientError::Asp(err.to_string()))?;

            if response.status().as_u16() == 409 {
                attempt += 1;
                if attempt >= self.retry.max_attempts {
                    return Err(ClientError::Asp(format!(
                        "asp insert path error: {}",
                        response.status()
                    )));
                }
                sleep(Duration::from_millis(self.retry.delay_ms)).await;
                continue;
            }

            if !response.status().is_success() {
                return Err(ClientError::Asp(format!(
                    "asp insert path error: {}",
                    response.status()
                )));
            }
            let body: InsertPathResponse = response.json().await.map_err(ClientError::from)?;
            if body.token != token_label {
                return Err(ClientError::Asp("token mismatch".to_string()));
            }
            let root =
                parse_felt(&body.root).map_err(|_| ClientError::Asp("invalid root".to_string()))?;
            let commitment = parse_felt(&body.commitment)
                .map_err(|_| ClientError::Asp("invalid commitment".to_string()))?;
            let path = parse_hex_vec(&body.path)?;

            return Ok(MerklePath {
                token,
                root,
                commitment,
                leaf_index: body.leaf_index,
                path,
                indices: body.indices,
            });
        }
    }
}

pub(crate) async fn execute_with_retry<A: ConnectedAccount + Sync>(
    account: &A,
    call: Call,
    retry: RetryConfig,
) -> Result<TxHash, ClientError> {
    with_retry(retry, || async {
        let mut exec = account.execute_v3(vec![call.clone()]);
        if let Ok(l1_gas) = std::env::var("ZYLITH_L1_GAS") {
            let parsed = l1_gas
                .parse::<u64>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L1_GAS".to_string()))?;
            exec = exec.l1_gas(parsed);
        }
        if let Ok(l1_gas_price) = std::env::var("ZYLITH_L1_GAS_PRICE") {
            let parsed = l1_gas_price
                .parse::<u128>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L1_GAS_PRICE".to_string()))?;
            exec = exec.l1_gas_price(parsed);
        }
        if let Ok(l2_gas) = std::env::var("ZYLITH_L2_GAS") {
            let parsed = l2_gas
                .parse::<u64>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L2_GAS".to_string()))?;
            exec = exec.l2_gas(parsed);
        }
        if let Ok(l2_gas_price) = std::env::var("ZYLITH_L2_GAS_PRICE") {
            let parsed = l2_gas_price
                .parse::<u128>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L2_GAS_PRICE".to_string()))?;
            exec = exec.l2_gas_price(parsed);
        }
        if let Ok(l1_data_gas) = std::env::var("ZYLITH_L1_DATA_GAS") {
            let parsed = l1_data_gas
                .parse::<u64>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L1_DATA_GAS".to_string()))?;
            exec = exec.l1_data_gas(parsed);
        }
        if let Ok(l1_data_gas_price) = std::env::var("ZYLITH_L1_DATA_GAS_PRICE") {
            let parsed = l1_data_gas_price
                .parse::<u128>()
                .map_err(|_| ClientError::InvalidInput("invalid ZYLITH_L1_DATA_GAS_PRICE".to_string()))?;
            exec = exec.l1_data_gas_price(parsed);
        }
        exec.send()
            .await
            .map_err(|err| ClientError::Rpc(err.to_string()))
            .map(|result| result.transaction_hash)
    })
    .await
}

pub(crate) async fn with_retry<F, Fut, T>(retry: RetryConfig, mut f: F) -> Result<T, ClientError>
where
    F: FnMut() -> Fut,
    Fut: std::future::Future<Output = Result<T, ClientError>>,
{
    let mut attempt = 0usize;
    loop {
        match f().await {
            Ok(value) => return Ok(value),
            Err(err) => {
                attempt += 1;
                if attempt >= retry.max_attempts {
                    return Err(err);
                }
                sleep(Duration::from_millis(retry.delay_ms)).await;
            }
        }
    }
}

pub(crate) fn serialize_merkle_proofs(proofs: &[MerklePath]) -> Result<Vec<Felt>, ClientError> {
    let mut out = Vec::new();
    out.push(Felt::from(proofs.len() as u64));
    for proof in proofs {
        out.extend(serialize_merkle_proof(proof)?);
    }
    Ok(out)
}

pub(crate) fn serialize_merkle_proof(proof: &MerklePath) -> Result<Vec<Felt>, ClientError> {
    if proof.path.len() != proof.indices.len() {
        return Err(ClientError::InvalidInput("merkle path mismatch".to_string()));
    }
    if proof.path.len() != generated_constants::TREE_HEIGHT {
        return Err(ClientError::InvalidInput("merkle path length mismatch".to_string()));
    }
    let mut out = Vec::new();
    out.push(proof.root);
    out.push(proof.commitment);
    out.push(Felt::from(proof.leaf_index));
    out.push(Felt::from(proof.path.len() as u64));
    out.extend(proof.path.iter().copied());
    out.push(Felt::from(proof.indices.len() as u64));
    out.extend(proof.indices.iter().map(|b| if *b { Felt::ONE } else { Felt::ZERO }));
    Ok(out)
}

fn parse_hex_vec(values: &[String]) -> Result<Vec<Felt>, ClientError> {
    values
        .iter()
        .map(|value| {
            parse_felt(value)
                .map_err(|_| ClientError::Asp("invalid felt".to_string()))
        })
        .collect()
}

fn compute_merkle_root(
    leaf: Felt,
    path: &[Felt],
    indices: &[bool],
) -> Result<Felt, ClientError> {
    if path.len() != indices.len() {
        return Err(ClientError::InvalidInput("merkle path mismatch".to_string()));
    }
    let mut hash = leaf;
    for (sibling, is_right) in path.iter().zip(indices.iter()) {
        let (left, right) = if *is_right {
            (*sibling, hash)
        } else {
            (hash, *sibling)
        };
        hash = poseidon_hash(left, right);
    }
    Ok(hash)
}

async fn fetch_root_at(asp_url: &str, token: &str, index: u64) -> Result<Felt, ClientError> {
    let url = format!("{}/root/{}?token={}", asp_url.trim_end_matches('/'), index, token);
    let client = asp_client()?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|err| ClientError::Asp(err.to_string()))?;
    if !response.status().is_success() {
        return Err(ClientError::Asp(format!(
            "asp root error: {}",
            response.status()
        )));
    }
    let body: RootAtResponse = response.json().await.map_err(ClientError::from)?;
    if body.token != token {
        return Err(ClientError::Asp("token mismatch".to_string()));
    }
    if body.root_index != index {
        return Err(ClientError::Asp("root index mismatch".to_string()));
    }
    parse_felt(&body.root).map_err(|_| ClientError::Asp("invalid root".to_string()))
}

fn felt_to_hex(value: Felt) -> String {
    format!("0x{:x}", value)
}

fn decode_signed_amount(mag: &Felt, sign: &Felt) -> Result<SignedAmount, ClientError> {
    let mag = felt_to_u128(mag)?;
    let sign = felt_to_bool(sign)?;
    Ok(SignedAmount { mag, sign })
}

fn felt_to_bool(value: &Felt) -> Result<bool, ClientError> {
    if value == &Felt::ZERO {
        Ok(false)
    } else if value == &Felt::ONE {
        Ok(true)
    } else {
        Err(ClientError::InvalidInput("invalid bool felt".to_string()))
    }
}

fn bool_to_felt(value: bool) -> Felt {
    if value { Felt::ONE } else { Felt::ZERO }
}

fn u256_to_felts(value: &U256) -> (Felt, Felt) {
    (Felt::from(value.low()), Felt::from(value.high()))
}

fn i32_to_felt(value: i32) -> Result<Felt, ClientError> {
    if value >= 0 {
        Ok(Felt::from(value as u64))
    } else {
        let modulus =
            BigUint::parse_bytes(b"800000000000011000000000000000000000000000000000000000000000001", 16)
                .ok_or_else(|| ClientError::Crypto("invalid modulus".to_string()))?;
        let mag = BigUint::from((-value) as u32);
        let result = modulus - mag;
        let bytes = result.to_bytes_be();
        let mut out = [0u8; 32];
        out[32 - bytes.len()..].copy_from_slice(&bytes);
        Ok(Felt::from_bytes_be(&out))
    }
}

fn parse_swap_steps_quote(result: &[Felt]) -> Result<SwapStepsQuote, ClientError> {
    let min_len = 18;
    if result.len() < min_len {
        return Err(ClientError::Rpc("invalid swap steps quote".to_string()));
    }
    let sqrt_price_start = U256::from_words(felt_to_u128(&result[0])?, felt_to_u128(&result[1])?);
    let sqrt_price_end = U256::from_words(felt_to_u128(&result[2])?, felt_to_u128(&result[3])?);
    let tick_start = felt_to_i32(&result[4])?;
    let tick_end = felt_to_i32(&result[5])?;
    let liquidity_start = felt_to_u128(&result[6])?;
    let liquidity_end = felt_to_u128(&result[7])?;
    let fee_growth_global_0_before =
        U256::from_words(felt_to_u128(&result[8])?, felt_to_u128(&result[9])?);
    let fee_growth_global_1_before =
        U256::from_words(felt_to_u128(&result[10])?, felt_to_u128(&result[11])?);
    let fee_growth_global_0_after =
        U256::from_words(felt_to_u128(&result[12])?, felt_to_u128(&result[13])?);
    let fee_growth_global_1_after =
        U256::from_words(felt_to_u128(&result[14])?, felt_to_u128(&result[15])?);
    let is_limited = felt_to_bool(&result[16])?;
    let step_count = felt_to_u128(&result[17])? as usize;
    if step_count > generated_constants::MAX_SWAP_STEPS {
        return Err(ClientError::Rpc("step count exceeds max".to_string()));
    }

    let step_len = 14;
    let expected_len = min_len + step_count * step_len;
    if result.len() != expected_len {
        return Err(ClientError::Rpc("invalid swap steps quote length".to_string()));
    }

    let mut steps = Vec::with_capacity(step_count);
    let mut idx = min_len;
    for _ in 0..step_count {
        let sqrt_price_next = U256::from_words(felt_to_u128(&result[idx])?, felt_to_u128(&result[idx + 1])?);
        let sqrt_price_limit = U256::from_words(felt_to_u128(&result[idx + 2])?, felt_to_u128(&result[idx + 3])?);
        let tick_next = felt_to_i32(&result[idx + 4])?;
        let liquidity_net = U256::from_words(felt_to_u128(&result[idx + 5])?, felt_to_u128(&result[idx + 6])?);
        let fee_growth_global_0 =
            U256::from_words(felt_to_u128(&result[idx + 7])?, felt_to_u128(&result[idx + 8])?);
        let fee_growth_global_1 =
            U256::from_words(felt_to_u128(&result[idx + 9])?, felt_to_u128(&result[idx + 10])?);
        let amount_in = felt_to_u128(&result[idx + 11])?;
        let amount_out = felt_to_u128(&result[idx + 12])?;
        let fee_amount = felt_to_u128(&result[idx + 13])?;
        steps.push(SwapStepQuote {
            sqrt_price_next,
            sqrt_price_limit,
            tick_next,
            liquidity_net,
            fee_growth_global_0,
            fee_growth_global_1,
            amount_in,
            amount_out,
            fee_amount,
        });
        idx += step_len;
    }

    Ok(SwapStepsQuote {
        sqrt_price_start,
        sqrt_price_end,
        tick_start,
        tick_end,
        liquidity_start,
        liquidity_end,
        fee_growth_global_0_before,
        fee_growth_global_1_before,
        fee_growth_global_0_after,
        fee_growth_global_1_after,
        is_limited,
        steps,
    })
}

#[cfg(test)]
mod tests {
    use super::{serialize_merkle_proof, serialize_merkle_proofs, MerklePath};
    use crate::generated_constants;
    use starknet::core::types::Felt;

    #[test]
    fn serialize_merkle_proof_layout() {
        let proof = MerklePath {
            token: Felt::from(1u8),
            root: Felt::from(10u8),
            commitment: Felt::from(20u8),
            leaf_index: 3,
            path: vec![Felt::from(30u8); generated_constants::TREE_HEIGHT],
            indices: (0..generated_constants::TREE_HEIGHT)
                .map(|idx| idx % 2 == 0)
                .collect(),
        };
        let data = serialize_merkle_proof(&proof).expect("serialize");
        assert_eq!(data.len(), 5 + proof.path.len() + proof.indices.len());
        assert_eq!(data[0], proof.root);
        assert_eq!(data[1], proof.commitment);
        assert_eq!(data[2], Felt::from(proof.leaf_index));
        assert_eq!(data[3], Felt::from(proof.path.len() as u64));
        assert_eq!(data[4], proof.path[0]);
        assert_eq!(data[5], proof.path[1]);
        let idx_offset = 4 + proof.path.len();
        assert_eq!(data[idx_offset], Felt::from(proof.indices.len() as u64));
        assert_eq!(data[idx_offset + 1], Felt::ONE);
        assert_eq!(data[idx_offset + 2], Felt::ZERO);
    }

    #[test]
    fn serialize_merkle_proofs_prefix() {
        let proof = MerklePath {
            token: Felt::from(1u8),
            root: Felt::from(10u8),
            commitment: Felt::from(20u8),
            leaf_index: 0,
            path: vec![Felt::from(30u8); generated_constants::TREE_HEIGHT],
            indices: vec![false; generated_constants::TREE_HEIGHT],
        };
        let data = serialize_merkle_proofs(&[proof]).expect("serialize");
        assert_eq!(data[0], Felt::ONE);
    }
}
