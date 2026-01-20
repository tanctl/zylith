use starknet::accounts::ConnectedAccount;
use starknet::core::types::{Call, Felt};
use starknet::core::utils::get_selector_from_name;

use crate::client::RetryConfig;
use crate::error::ClientError;
use crate::notes::{generate_nullifier_hash, Note};
use crate::swap::{execute_with_retry, serialize_merkle_proof, MerklePath};
use crate::utils::{parse_felt, Address};
use zylith_prover::ProofCalldata;

pub type TxHash = Felt;

#[derive(Debug, Clone)]
pub struct WithdrawRequest {
    pub note: Note,
    pub token_id: u8,
    pub token_address: Address,
    pub recipient: Address,
    pub proof: ProofCalldata,
    pub merkle_proof: MerklePath,
}

#[derive(Clone)]
pub struct WithdrawClient<A: ConnectedAccount + Sync> {
    pub account: A,
    pub shielded_notes_address: Address,
    pub retry: RetryConfig,
}

impl<A: ConnectedAccount + Sync> WithdrawClient<A> {
    pub fn new(account: A, shielded_notes_address: Address) -> Self {
        Self {
            account,
            shielded_notes_address,
            retry: RetryConfig::default(),
        }
    }

    pub async fn withdraw(&self, request: WithdrawRequest) -> Result<TxHash, ClientError> {
        if request.token_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("token address is zero".to_string()));
        }
        if request.recipient == Felt::ZERO {
            return Err(ClientError::InvalidInput("recipient is zero".to_string()));
        }
        if self.shielded_notes_address == Felt::ZERO {
            return Err(ClientError::InvalidInput("shielded notes address is zero".to_string()));
        }
        let commitment = crate::notes::compute_commitment(&request.note, request.token_id)?;
        if commitment != request.merkle_proof.commitment {
            return Err(ClientError::InvalidInput("commitment mismatch".to_string()));
        }
        let _nullifier = generate_nullifier_hash(&request.note, request.token_id)?;
        let mut calldata: Vec<Felt> = request
            .proof
            .to_calldata()
            .into_iter()
            .map(|value| {
                parse_felt(&value)
                    .map_err(|_| ClientError::InvalidInput("invalid proof calldata".to_string()))
            })
            .collect::<Result<Vec<_>, _>>()?;
        calldata.extend(serialize_merkle_proof(&request.merkle_proof)?);

        let entrypoint = match request.token_id {
            0 => "withdraw_token0",
            1 => "withdraw_token1",
            _ => return Err(ClientError::InvalidInput("invalid token id".to_string())),
        };
        let selector = get_selector_from_name(entrypoint)
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = Call {
            to: self.shielded_notes_address,
            selector,
            calldata,
        };
        execute_with_retry(&self.account, call, self.retry.clone()).await
    }
}
