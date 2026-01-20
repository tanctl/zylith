use starknet::accounts::ConnectedAccount;
use starknet::core::types::{Call, Felt};
use starknet::core::utils::get_selector_from_name;

use crate::client::RetryConfig;
use crate::error::ClientError;
use crate::notes::{compute_commitment, Note};
use crate::swap::{execute_with_retry, serialize_merkle_proof, MerklePath};
use crate::utils::{parse_felt, Address};
use zylith_prover::ProofCalldata;

pub type TxHash = Felt;

#[derive(Debug, Clone)]
pub struct DepositRequest {
    pub note: Note,
    pub token_id: u8,
    pub token_address: Address,
    pub proof: ProofCalldata,
    pub insertion_proof: MerklePath,
}

#[derive(Debug, Clone)]
pub struct DepositResult {
    pub commitment: Felt,
    pub tx_hash: TxHash,
}

#[derive(Clone)]
pub struct DepositClient<A: ConnectedAccount + Sync> {
    pub account: A,
    pub shielded_notes_address: Address,
    pub retry: RetryConfig,
}

impl<A: ConnectedAccount + Sync> DepositClient<A> {
    pub fn new(account: A, shielded_notes_address: Address) -> Self {
        Self {
            account,
            shielded_notes_address,
            retry: RetryConfig::default(),
        }
    }

    pub async fn deposit_token0(&self, request: DepositRequest) -> Result<DepositResult, ClientError> {
        self.deposit("deposit_token0", request).await
    }

    pub async fn deposit_token1(&self, request: DepositRequest) -> Result<DepositResult, ClientError> {
        self.deposit("deposit_token1", request).await
    }

    async fn deposit(&self, entrypoint: &str, request: DepositRequest) -> Result<DepositResult, ClientError> {
        if request.note.amount == 0 {
            return Err(ClientError::InvalidInput("amount is zero".to_string()));
        }
        if entrypoint == "deposit_token0" && request.token_id != 0 {
            return Err(ClientError::InvalidInput("token id mismatch".to_string()));
        }
        if entrypoint == "deposit_token1" && request.token_id != 1 {
            return Err(ClientError::InvalidInput("token id mismatch".to_string()));
        }
        if request.token_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("token address is zero".to_string()));
        }
        if self.shielded_notes_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("shielded notes address is zero".to_string()));
        }
        if request.insertion_proof.token != request.token_address {
            return Err(ClientError::InvalidInput("insertion proof token mismatch".to_string()));
        }
        let commitment = compute_commitment(&request.note, request.token_id)?;
        approve_erc20(
            &self.account,
            request.token_address,
            self.shielded_notes_address,
            request.note.amount,
            self.retry.clone(),
        )
        .await?;

        let mut calldata = request
            .proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        calldata.extend(serialize_merkle_proof(&request.insertion_proof)?);

        let selector = get_selector_from_name(entrypoint)
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = Call {
            to: self.shielded_notes_address,
            selector,
            calldata,
        };
        let tx_hash = execute_with_retry(&self.account, call, self.retry.clone()).await?;
        Ok(DepositResult {
            commitment,
            tx_hash,
        })
    }
}

async fn approve_erc20<A: ConnectedAccount + Sync>(
    account: &A,
    token: Address,
    spender: Address,
    amount: u128,
    retry: RetryConfig,
) -> Result<TxHash, ClientError> {
    let selector = get_selector_from_name("approve")
        .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
    let mut calldata = Vec::new();
    calldata.push(spender);
    calldata.push(Felt::from(amount));
    calldata.push(Felt::ZERO);
    let call = Call {
        to: token,
        selector,
        calldata,
    };
    execute_with_retry(account, call, retry).await
}
