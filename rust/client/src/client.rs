use std::sync::Arc;

use num_bigint::BigUint;
use starknet::accounts::ConnectedAccount;
use starknet::core::types::{BlockId, BlockTag, FunctionCall, U256};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::Provider;

use crate::deposit::{DepositClient, DepositRequest, DepositResult};
use crate::error::ClientError;
use crate::generated_constants;
use crate::liquidity::{LiquidityClaimRequest, LiquidityClient, LiquidityRequest};
use crate::swap::{with_retry, MerklePath, SwapClient, SwapQuoteRequest, SwapResult, TxHash};
use crate::utils::{felt_to_i32, felt_to_u128, Address};
use crate::withdraw::{WithdrawClient, WithdrawRequest};
use zylith_prover::ProofCalldata;

#[derive(Debug, Clone)]
pub struct RetryConfig {
    pub max_attempts: usize,
    pub delay_ms: u64,
}

impl Default for RetryConfig {
    fn default() -> Self {
        Self {
            max_attempts: 3,
            delay_ms: 500,
        }
    }
}

#[derive(Debug, Clone)]
pub struct PoolState {
    pub sqrt_price: U256,
    pub tick: i32,
    pub liquidity: u128,
    pub fee_growth_global_0: (u128, u128),
    pub fee_growth_global_1: (u128, u128),
}

#[derive(Debug, Clone)]
pub struct PoolConfig {
    pub token0: Address,
    pub token1: Address,
    pub fee: u128,
    pub tick_spacing: u128,
    pub min_sqrt_ratio: U256,
    pub max_sqrt_ratio: U256,
}

pub struct ZylithConfig<A: ConnectedAccount + Sync + Send> {
    pub account: A,
    pub asp_url: String,
    pub pool_address: Address,
    pub shielded_notes_address: Address,
    pub token0: Address,
    pub token1: Address,
}

pub struct ZylithClient<A: ConnectedAccount + Sync + Send> {
    account: Arc<A>,
    pub asp_url: String,
    pub pool_address: Address,
    pub shielded_notes_address: Address,
    pub token0: Address,
    pub token1: Address,
    pub retry: RetryConfig,
}

impl<A: ConnectedAccount + Sync + Send> ZylithClient<A> {
    pub fn new(config: ZylithConfig<A>) -> Self {
        Self {
            account: Arc::new(config.account),
            asp_url: config.asp_url,
            pool_address: config.pool_address,
            shielded_notes_address: config.shielded_notes_address,
            token0: config.token0,
            token1: config.token1,
            retry: RetryConfig::default(),
        }
    }

    pub fn swap_client(&self) -> SwapClient<Arc<A>> {
        let mut client = SwapClient::new(self.account.clone(), self.pool_address, self.asp_url.clone());
        client.retry = self.retry.clone();
        client
    }

    pub fn deposit_client(&self) -> DepositClient<Arc<A>> {
        let mut client = DepositClient::new(self.account.clone(), self.shielded_notes_address);
        client.retry = self.retry.clone();
        client
    }

    pub fn withdraw_client(&self) -> WithdrawClient<Arc<A>> {
        let mut client = WithdrawClient::new(self.account.clone(), self.shielded_notes_address);
        client.retry = self.retry.clone();
        client
    }

    pub fn liquidity_client(&self) -> LiquidityClient<Arc<A>> {
        let mut client = LiquidityClient::new(self.account.clone(), self.pool_address);
        client.retry = self.retry.clone();
        client
    }

    pub fn token_id(&self, token: Address) -> Result<u8, ClientError> {
        if token == self.token0 {
            Ok(0)
        } else if token == self.token1 {
            Ok(1)
        } else {
            Err(ClientError::InvalidInput("unknown token".to_string()))
        }
    }

    pub async fn deposit(&self, request: DepositRequest) -> Result<DepositResult, ClientError> {
        match request.token_id {
            0 => self.deposit_client().deposit_token0(request).await,
            1 => self.deposit_client().deposit_token1(request).await,
            _ => Err(ClientError::InvalidInput("invalid token id".to_string())),
        }
    }

    pub async fn swap(
        &self,
        proof: ProofCalldata,
        proofs: &[MerklePath],
        output_proofs: &[MerklePath],
        exact_out: bool,
    ) -> Result<TxHash, ClientError> {
        self.swap_client()
            .execute_swap(proof, proofs, output_proofs, exact_out)
            .await
    }

    pub async fn quote_swap(&self, request: SwapQuoteRequest) -> Result<SwapResult, ClientError> {
        self.swap_client().simulate_swap(request).await
    }

    pub async fn add_liquidity(&self, request: LiquidityRequest) -> Result<TxHash, ClientError> {
        self.liquidity_client().add_liquidity(request).await
    }

    pub async fn remove_liquidity(
        &self,
        proof: ProofCalldata,
        proof_position: MerklePath,
        insert_proof_position: Option<MerklePath>,
        output_proof_token0: Option<MerklePath>,
        output_proof_token1: Option<MerklePath>,
    ) -> Result<TxHash, ClientError> {
        self.liquidity_client()
            .remove_liquidity(
                proof,
                proof_position,
                insert_proof_position,
                output_proof_token0,
                output_proof_token1,
            )
            .await
    }

    pub async fn claim_liquidity_fees(
        &self,
        request: LiquidityClaimRequest,
    ) -> Result<TxHash, ClientError> {
        self.liquidity_client().claim_fees(request).await
    }

    pub async fn withdraw(&self, request: WithdrawRequest) -> Result<TxHash, ClientError> {
        self.withdraw_client().withdraw(request).await
    }

    pub async fn get_pool_state(&self) -> Result<PoolState, ClientError> {
        let selector = get_selector_from_name("get_pool_state")
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
            return Err(ClientError::Rpc("invalid pool state".to_string()));
        }
        let sqrt_price = U256::from_words(
            felt_to_u128(&result[0])?,
            felt_to_u128(&result[1])?,
        );
        let tick = felt_to_i32(&result[2])?;
        let liquidity = felt_to_u128(&result[3])?;
        let fee0_low = felt_to_u128(&result[4])?;
        let fee0_high = felt_to_u128(&result[5])?;
        let fee1_low = felt_to_u128(&result[6])?;
        let fee1_high = felt_to_u128(&result[7])?;
        let max_fee_growth = max_fee_growth()?;
        let fee_growth_0 = biguint_from_words(fee0_low, fee0_high);
        let fee_growth_1 = biguint_from_words(fee1_low, fee1_high);
        if fee_growth_0 > max_fee_growth || fee_growth_1 > max_fee_growth {
            return Err(ClientError::Rpc("fee growth exceeds max".to_string()));
        }
        Ok(PoolState {
            sqrt_price,
            tick,
            liquidity,
            fee_growth_global_0: (fee0_low, fee0_high),
            fee_growth_global_1: (fee1_low, fee1_high),
        })
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
        if tick_spacing == 0 || tick_spacing > generated_constants::MAX_TICK_SPACING {
            return Err(ClientError::InvalidInput("invalid tick spacing".to_string()));
        }
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

fn biguint_from_words(low: u128, high: u128) -> BigUint {
    (BigUint::from(high) << 128) + BigUint::from(low)
}

fn max_fee_growth() -> Result<BigUint, ClientError> {
    let hex = generated_constants::MAX_FEE_GROWTH_HEX.trim_start_matches("0x");
    BigUint::parse_bytes(hex.as_bytes(), 16)
        .ok_or_else(|| ClientError::Crypto("invalid max fee growth".to_string()))
}
