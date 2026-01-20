use starknet::accounts::ConnectedAccount;
use starknet::core::types::{Call, Felt};
use starknet::core::utils::get_selector_from_name;
use crate::client::RetryConfig;
use crate::error::ClientError;
use crate::swap::{
    execute_with_retry, serialize_merkle_proof, serialize_merkle_proofs, MerklePath,
};
use crate::utils::{parse_felt, Address};
use zylith_prover::ProofCalldata;

pub type TxHash = Felt;

#[derive(Debug, Clone)]
pub struct LiquidityRequest {
    pub proof: ProofCalldata,
    pub proofs_token0: Vec<MerklePath>,
    pub proofs_token1: Vec<MerklePath>,
    pub proof_position: Option<MerklePath>,
    pub insert_proof_position: Option<MerklePath>,
    pub output_proof_token0: Option<MerklePath>,
    pub output_proof_token1: Option<MerklePath>,
}

#[derive(Debug, Clone)]
pub struct LiquidityClaimRequest {
    pub proof: ProofCalldata,
    pub proof_position: MerklePath,
    pub insert_proof_position: Option<MerklePath>,
    pub output_proof_token0: Option<MerklePath>,
    pub output_proof_token1: Option<MerklePath>,
}

#[derive(Clone)]
pub struct LiquidityClient<A: ConnectedAccount + Sync> {
    pub account: A,
    pub pool_address: Address,
    pub retry: RetryConfig,
}

impl<A: ConnectedAccount + Sync> LiquidityClient<A> {
    pub fn new(account: A, pool_address: Address) -> Self {
        Self {
            account,
            pool_address,
            retry: RetryConfig::default(),
        }
    }

    pub async fn add_liquidity(&self, request: LiquidityRequest) -> Result<TxHash, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let mut calldata: Vec<Felt> = request
            .proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        calldata.extend(serialize_merkle_proofs(&request.proofs_token0)?);
        calldata.extend(serialize_merkle_proofs(&request.proofs_token1)?);
        let position_proofs = opt_proof_slice(&request.proof_position);
        calldata.extend(serialize_merkle_proofs(position_proofs)?);
        let insert_position_proofs = opt_proof_slice(&request.insert_proof_position);
        calldata.extend(serialize_merkle_proofs(insert_position_proofs)?);
        let output_token0_proofs = opt_proof_slice(&request.output_proof_token0);
        calldata.extend(serialize_merkle_proofs(output_token0_proofs)?);
        let output_token1_proofs = opt_proof_slice(&request.output_proof_token1);
        calldata.extend(serialize_merkle_proofs(output_token1_proofs)?);

        let selector = get_selector_from_name("add_liquidity_private")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = Call {
            to: self.pool_address,
            selector,
            calldata,
        };
        execute_with_retry(&self.account, call, self.retry.clone()).await
    }

    pub async fn remove_liquidity(
        &self,
        proof: ProofCalldata,
        proof_position: MerklePath,
        insert_proof_position: Option<MerklePath>,
        output_proof_token0: Option<MerklePath>,
        output_proof_token1: Option<MerklePath>,
    ) -> Result<TxHash, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let mut calldata: Vec<Felt> = proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        calldata.extend(serialize_merkle_proof(&proof_position)?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&insert_proof_position))?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&output_proof_token0))?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&output_proof_token1))?);

        let selector = get_selector_from_name("remove_liquidity_private")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = Call {
            to: self.pool_address,
            selector,
            calldata,
        };
        execute_with_retry(&self.account, call, self.retry.clone()).await
    }

    pub async fn claim_fees(
        &self,
        request: LiquidityClaimRequest,
    ) -> Result<TxHash, ClientError> {
        if self.pool_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("pool address is zero".to_string()));
        }
        let mut calldata: Vec<Felt> = request
            .proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        calldata.extend(serialize_merkle_proof(&request.proof_position)?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&request.insert_proof_position))?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&request.output_proof_token0))?);
        calldata.extend(serialize_merkle_proofs(opt_proof_slice(&request.output_proof_token1))?);

        let selector = get_selector_from_name("claim_liquidity_fees_private")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = Call {
            to: self.pool_address,
            selector,
            calldata,
        };
        execute_with_retry(&self.account, call, self.retry.clone()).await
    }
}

fn opt_proof_slice(proof: &Option<MerklePath>) -> &[MerklePath] {
    match proof {
        Some(proof) => std::slice::from_ref(proof),
        None => &[],
    }
}
