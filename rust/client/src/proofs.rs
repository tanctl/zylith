use std::collections::HashMap;
use std::path::PathBuf;

use num_bigint::BigUint;
use num_traits::{CheckedSub, One, ToPrimitive, Zero};
use serde_json::Value;
use starknet::accounts::ConnectedAccount;
use starknet::core::types::{BlockId, BlockTag, Felt, FunctionCall, U256};
use starknet::core::utils::get_selector_from_name;
use starknet::providers::Provider;

use crate::client::{PoolConfig, ZylithClient};
use crate::error::ClientError;
use crate::generated_constants;
use crate::notes::{
    compute_commitment, compute_position_commitment, generate_note_with_token_id,
    generate_nullifier_hash, generate_position_note, generate_position_nullifier_hash, Note,
    PositionNote,
};
use crate::swap::{
    asp_client, with_retry, MerklePath, SignedAmount, SwapClient, SwapQuoteRequest, SwapStepsQuote,
};
use crate::utils::felt_to_u128;
use zylith_prover::{
    prove_lp_add, prove_lp_claim, prove_lp_remove, prove_swap, prove_swap_exact_out, LpWitnessInputs,
    ProofCalldata, SwapWitnessInputs, WitnessValue,
};

const VK_SWAP_DEC: &str = "1398227280";
const VK_SWAP_EXACT_OUT_DEC: &str = "1690353060931437599809942001243476";
const VK_LIQ_ADD_DEC: &str = "21472712069301316";
const VK_LIQ_REMOVE_DEC: &str = "360252328511171296450117";
const VK_LIQ_CLAIM_DEC: &str = "1407235658182455019853";

const U128_MAX: u128 = 0xffffffffffffffffffffffffffffffff;

#[derive(Debug, Clone)]
pub struct SwapProveRequest {
    pub notes: Vec<Note>,
    pub zero_for_one: bool,
    pub exact_out: bool,
    pub amount_out: Option<u128>,
    pub sqrt_ratio_limit: Option<U256>,
    pub output_note: Option<Note>,
    pub change_note: Option<Note>,
    pub circuit_dir: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct SwapProveResult {
    pub proof: ProofCalldata,
    pub input_proofs: Vec<MerklePath>,
    pub output_proofs: Vec<MerklePath>,
    pub output_note: Option<Note>,
    pub change_note: Option<Note>,
    pub amount_out: u128,
    pub amount_in_consumed: u128,
}

#[derive(Debug, Clone)]
pub struct LiquidityAddProveRequest {
    pub token0_notes: Vec<Note>,
    pub token1_notes: Vec<Note>,
    pub position_note: Option<PositionNote>,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub liquidity_delta: u128,
    pub output_position_note: Option<PositionNote>,
    pub output_note_token0: Option<Note>,
    pub output_note_token1: Option<Note>,
    pub circuit_dir: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct LiquidityRemoveProveRequest {
    pub position_note: PositionNote,
    pub liquidity_delta: u128,
    pub output_position_note: Option<PositionNote>,
    pub output_note_token0: Option<Note>,
    pub output_note_token1: Option<Note>,
    pub circuit_dir: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct LiquidityClaimProveRequest {
    pub position_note: PositionNote,
    pub output_position_note: Option<PositionNote>,
    pub output_note_token0: Option<Note>,
    pub output_note_token1: Option<Note>,
    pub circuit_dir: Option<PathBuf>,
}

#[derive(Debug, Clone)]
pub struct LiquidityProveResult {
    pub proof: ProofCalldata,
    pub proofs_token0: Vec<MerklePath>,
    pub proofs_token1: Vec<MerklePath>,
    pub proof_position: Option<MerklePath>,
    pub insert_proof_position: Option<MerklePath>,
    pub output_proof_token0: Option<MerklePath>,
    pub output_proof_token1: Option<MerklePath>,
    pub output_note_token0: Option<Note>,
    pub output_note_token1: Option<Note>,
    pub output_position_note: Option<PositionNote>,
}

impl<A: ConnectedAccount + Sync + Send> ZylithClient<A> {
    pub async fn prove_swap(&self, request: SwapProveRequest) -> Result<SwapProveResult, ClientError> {
        let swap_client = self.swap_client();
        let pool_config = swap_client.get_pool_config().await?;
        if request.notes.len() > generated_constants::MAX_INPUT_NOTES {
            return Err(ClientError::InvalidInput("too many input notes".to_string()));
        }
        let (token_id_in, input_token, output_token) =
            resolve_swap_tokens(&request.notes, &pool_config, request.zero_for_one)?;

        let total_amount_in = sum_note_amounts(&request.notes)?;
        if total_amount_in == 0 {
            return Err(ClientError::InvalidInput("input amount is zero".to_string()));
        }
        let amount_out_requested = if request.exact_out {
            request
                .amount_out
                .ok_or_else(|| ClientError::InvalidInput("missing amount_out".to_string()))?
        } else {
            0
        };
        if request.exact_out && amount_out_requested == 0 {
            return Err(ClientError::InvalidInput("amount_out is zero".to_string()));
        }
        let sqrt_ratio_limit =
            request
                .sqrt_ratio_limit
                .unwrap_or_else(|| default_sqrt_ratio_limit(&pool_config, request.zero_for_one));

        let is_token1 = if request.exact_out {
            request.zero_for_one
        } else {
            !request.zero_for_one
        };
        let quote_amount = if request.exact_out {
            SignedAmount { mag: amount_out_requested, sign: true }
        } else {
            SignedAmount { mag: total_amount_in, sign: false }
        };
        let mut quote = swap_client
            .quote_swap_steps(SwapQuoteRequest {
                amount: quote_amount,
                is_token1,
                sqrt_ratio_limit,
                skip_ahead: 0,
            })
            .await?;
        if quote.sqrt_price_start == U256::from(0u128) {
            return Err(ClientError::InvalidInput(
                "swap quote sqrt_price_start is zero".to_string(),
            ));
        }
        if quote
            .steps
            .iter()
            .any(|step| step.sqrt_price_limit == U256::from(0u128))
        {
            return Err(ClientError::InvalidInput(
                "swap quote sqrt_price_limit is zero".to_string(),
            ));
        }

        let max_steps = generated_constants::MAX_SWAP_STEPS;
        if quote.steps.len() != max_steps {
            return Err(ClientError::Rpc("unexpected swap steps length".to_string()));
        }

        let mut step_liquidity = compute_step_liquidity(
            &swap_client,
            &quote,
            request.zero_for_one,
        )
        .await?;
        let remaining_start = if request.exact_out {
            amount_out_requested
        } else {
            total_amount_in
        };
        if let Some(adjusted) = maybe_truncate_quote_for_zero_liquidity(
            &quote,
            &step_liquidity,
            remaining_start,
            request.exact_out,
            request.zero_for_one,
        )? {
            quote = adjusted;
            step_liquidity = compute_step_liquidity(&swap_client, &quote, request.zero_for_one).await?;
        }

        let (_step_amount_in, _step_amount_out, amount_out_total, amount_in_consumed) =
            summarize_swap_amounts(&quote.steps)?;
        if request.exact_out && amount_out_total != amount_out_requested {
            return Err(ClientError::InvalidInput("quoted amount_out mismatch".to_string()));
        }

        let change_amount = total_amount_in
            .checked_sub(amount_in_consumed)
            .ok_or_else(|| ClientError::InvalidInput("input amount underflow".to_string()))?;

        let output_note = build_output_note(
            request.output_note.clone(),
            amount_out_total,
            output_token,
            1 - token_id_in,
        )?;
        let change_note = build_output_note(
            request.change_note.clone(),
            change_amount,
            input_token,
            token_id_in,
        )?;

        let output_commitment = match &output_note {
            Some(note) => compute_commitment(note, 1 - token_id_in)?,
            None => Felt::ZERO,
        };
        let change_commitment = match &change_note {
            Some(note) => compute_commitment(note, token_id_in)?,
            None => Felt::ZERO,
        };

        let (input_proofs, merkle_root) =
            fetch_input_proofs(&swap_client, &request.notes, token_id_in, input_token).await?;

        let mut output_proofs = Vec::new();
        if output_note.is_some() {
            output_proofs.push(swap_client.fetch_insertion_path(output_token).await?);
        }
        if change_note.is_some() {
            output_proofs.push(swap_client.fetch_insertion_path(input_token).await?);
        }

        let swap_witness = if request.exact_out {
            build_swap_witness_exact_out(
                &request,
                &output_note,
                &change_note,
                &pool_config,
                &quote,
                &step_liquidity,
                &merkle_root,
                output_commitment,
                change_commitment,
                amount_out_total,
            )?
        } else {
            build_swap_witness_exact_in(
                &request,
                &output_note,
                &change_note,
                &pool_config,
                &quote,
                &step_liquidity,
                &merkle_root,
                output_commitment,
                change_commitment,
            )?
        };

        let circuit_dir = request
            .circuit_dir
            .unwrap_or_else(|| default_circuit_dir(if request.exact_out { "private_swap_exact_out" } else { "private_swap" }));
        let proof = if request.exact_out {
            prove_swap_exact_out(swap_witness, &circuit_dir)
                .await
                .map_err(|e| ClientError::Prover(e.to_string()))?
        } else {
            prove_swap(swap_witness, &circuit_dir)
                .await
                .map_err(|e| ClientError::Prover(e.to_string()))?
        };

        Ok(SwapProveResult {
            proof,
            input_proofs,
            output_proofs,
            output_note,
            change_note,
            amount_out: amount_out_total,
            amount_in_consumed,
        })
    }

    pub async fn prove_liquidity_add(
        &self,
        request: LiquidityAddProveRequest,
    ) -> Result<LiquidityProveResult, ClientError> {
        let swap_client = self.swap_client();
        let pool_config = swap_client.get_pool_config().await?;
        if request.token0_notes.len() > generated_constants::MAX_INPUT_NOTES {
            return Err(ClientError::InvalidInput("too many token0 notes".to_string()));
        }
        if request.token1_notes.len() > generated_constants::MAX_INPUT_NOTES {
            return Err(ClientError::InvalidInput("too many token1 notes".to_string()));
        }
        let tick_lower = request.tick_lower;
        let tick_upper = request.tick_upper;
        let liquidity_delta = request.liquidity_delta;
        if liquidity_delta == 0 {
            return Err(ClientError::InvalidInput("liquidity_delta is zero".to_string()));
        }

        if let Some(note) = &request.position_note {
            if note.tick_lower != tick_lower || note.tick_upper != tick_upper {
                return Err(ClientError::InvalidInput(
                    "position note tick bounds mismatch".to_string(),
                ));
            }
        }

        let pool_state = self.get_pool_state().await?;
        let sqrt_price_start = pool_state.sqrt_price;
        let tick_start = pool_state.tick;
        let liquidity_before = pool_state.liquidity;
        let fee_growth_global_0_before =
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1);
        let fee_growth_global_1_before =
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1);

        let (sqrt_ratio_lower, sqrt_ratio_upper) = fetch_tick_sqrt_ratios(
            &swap_client,
            tick_lower,
            tick_upper,
        )
        .await?;
        let (fee_growth_inside_0_after, fee_growth_inside_1_after) =
            fetch_fee_growth_inside(&swap_client, tick_lower, tick_upper).await?;

        let (
            position_commitment_in,
            nullifier_position,
            position_liquidity,
            fee_inside_0_before,
            fee_inside_1_before,
            mut position_secret_in,
            mut position_nullifier_seed_in,
        ) = match &request.position_note {
                Some(note) => {
                    let commitment = compute_position_commitment(note)?;
                    let nullifier = generate_position_nullifier_hash(note)?;
                    (
                        commitment,
                        nullifier,
                        note.liquidity,
                        note.fee_growth_inside_0,
                        note.fee_growth_inside_1,
                        Some(note.secret),
                        Some(note.nullifier),
                    )
                }
                None => (
                    Felt::ZERO,
                    Felt::ZERO,
                    liquidity_delta,
                    fee_growth_inside_0_after,
                    fee_growth_inside_1_after,
                    None,
                    None,
                ),
            };
        if position_secret_in.is_none() {
            let dummy = generate_position_note(
                tick_lower,
                tick_upper,
                position_liquidity,
                fee_inside_0_before,
                fee_inside_1_before,
            )?;
            position_secret_in = Some(dummy.secret);
            position_nullifier_seed_in = Some(dummy.nullifier);
        }

        let new_liquidity = if request.position_note.is_some() {
            position_liquidity
                .checked_add(liquidity_delta)
                .ok_or_else(|| ClientError::InvalidInput("liquidity overflow".to_string()))?
        } else {
            position_liquidity
        };
        let output_position_note = build_position_note(
            request.output_position_note,
            tick_lower,
            tick_upper,
            new_liquidity,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
        )?;
        let new_position_commitment = compute_position_commitment(&output_position_note)?;

        let (amount0, amount1, amount0_below_div_q, amount0_inside_div_q) =
            compute_liquidity_amounts(
                sqrt_price_start,
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity_delta,
                true,
            )?;
        let (token0_total, token1_total) = (
            sum_note_amounts(&request.token0_notes)?,
            sum_note_amounts(&request.token1_notes)?,
        );
        if token0_total < amount0 || token1_total < amount1 {
            return Err(ClientError::InvalidInput(
                "input notes do not cover liquidity".to_string(),
            ));
        }
        let change0 = token0_total - amount0;
        let change1 = token1_total - amount1;

        let output_note_token0 = build_output_note(
            request.output_note_token0,
            change0,
            pool_config.token0,
            0,
        )?;
        let output_note_token1 = build_output_note(
            request.output_note_token1,
            change1,
            pool_config.token1,
            1,
        )?;

        let output_commitment_token0 = match &output_note_token0 {
            Some(note) => compute_commitment(note, 0)?,
            None => Felt::ZERO,
        };
        let output_commitment_token1 = match &output_note_token1 {
            Some(note) => compute_commitment(note, 1)?,
            None => Felt::ZERO,
        };
        let (proofs_token0, root_token0) =
            fetch_input_proofs(&swap_client, &request.token0_notes, 0, pool_config.token0).await?;
        let (proofs_token1, root_token1) =
            fetch_input_proofs(&swap_client, &request.token1_notes, 1, pool_config.token1).await?;
        let root_position = fetch_position_root(&swap_client, position_commitment_in).await?;

        let proof_position = if position_commitment_in != Felt::ZERO {
            Some(swap_client.fetch_merkle_path(position_commitment_in, None, None).await?)
        } else {
            None
        };
        let insert_proof_position = Some(swap_client.fetch_position_insertion_path().await?);

        let output_proof_token0 = if output_note_token0.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token0).await?)
        } else {
            None
        };
        let output_proof_token1 = if output_note_token1.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token1).await?)
        } else {
            None
        };

        let witness = build_liquidity_witness(
            &pool_config,
            VK_LIQ_ADD_DEC,
            root_token0,
            root_token1,
            root_position,
            nullifier_position,
            sqrt_price_start,
            tick_start,
            liquidity_before,
            fee_growth_global_0_before,
            fee_growth_global_1_before,
            tick_lower,
            tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            true,
            position_liquidity,
            liquidity_delta,
            position_commitment_in,
            new_position_commitment,
            fee_inside_0_before,
            fee_inside_1_before,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
            &request.token0_notes,
            &request.token1_notes,
            output_commitment_token0,
            output_commitment_token1,
            position_secret_in,
            position_nullifier_seed_in,
            output_position_note.secret,
            output_position_note.nullifier,
            output_note_token0.as_ref().map(|note| note.secret),
            output_note_token0.as_ref().map(|note| note.nullifier),
            output_note_token1.as_ref().map(|note| note.secret),
            output_note_token1.as_ref().map(|note| note.nullifier),
            0,
            0,
            amount0_below_div_q,
            amount0_inside_div_q,
        )?;

        let circuit_dir = request
            .circuit_dir
            .unwrap_or_else(|| default_circuit_dir("private_liquidity"));
        let proof = prove_lp_add(witness, &circuit_dir)
            .await
            .map_err(|e| ClientError::Prover(e.to_string()))?;

        Ok(LiquidityProveResult {
            proof,
            proofs_token0,
            proofs_token1,
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
            output_note_token0,
            output_note_token1,
            output_position_note: Some(output_position_note),
        })
    }

    pub async fn prove_liquidity_remove(
        &self,
        request: LiquidityRemoveProveRequest,
    ) -> Result<LiquidityProveResult, ClientError> {
        let swap_client = self.swap_client();
        let pool_config = swap_client.get_pool_config().await?;
        let position_note = request.position_note;
        let liquidity_delta = request.liquidity_delta;
        if liquidity_delta == 0 {
            return Err(ClientError::InvalidInput("liquidity_delta is zero".to_string()));
        }
        if liquidity_delta > position_note.liquidity {
            return Err(ClientError::InvalidInput(
                "liquidity_delta exceeds position".to_string(),
            ));
        }

        let pool_state = self.get_pool_state().await?;
        let sqrt_price_start = pool_state.sqrt_price;
        let tick_start = pool_state.tick;
        let liquidity_before = pool_state.liquidity;
        let fee_growth_global_0_before =
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1);
        let fee_growth_global_1_before =
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1);
        let (sqrt_ratio_lower, sqrt_ratio_upper) = fetch_tick_sqrt_ratios(
            &swap_client,
            position_note.tick_lower,
            position_note.tick_upper,
        )
        .await?;
        let (fee_growth_inside_0_after, fee_growth_inside_1_after) = fetch_fee_growth_inside(
            &swap_client,
            position_note.tick_lower,
            position_note.tick_upper,
        )
        .await?;

        let position_commitment_in = compute_position_commitment(&position_note)?;
        let nullifier_position = generate_position_nullifier_hash(&position_note)?;
        let remaining_liquidity = position_note
            .liquidity
            .checked_sub(liquidity_delta)
            .ok_or_else(|| ClientError::InvalidInput("liquidity underflow".to_string()))?;

        let output_position_note = if remaining_liquidity == 0 {
            None
        } else {
            Some(build_position_note(
                request.output_position_note,
                position_note.tick_lower,
                position_note.tick_upper,
                remaining_liquidity,
                fee_growth_inside_0_after,
                fee_growth_inside_1_after,
            )?)
        };
        let (position_secret_out, position_nullifier_seed_out) = match &output_position_note {
            Some(note) => (note.secret, note.nullifier),
            None => {
                let dummy = generate_position_note(
                    position_note.tick_lower,
                    position_note.tick_upper,
                    remaining_liquidity,
                    fee_growth_inside_0_after,
                    fee_growth_inside_1_after,
                )?;
                (dummy.secret, dummy.nullifier)
            }
        };

        let new_position_commitment = match &output_position_note {
            Some(note) => compute_position_commitment(note)?,
            None => Felt::ZERO,
        };

        let (amount0, amount1, amount0_below_div_q, amount0_inside_div_q) =
            compute_liquidity_amounts(
                sqrt_price_start,
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity_delta,
                false,
            )?;
        let (fee_amount0, fee_amount1) = compute_fee_amounts(
            position_note.liquidity,
            position_note.fee_growth_inside_0,
            position_note.fee_growth_inside_1,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
        )?;
        let protocol_fee_0 = compute_fee(amount0, pool_config.fee);
        let protocol_fee_1 = compute_fee(amount1, pool_config.fee);

        let out_amount0 = amount0
            .checked_sub(protocol_fee_0)
            .and_then(|val| val.checked_add(fee_amount0))
            .ok_or_else(|| ClientError::InvalidInput("token0 output underflow".to_string()))?;
        let out_amount1 = amount1
            .checked_sub(protocol_fee_1)
            .and_then(|val| val.checked_add(fee_amount1))
            .ok_or_else(|| ClientError::InvalidInput("token1 output underflow".to_string()))?;

        let output_note_token0 = build_output_note(
            request.output_note_token0,
            out_amount0,
            pool_config.token0,
            0,
        )?;
        let output_note_token1 = build_output_note(
            request.output_note_token1,
            out_amount1,
            pool_config.token1,
            1,
        )?;

        let output_commitment_token0 = match &output_note_token0 {
            Some(note) => compute_commitment(note, 0)?,
            None => Felt::ZERO,
        };
        let output_commitment_token1 = match &output_note_token1 {
            Some(note) => compute_commitment(note, 1)?,
            None => Felt::ZERO,
        };

        let root_token0 = fetch_latest_root(&swap_client, pool_config.token0).await?;
        let root_token1 = fetch_latest_root(&swap_client, pool_config.token1).await?;
        let root_position = fetch_position_root(&swap_client, position_commitment_in).await?;

        let proof_position = Some(swap_client.fetch_merkle_path(position_commitment_in, None, None).await?);
        let insert_proof_position = if new_position_commitment != Felt::ZERO {
            Some(swap_client.fetch_position_insertion_path().await?)
        } else {
            None
        };
        let output_proof_token0 = if output_note_token0.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token0).await?)
        } else {
            None
        };
        let output_proof_token1 = if output_note_token1.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token1).await?)
        } else {
            None
        };

        let witness = build_liquidity_witness(
            &pool_config,
            VK_LIQ_REMOVE_DEC,
            root_token0,
            root_token1,
            root_position,
            nullifier_position,
            sqrt_price_start,
            tick_start,
            liquidity_before,
            fee_growth_global_0_before,
            fee_growth_global_1_before,
            position_note.tick_lower,
            position_note.tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            false,
            position_note.liquidity,
            liquidity_delta,
            position_commitment_in,
            new_position_commitment,
            position_note.fee_growth_inside_0,
            position_note.fee_growth_inside_1,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
            &[],
            &[],
            output_commitment_token0,
            output_commitment_token1,
            Some(position_note.secret),
            Some(position_note.nullifier),
            position_secret_out,
            position_nullifier_seed_out,
            output_note_token0.as_ref().map(|note| note.secret),
            output_note_token0.as_ref().map(|note| note.nullifier),
            output_note_token1.as_ref().map(|note| note.secret),
            output_note_token1.as_ref().map(|note| note.nullifier),
            protocol_fee_0,
            protocol_fee_1,
            amount0_below_div_q,
            amount0_inside_div_q,
        )?;

        let circuit_dir = request
            .circuit_dir
            .unwrap_or_else(|| default_circuit_dir("private_liquidity"));
        let proof = prove_lp_remove(witness, &circuit_dir)
            .await
            .map_err(|e| ClientError::Prover(e.to_string()))?;

        Ok(LiquidityProveResult {
            proof,
            proofs_token0: Vec::new(),
            proofs_token1: Vec::new(),
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
            output_note_token0,
            output_note_token1,
            output_position_note,
        })
    }

    pub async fn prove_liquidity_claim(
        &self,
        request: LiquidityClaimProveRequest,
    ) -> Result<LiquidityProveResult, ClientError> {
        let swap_client = self.swap_client();
        let pool_config = swap_client.get_pool_config().await?;
        let position_note = request.position_note;

        let pool_state = self.get_pool_state().await?;
        let sqrt_price_start = pool_state.sqrt_price;
        let tick_start = pool_state.tick;
        let liquidity_before = pool_state.liquidity;
        let fee_growth_global_0_before =
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1);
        let fee_growth_global_1_before =
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1);
        let (sqrt_ratio_lower, sqrt_ratio_upper) = fetch_tick_sqrt_ratios(
            &swap_client,
            position_note.tick_lower,
            position_note.tick_upper,
        )
        .await?;
        let (fee_growth_inside_0_after, fee_growth_inside_1_after) = fetch_fee_growth_inside(
            &swap_client,
            position_note.tick_lower,
            position_note.tick_upper,
        )
        .await?;

        let position_commitment_in = compute_position_commitment(&position_note)?;
        let nullifier_position = generate_position_nullifier_hash(&position_note)?;

        let output_position_note = build_position_note(
            request.output_position_note,
            position_note.tick_lower,
            position_note.tick_upper,
            position_note.liquidity,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
        )?;
        let new_position_commitment = compute_position_commitment(&output_position_note)?;

        let (fee_amount0, fee_amount1) = compute_fee_amounts(
            position_note.liquidity,
            position_note.fee_growth_inside_0,
            position_note.fee_growth_inside_1,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
        )?;

        let output_note_token0 = build_output_note(
            request.output_note_token0,
            fee_amount0,
            pool_config.token0,
            0,
        )?;
        let output_note_token1 = build_output_note(
            request.output_note_token1,
            fee_amount1,
            pool_config.token1,
            1,
        )?;
        let output_commitment_token0 = match &output_note_token0 {
            Some(note) => compute_commitment(note, 0)?,
            None => Felt::ZERO,
        };
        let output_commitment_token1 = match &output_note_token1 {
            Some(note) => compute_commitment(note, 1)?,
            None => Felt::ZERO,
        };

        let root_token0 = fetch_latest_root(&swap_client, pool_config.token0).await?;
        let root_token1 = fetch_latest_root(&swap_client, pool_config.token1).await?;
        let root_position = fetch_position_root(&swap_client, position_commitment_in).await?;

        let proof_position = Some(swap_client.fetch_merkle_path(position_commitment_in, None, None).await?);
        let insert_proof_position = Some(swap_client.fetch_position_insertion_path().await?);
        let output_proof_token0 = if output_note_token0.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token0).await?)
        } else {
            None
        };
        let output_proof_token1 = if output_note_token1.is_some() {
            Some(swap_client.fetch_insertion_path(pool_config.token1).await?)
        } else {
            None
        };

        let witness = build_liquidity_witness(
            &pool_config,
            VK_LIQ_CLAIM_DEC,
            root_token0,
            root_token1,
            root_position,
            nullifier_position,
            sqrt_price_start,
            tick_start,
            liquidity_before,
            fee_growth_global_0_before,
            fee_growth_global_1_before,
            position_note.tick_lower,
            position_note.tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            false,
            position_note.liquidity,
            0,
            position_commitment_in,
            new_position_commitment,
            position_note.fee_growth_inside_0,
            position_note.fee_growth_inside_1,
            fee_growth_inside_0_after,
            fee_growth_inside_1_after,
            &[],
            &[],
            output_commitment_token0,
            output_commitment_token1,
            Some(position_note.secret),
            Some(position_note.nullifier),
            output_position_note.secret,
            output_position_note.nullifier,
            output_note_token0.as_ref().map(|note| note.secret),
            output_note_token0.as_ref().map(|note| note.nullifier),
            output_note_token1.as_ref().map(|note| note.secret),
            output_note_token1.as_ref().map(|note| note.nullifier),
            0,
            0,
            empty_div_matrix(),
            empty_div_matrix(),
        )?;

        let circuit_dir = request
            .circuit_dir
            .unwrap_or_else(|| default_circuit_dir("private_liquidity"));
        let proof = prove_lp_claim(witness, &circuit_dir)
            .await
            .map_err(|e| ClientError::Prover(e.to_string()))?;

        Ok(LiquidityProveResult {
            proof,
            proofs_token0: Vec::new(),
            proofs_token1: Vec::new(),
            proof_position,
            insert_proof_position,
            output_proof_token0,
            output_proof_token1,
            output_note_token0,
            output_note_token1,
            output_position_note: Some(output_position_note),
        })
    }
}

fn resolve_swap_tokens(
    notes: &[Note],
    pool_config: &PoolConfig,
    zero_for_one: bool,
) -> Result<(u8, Felt, Felt), ClientError> {
    if notes.is_empty() {
        return Err(ClientError::InvalidInput("notes cannot be empty".to_string()));
    }
    let token_id_in = token_id_from_note(notes[0].token, pool_config)?;
    for note in &notes[1..] {
        let token_id = token_id_from_note(note.token, pool_config)?;
        if token_id != token_id_in {
            return Err(ClientError::InvalidInput(
                "all input notes must share token".to_string(),
            ));
        }
    }
    if zero_for_one && token_id_in != 0 {
        return Err(ClientError::InvalidInput(
            "zero_for_one requires token0 input".to_string(),
        ));
    }
    if !zero_for_one && token_id_in != 1 {
        return Err(ClientError::InvalidInput(
            "zero_for_one=false requires token1 input".to_string(),
        ));
    }
    let input_token = if token_id_in == 0 {
        pool_config.token0
    } else {
        pool_config.token1
    };
    let output_token = if token_id_in == 0 {
        pool_config.token1
    } else {
        pool_config.token0
    };
    Ok((token_id_in, input_token, output_token))
}

fn token_id_from_note(token: Felt, config: &PoolConfig) -> Result<u8, ClientError> {
    if token == config.token0 {
        Ok(0)
    } else if token == config.token1 {
        Ok(1)
    } else {
        Err(ClientError::InvalidInput("note token not in pool".to_string()))
    }
}

fn default_sqrt_ratio_limit(config: &PoolConfig, zero_for_one: bool) -> U256 {
    if zero_for_one {
        config.min_sqrt_ratio
    } else {
        config.max_sqrt_ratio
    }
}

fn sum_note_amounts(notes: &[Note]) -> Result<u128, ClientError> {
    let mut total = 0u128;
    for note in notes {
        total = total
            .checked_add(note.amount)
            .ok_or_else(|| ClientError::InvalidInput("note amount overflow".to_string()))?;
    }
    Ok(total)
}

fn summarize_swap_amounts(
    steps: &[crate::swap::SwapStepQuote],
) -> Result<(Vec<u128>, Vec<u128>, u128, u128), ClientError> {
    let mut in_amounts = Vec::with_capacity(steps.len());
    let mut out_amounts = Vec::with_capacity(steps.len());
    let mut total_in = 0u128;
    let mut total_out = 0u128;
    for step in steps {
        total_in = total_in
            .checked_add(step.amount_in)
            .ok_or_else(|| ClientError::InvalidInput("amount_in overflow".to_string()))?;
        total_out = total_out
            .checked_add(step.amount_out)
            .ok_or_else(|| ClientError::InvalidInput("amount_out overflow".to_string()))?;
        in_amounts.push(step.amount_in);
        out_amounts.push(step.amount_out);
    }
    Ok((in_amounts, out_amounts, total_out, total_in))
}

fn compute_is_limited(quote: &SwapStepsQuote, zero_for_one: bool) -> bool {
    let sqrt_price_end = quote.sqrt_price_end;
    for step in &quote.steps {
        let step_limit = if zero_for_one {
            if sqrt_price_end > step.sqrt_price_limit {
                sqrt_price_end
            } else {
                step.sqrt_price_limit
            }
        } else if sqrt_price_end < step.sqrt_price_limit {
            sqrt_price_end
        } else {
            step.sqrt_price_limit
        };
        if step.sqrt_price_next == step_limit {
            return true;
        }
    }
    false
}

fn maybe_truncate_quote_for_zero_liquidity(
    quote: &SwapStepsQuote,
    step_liquidity: &[u128],
    remaining_start: u128,
    exact_out: bool,
    zero_for_one: bool,
) -> Result<Option<SwapStepsQuote>, ClientError> {
    if !zero_for_one {
        return Ok(None);
    }
    if step_liquidity.len() != quote.steps.len() {
        return Err(ClientError::InvalidInput("step liquidity length mismatch".to_string()));
    }

    let mut remaining = remaining_start;
    for (idx, step) in quote.steps.iter().enumerate() {
        if remaining == 0 {
            break;
        }
        if step_liquidity[idx] == 0 {
            let mut adjusted = quote.clone();
            let sqrt_price_end = if idx == 0 {
                adjusted.sqrt_price_start
            } else {
                adjusted.steps[idx - 1].sqrt_price_next
            };
            let fee_growth_0 = if idx == 0 {
                adjusted.fee_growth_global_0_before
            } else {
                adjusted.steps[idx - 1].fee_growth_global_0
            };
            let fee_growth_1 = if idx == 0 {
                adjusted.fee_growth_global_1_before
            } else {
                adjusted.steps[idx - 1].fee_growth_global_1
            };
            let template = adjusted
                .steps
                .get(idx)
                .cloned()
                .ok_or_else(|| ClientError::InvalidInput("halt step out of range".to_string()))?;

            for step_mut in adjusted.steps.iter_mut().skip(idx) {
                step_mut.sqrt_price_next = sqrt_price_end;
                step_mut.sqrt_price_limit = template.sqrt_price_limit;
                step_mut.tick_next = template.tick_next;
                step_mut.liquidity_net = template.liquidity_net;
                step_mut.amount_in = 0;
                step_mut.amount_out = 0;
                step_mut.fee_amount = 0;
                step_mut.fee_growth_global_0 = fee_growth_0;
                step_mut.fee_growth_global_1 = fee_growth_1;
            }

            adjusted.sqrt_price_end = sqrt_price_end;
            adjusted.fee_growth_global_0_after = fee_growth_0;
            adjusted.fee_growth_global_1_after = fee_growth_1;
            adjusted.is_limited = compute_is_limited(&adjusted, zero_for_one);
            return Ok(Some(adjusted));
        }
        let consumed = if exact_out { step.amount_out } else { step.amount_in };
        remaining = remaining
            .checked_sub(consumed)
            .ok_or_else(|| ClientError::InvalidInput("swap remaining underflow".to_string()))?;
    }
    Ok(None)
}

async fn compute_step_liquidity<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    quote: &SwapStepsQuote,
    zero_for_one: bool,
) -> Result<Vec<u128>, ClientError> {
    let mut liquidity = quote.liquidity_start;
    let mut step_liquidity = Vec::with_capacity(quote.steps.len());
    for step in &quote.steps {
        step_liquidity.push(liquidity);
        let tick_ratio = fetch_sqrt_ratio_at_tick(swap_client, step.tick_next).await?;
        if step.sqrt_price_next == tick_ratio {
            let (sign, mag) = decode_signed_u256(step.liquidity_net)?;
            if zero_for_one {
                if sign {
                    liquidity = liquidity
                        .checked_add(mag)
                        .ok_or_else(|| ClientError::InvalidInput("liquidity overflow".to_string()))?;
                } else {
                    liquidity = liquidity
                        .checked_sub(mag)
                        .ok_or_else(|| ClientError::InvalidInput("liquidity underflow".to_string()))?;
                }
            } else if sign {
                liquidity = liquidity
                    .checked_sub(mag)
                    .ok_or_else(|| ClientError::InvalidInput("liquidity underflow".to_string()))?;
            } else {
                liquidity = liquidity
                    .checked_add(mag)
                    .ok_or_else(|| ClientError::InvalidInput("liquidity overflow".to_string()))?;
            }
        }
    }
    Ok(step_liquidity)
}

fn build_output_note(
    note: Option<Note>,
    amount: u128,
    token: Felt,
    token_id: u8,
) -> Result<Option<Note>, ClientError> {
    if amount == 0 {
        return Ok(None);
    }
    if let Some(note) = note {
        if note.amount != amount {
            return Err(ClientError::InvalidInput("note amount mismatch".to_string()));
        }
        if note.token != token {
            return Err(ClientError::InvalidInput("note token mismatch".to_string()));
        }
        compute_commitment(&note, token_id)?;
        Ok(Some(note))
    } else {
        Ok(Some(generate_note_with_token_id(amount, token, token_id)?))
    }
}

fn build_position_note(
    note: Option<PositionNote>,
    tick_lower: i32,
    tick_upper: i32,
    liquidity: u128,
    fee_growth_inside_0: U256,
    fee_growth_inside_1: U256,
) -> Result<PositionNote, ClientError> {
    if let Some(note) = note {
        Ok(note)
    } else {
        generate_position_note(
            tick_lower,
            tick_upper,
            liquidity,
            fee_growth_inside_0,
            fee_growth_inside_1,
        )
    }
}

async fn fetch_input_proofs<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    notes: &[Note],
    token_id: u8,
    token: Felt,
) -> Result<(Vec<MerklePath>, Felt), ClientError> {
    if notes.is_empty() {
        let root = fetch_latest_root(swap_client, token).await?;
        return Ok((Vec::new(), root));
    }
    let mut proofs = Vec::with_capacity(notes.len());
    let mut merkle_root = Felt::ZERO;
    for (idx, note) in notes.iter().enumerate() {
        let commitment = compute_commitment(note, token_id)?;
        let proof = swap_client.fetch_merkle_path(commitment, None, None).await?;
        if idx == 0 {
            merkle_root = proof.root;
        } else if proof.root != merkle_root {
            return Err(ClientError::Asp("input roots mismatch".to_string()));
        }
        proofs.push(proof);
    }
    Ok((proofs, merkle_root))
}

async fn fetch_latest_root<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    token: Felt,
) -> Result<Felt, ClientError> {
    let token_label = format!("0x{:x}", token);
    let url = format!(
        "{}/root/latest?token={}",
        swap_client.asp_url.trim_end_matches('/'),
        token_label
    );
    let client = asp_client()?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|err| ClientError::Asp(err.to_string()))?;
    if !response.status().is_success() {
        return Err(ClientError::Asp(format!("asp root error: {}", response.status())));
    }
    let body: RootAtResponse = response.json().await.map_err(ClientError::from)?;
    if body.token != token_label {
        return Err(ClientError::Asp("token mismatch".to_string()));
    }
    let root = parse_hex_felt(&body.root)?;
    Ok(root)
}

async fn fetch_position_root<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    position_commitment: Felt,
) -> Result<Felt, ClientError> {
    if position_commitment != Felt::ZERO {
        let proof = swap_client.fetch_merkle_path(position_commitment, None, None).await?;
        Ok(proof.root)
    } else {
        let url = format!(
            "{}/root/latest?token=position",
            swap_client.asp_url.trim_end_matches('/')
        );
        let client = asp_client()?;
        let response = client
            .get(url)
            .send()
            .await
            .map_err(|err| ClientError::Asp(err.to_string()))?;
        if !response.status().is_success() {
            return Err(ClientError::Asp(format!("asp root error: {}", response.status())));
        }
        let body: RootAtResponse = response.json().await.map_err(ClientError::from)?;
        if body.token != "position" {
            return Err(ClientError::Asp("token mismatch".to_string()));
        }
        parse_hex_felt(&body.root)
    }
}

fn build_swap_witness_exact_in(
    request: &SwapProveRequest,
    output_note: &Option<Note>,
    change_note: &Option<Note>,
    pool_config: &PoolConfig,
    quote: &SwapStepsQuote,
    step_liquidity: &[u128],
    merkle_root: &Felt,
    output_commitment: Felt,
    change_commitment: Felt,
) -> Result<SwapWitnessInputs, ClientError> {
    let max_steps = generated_constants::MAX_SWAP_STEPS;
    let max_notes = generated_constants::MAX_INPUT_NOTES;

    let total_amount_in = sum_note_amounts(&request.notes)?;
    let (step_amount_in, step_amount_out, _amount_out_total, _amount_in_consumed) =
        summarize_swap_amounts(&quote.steps)?;

    let mut step_amount_before_fee_div_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_amount0_limit_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_amount0_calc_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_amount0_out_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_next0_div_floor_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_next0_div_ceil_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_next1_div_floor_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_fee_div_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);

    let mut amount_remaining = total_amount_in;
    let mut sqrt_price_start = u256_to_big(&quote.sqrt_price_start);
    let mut halted = false;
    for (idx, step) in quote.steps.iter().enumerate() {
        let amount_step = if halted { 0 } else { amount_remaining };
        let liquidity = step_liquidity[idx];
        let sqrt_limit = u256_to_big(&step.sqrt_price_limit);
        let (div_before_fee, amt0_limit, amt0_calc, amt0_out, next0_floor, next0_ceil, next1_floor) =
            compute_swap_divs_exact_in(
                sqrt_price_start.clone(),
                sqrt_limit,
                liquidity,
                amount_step,
                pool_config.fee,
                request.zero_for_one,
            )?;
        step_amount_before_fee_div_q.push(div_before_fee);
        step_amount0_limit_div_q.push(amt0_limit);
        step_amount0_calc_div_q.push(amt0_calc);
        step_amount0_out_div_q.push(amt0_out);
        step_next0_div_floor_q.push(next0_floor);
        step_next0_div_ceil_q.push(next0_ceil);
        step_next1_div_floor_q.push(next1_floor);

        let fee_div = compute_fee_div_q(step.fee_amount, liquidity)?;
        step_fee_div_q.push(fee_div);

        amount_remaining = amount_remaining
            .checked_sub(step_amount_in[idx])
            .ok_or_else(|| ClientError::InvalidInput("amount remaining underflow".to_string()))?;
        sqrt_price_start = u256_to_big(&step.sqrt_price_next);
        if step.sqrt_price_next == quote.sqrt_price_end {
            halted = true;
        }
    }

    let (token_id_in, input_token, output_token) =
        resolve_swap_tokens(&request.notes, &pool_config, request.zero_for_one)?;
    let (commitment_in, nullifier, note_count, commitment_extra, nullifier_extra) =
        build_note_public_inputs(&request.notes, token_id_in, max_notes)?;

    let pad_input_note = generate_note_with_token_id(PAD_NOTE_AMOUNT, input_token, token_id_in)?;
    let pad_output_note =
        generate_note_with_token_id(PAD_NOTE_AMOUNT, output_token, 1 - token_id_in)?;
    let secret_in: Vec<[u8; 32]> = pad_note_bytes(
        &request.notes.iter().map(|note| note.secret).collect::<Vec<_>>(),
        max_notes,
        pad_input_note.secret,
    );
    let nullifier_seed_in: Vec<[u8; 32]> = pad_note_bytes(
        &request.notes.iter().map(|note| note.nullifier).collect::<Vec<_>>(),
        max_notes,
        pad_input_note.nullifier,
    );
    let note_amount_in = pad_note_amounts(&request.notes, max_notes);

    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(VK_SWAP_DEC.to_string()));
    values.insert(
        "merkle_root".to_string(),
        WitnessValue::Scalar(felt_to_decimal(*merkle_root)),
    );
    values.insert(
        "nullifier".to_string(),
        WitnessValue::Scalar(felt_to_decimal(nullifier)),
    );
    values.insert(
        "sqrt_price_start".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.sqrt_price_start))),
    );
    values.insert(
        "sqrt_price_end_public".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.sqrt_price_end))),
    );
    values.insert("liquidity_before".to_string(), WitnessValue::U128(quote.liquidity_start));
    values.insert("fee".to_string(), WitnessValue::U128(pool_config.fee));
    values.insert(
        "fee_growth_global_0_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.fee_growth_global_0_before))),
    );
    values.insert(
        "fee_growth_global_1_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.fee_growth_global_1_before))),
    );
    values.insert(
        "output_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(output_commitment)),
    );
    values.insert(
        "change_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(change_commitment)),
    );
    values.insert("is_limited".to_string(), WitnessValue::Bool(quote.is_limited));
    values.insert("zero_for_one".to_string(), WitnessValue::Bool(request.zero_for_one));
    values.insert(
        "step_sqrt_price_next".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.sqrt_price_next).collect::<Vec<_>>())),
    );
    values.insert(
        "step_sqrt_price_limit".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.sqrt_price_limit).collect::<Vec<_>>())),
    );
    values.insert(
        "step_tick_next".to_string(),
        WitnessValue::VecI32(quote.steps.iter().map(|s| s.tick_next).collect()),
    );
    values.insert(
        "step_liquidity_net".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.liquidity_net).collect::<Vec<_>>())),
    );
    values.insert(
        "step_fee_growth_global_0".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.fee_growth_global_0).collect::<Vec<_>>())),
    );
    values.insert(
        "step_fee_growth_global_1".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.fee_growth_global_1).collect::<Vec<_>>())),
    );
    values.insert(
        "commitment_in".to_string(),
        WitnessValue::Scalar(felt_to_decimal(commitment_in)),
    );
    values.insert("token_id_in".to_string(), WitnessValue::U128(token_id_in as u128));
    values.insert("note_count".to_string(), WitnessValue::U128(note_count));
    values.insert(
        "nullifier_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&nullifier_extra)),
    );
    values.insert(
        "commitment_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&commitment_extra)),
    );
    values.insert(
        "step_amount_in".to_string(),
        WitnessValue::VecU128(step_amount_in),
    );
    values.insert(
        "step_amount_out".to_string(),
        WitnessValue::VecU128(step_amount_out),
    );
    values.insert(
        "step_amount_before_fee_div_q".to_string(),
        WitnessValue::MatrixU128(step_amount_before_fee_div_q),
    );
    values.insert(
        "step_amount0_limit_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_limit_div_q),
    );
    values.insert(
        "step_amount0_calc_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_calc_div_q),
    );
    values.insert(
        "step_amount0_out_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_out_div_q),
    );
    values.insert(
        "step_next0_div_floor_q".to_string(),
        WitnessValue::MatrixU128(step_next0_div_floor_q),
    );
    values.insert(
        "step_next0_div_ceil_q".to_string(),
        WitnessValue::MatrixU128(step_next0_div_ceil_q),
    );
    values.insert(
        "step_next1_div_floor_q".to_string(),
        WitnessValue::MatrixU128(step_next1_div_floor_q),
    );
    values.insert("step_fee_div_q".to_string(), WitnessValue::MatrixU128(step_fee_div_q));
    values.insert("note_amount_in".to_string(), WitnessValue::VecU128(note_amount_in));
    values.insert("secret_in".to_string(), WitnessValue::VecBytes32(secret_in));
    values.insert("nullifier_seed_in".to_string(), WitnessValue::VecBytes32(nullifier_seed_in));
    values.insert(
        "secret_out".to_string(),
        WitnessValue::Bytes32(
            output_note
                .as_ref()
                .map(|n| n.secret)
                .unwrap_or(pad_output_note.secret),
        ),
    );
    values.insert(
        "nullifier_seed_out".to_string(),
        WitnessValue::Bytes32(
            output_note
                .as_ref()
                .map(|n| n.nullifier)
                .unwrap_or(pad_output_note.nullifier),
        ),
    );
    values.insert(
        "change_secret".to_string(),
        WitnessValue::Bytes32(
            change_note
                .as_ref()
                .map(|n| n.secret)
                .unwrap_or(pad_input_note.secret),
        ),
    );
    values.insert(
        "change_nullifier_seed".to_string(),
        WitnessValue::Bytes32(
            change_note
                .as_ref()
                .map(|n| n.nullifier)
                .unwrap_or(pad_input_note.nullifier),
        ),
    );
    values.insert("tick_spacing".to_string(), WitnessValue::U128(pool_config.tick_spacing));

    Ok(SwapWitnessInputs { values })
}

fn build_swap_witness_exact_out(
    request: &SwapProveRequest,
    output_note: &Option<Note>,
    change_note: &Option<Note>,
    pool_config: &PoolConfig,
    quote: &SwapStepsQuote,
    step_liquidity: &[u128],
    merkle_root: &Felt,
    output_commitment: Felt,
    change_commitment: Felt,
    amount_out_total: u128,
) -> Result<SwapWitnessInputs, ClientError> {
    let max_steps = generated_constants::MAX_SWAP_STEPS;
    let max_notes = generated_constants::MAX_INPUT_NOTES;
    let (step_amount_in, step_amount_out, _amount_out_total, _amount_in_consumed) =
        summarize_swap_amounts(&quote.steps)?;

    let mut step_amount_before_fee_div_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_amount0_limit_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_amount0_calc_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_amount0_out_div_q: Vec<Vec<Vec<u128>>> = Vec::with_capacity(max_steps);
    let mut step_next0_div_ceil_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_next1_div_floor_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);
    let mut step_fee_div_q: Vec<Vec<u128>> = Vec::with_capacity(max_steps);

    let mut amount_remaining = amount_out_total;
    let mut sqrt_price_start = u256_to_big(&quote.sqrt_price_start);
    let mut halted = false;
    for (idx, step) in quote.steps.iter().enumerate() {
        let amount_step = if halted { 0 } else { amount_remaining };
        let liquidity = step_liquidity[idx];
        let sqrt_limit = u256_to_big(&step.sqrt_price_limit);
        let (
            div_before_fee,
            amt0_limit,
            amt0_calc,
            amt0_out,
            next0_ceil,
            next1_floor,
        ) = compute_swap_divs_exact_out(
            sqrt_price_start.clone(),
            sqrt_limit,
            liquidity,
            amount_step,
            pool_config.fee,
            request.zero_for_one,
        )?;
        step_amount_before_fee_div_q.push(div_before_fee);
        step_amount0_limit_div_q.push(amt0_limit);
        step_amount0_calc_div_q.push(amt0_calc);
        step_amount0_out_div_q.push(amt0_out);
        step_next0_div_ceil_q.push(next0_ceil);
        step_next1_div_floor_q.push(next1_floor);

        let fee_div = compute_fee_div_q(step.fee_amount, liquidity)?;
        step_fee_div_q.push(fee_div);

        amount_remaining = amount_remaining
            .checked_sub(step_amount_out[idx])
            .ok_or_else(|| ClientError::InvalidInput("amount remaining underflow".to_string()))?;
        sqrt_price_start = u256_to_big(&step.sqrt_price_next);
        if step.sqrt_price_next == quote.sqrt_price_end {
            halted = true;
        }
    }

    let (token_id_in, input_token, output_token) =
        resolve_swap_tokens(&request.notes, &pool_config, request.zero_for_one)?;
    let (commitment_in, nullifier, note_count, commitment_extra, nullifier_extra) =
        build_note_public_inputs(&request.notes, token_id_in, max_notes)?;

    let pad_input_note = generate_note_with_token_id(PAD_NOTE_AMOUNT, input_token, token_id_in)?;
    let pad_output_note =
        generate_note_with_token_id(PAD_NOTE_AMOUNT, output_token, 1 - token_id_in)?;
    let secret_in: Vec<[u8; 32]> = pad_note_bytes(
        &request.notes.iter().map(|note| note.secret).collect::<Vec<_>>(),
        max_notes,
        pad_input_note.secret,
    );
    let nullifier_seed_in: Vec<[u8; 32]> = pad_note_bytes(
        &request.notes.iter().map(|note| note.nullifier).collect::<Vec<_>>(),
        max_notes,
        pad_input_note.nullifier,
    );
    let note_amount_in = pad_note_amounts(&request.notes, max_notes);

    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(VK_SWAP_EXACT_OUT_DEC.to_string()));
    values.insert(
        "merkle_root".to_string(),
        WitnessValue::Scalar(felt_to_decimal(*merkle_root)),
    );
    values.insert(
        "nullifier".to_string(),
        WitnessValue::Scalar(felt_to_decimal(nullifier)),
    );
    values.insert(
        "sqrt_price_start".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.sqrt_price_start))),
    );
    values.insert(
        "sqrt_price_end_public".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.sqrt_price_end))),
    );
    values.insert("liquidity_before".to_string(), WitnessValue::U128(quote.liquidity_start));
    values.insert("fee".to_string(), WitnessValue::U128(pool_config.fee));
    values.insert(
        "fee_growth_global_0_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.fee_growth_global_0_before))),
    );
    values.insert(
        "fee_growth_global_1_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&quote.fee_growth_global_1_before))),
    );
    values.insert(
        "output_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(output_commitment)),
    );
    values.insert(
        "change_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(change_commitment)),
    );
    values.insert("is_limited".to_string(), WitnessValue::Bool(quote.is_limited));
    values.insert("zero_for_one".to_string(), WitnessValue::Bool(request.zero_for_one));
    values.insert(
        "step_sqrt_price_next".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.sqrt_price_next).collect::<Vec<_>>())),
    );
    values.insert(
        "step_sqrt_price_limit".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.sqrt_price_limit).collect::<Vec<_>>())),
    );
    values.insert(
        "step_tick_next".to_string(),
        WitnessValue::VecI32(quote.steps.iter().map(|s| s.tick_next).collect()),
    );
    values.insert(
        "step_liquidity_net".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.liquidity_net).collect::<Vec<_>>())),
    );
    values.insert(
        "step_fee_growth_global_0".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.fee_growth_global_0).collect::<Vec<_>>())),
    );
    values.insert(
        "step_fee_growth_global_1".to_string(),
        WitnessValue::Raw(u256_array_to_json(&quote.steps.iter().map(|s| s.fee_growth_global_1).collect::<Vec<_>>())),
    );
    values.insert(
        "commitment_in".to_string(),
        WitnessValue::Scalar(felt_to_decimal(commitment_in)),
    );
    values.insert("token_id_in".to_string(), WitnessValue::U128(token_id_in as u128));
    values.insert("note_count".to_string(), WitnessValue::U128(note_count));
    values.insert(
        "nullifier_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&nullifier_extra)),
    );
    values.insert(
        "commitment_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&commitment_extra)),
    );
    values.insert(
        "step_amount_in".to_string(),
        WitnessValue::VecU128(step_amount_in),
    );
    values.insert(
        "step_amount_out".to_string(),
        WitnessValue::VecU128(step_amount_out),
    );
    values.insert(
        "step_amount_before_fee_div_q".to_string(),
        WitnessValue::MatrixU128(step_amount_before_fee_div_q),
    );
    values.insert(
        "step_amount0_limit_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_limit_div_q),
    );
    values.insert(
        "step_amount0_calc_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_calc_div_q),
    );
    values.insert(
        "step_amount0_out_div_q".to_string(),
        WitnessValue::TensorU128(step_amount0_out_div_q),
    );
    values.insert(
        "step_next0_div_ceil_q".to_string(),
        WitnessValue::MatrixU128(step_next0_div_ceil_q),
    );
    values.insert(
        "step_next1_div_floor_q".to_string(),
        WitnessValue::MatrixU128(step_next1_div_floor_q),
    );
    values.insert("step_fee_div_q".to_string(), WitnessValue::MatrixU128(step_fee_div_q));
    values.insert("note_amount_in".to_string(), WitnessValue::VecU128(note_amount_in));
    values.insert("secret_in".to_string(), WitnessValue::VecBytes32(secret_in));
    values.insert("nullifier_seed_in".to_string(), WitnessValue::VecBytes32(nullifier_seed_in));
    values.insert(
        "secret_out".to_string(),
        WitnessValue::Bytes32(
            output_note
                .as_ref()
                .map(|n| n.secret)
                .unwrap_or(pad_output_note.secret),
        ),
    );
    values.insert(
        "nullifier_seed_out".to_string(),
        WitnessValue::Bytes32(
            output_note
                .as_ref()
                .map(|n| n.nullifier)
                .unwrap_or(pad_output_note.nullifier),
        ),
    );
    values.insert(
        "change_secret".to_string(),
        WitnessValue::Bytes32(
            change_note
                .as_ref()
                .map(|n| n.secret)
                .unwrap_or(pad_input_note.secret),
        ),
    );
    values.insert(
        "change_nullifier_seed".to_string(),
        WitnessValue::Bytes32(
            change_note
                .as_ref()
                .map(|n| n.nullifier)
                .unwrap_or(pad_input_note.nullifier),
        ),
    );
    values.insert("tick_spacing".to_string(), WitnessValue::U128(pool_config.tick_spacing));

    Ok(SwapWitnessInputs { values })
}

fn build_liquidity_witness(
    pool_config: &PoolConfig,
    tag_dec: &str,
    root_token0: Felt,
    root_token1: Felt,
    root_position: Felt,
    nullifier_position: Felt,
    sqrt_price_start: U256,
    tick_start: i32,
    liquidity_before: u128,
    fee_growth_global_0_before: U256,
    fee_growth_global_1_before: U256,
    tick_lower: i32,
    tick_upper: i32,
    sqrt_ratio_lower: U256,
    sqrt_ratio_upper: U256,
    is_add: bool,
    position_liquidity: u128,
    liquidity_delta: u128,
    prev_position_commitment: Felt,
    new_position_commitment: Felt,
    fee_growth_inside_0_before: U256,
    fee_growth_inside_1_before: U256,
    fee_growth_inside_0_after: U256,
    fee_growth_inside_1_after: U256,
    token0_notes: &[Note],
    token1_notes: &[Note],
    output_commitment_token0: Felt,
    output_commitment_token1: Felt,
    position_secret_in: Option<[u8; 32]>,
    position_nullifier_seed_in: Option<[u8; 32]>,
    position_secret_out: [u8; 32],
    position_nullifier_seed_out: [u8; 32],
    out_token0_secret: Option<[u8; 32]>,
    out_token0_nullifier_seed: Option<[u8; 32]>,
    out_token1_secret: Option<[u8; 32]>,
    out_token1_nullifier_seed: Option<[u8; 32]>,
    protocol_fee_0: u128,
    protocol_fee_1: u128,
    amount0_below_div_q: Vec<Vec<u128>>,
    amount0_inside_div_q: Vec<Vec<u128>>,
) -> Result<LpWitnessInputs, ClientError> {
    let max_notes = generated_constants::MAX_INPUT_NOTES;
    let (token0_commitment, token0_nullifier, token0_count, token0_commitment_extra, token0_nullifier_extra) =
        build_note_public_inputs(token0_notes, 0, max_notes)?;
    let (token1_commitment, token1_nullifier, token1_count, token1_commitment_extra, token1_nullifier_extra) =
        build_note_public_inputs(token1_notes, 1, max_notes)?;

    let pad_token0_note = generate_note_with_token_id(PAD_NOTE_AMOUNT, pool_config.token0, 0)?;
    let pad_token1_note = generate_note_with_token_id(PAD_NOTE_AMOUNT, pool_config.token1, 1)?;
    let token0_amounts = pad_note_amounts(token0_notes, max_notes);
    let token1_amounts = pad_note_amounts(token1_notes, max_notes);
    let token0_secrets = pad_note_bytes(
        &token0_notes.iter().map(|note| note.secret).collect::<Vec<_>>(),
        max_notes,
        pad_token0_note.secret,
    );
    let token1_secrets = pad_note_bytes(
        &token1_notes.iter().map(|note| note.secret).collect::<Vec<_>>(),
        max_notes,
        pad_token1_note.secret,
    );
    let token0_nullifier_seeds =
        pad_note_bytes(
            &token0_notes.iter().map(|note| note.nullifier).collect::<Vec<_>>(),
            max_notes,
            pad_token0_note.nullifier,
        );
    let token1_nullifier_seeds =
        pad_note_bytes(
            &token1_notes.iter().map(|note| note.nullifier).collect::<Vec<_>>(),
            max_notes,
            pad_token1_note.nullifier,
        );

    let liquidity_delta_value = if is_add {
        encode_signed_u256(liquidity_delta as i128)?
    } else if liquidity_delta == 0 {
        U256::from(0u128)
    } else {
        encode_signed_u256(-(liquidity_delta as i128))?
    };
    let liquidity_commitment = if is_add {
        new_position_commitment
    } else {
        prev_position_commitment
    };
    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(tag_dec.to_string()));
    values.insert(
        "merkle_root_token0".to_string(),
        WitnessValue::Scalar(felt_to_decimal(root_token0)),
    );
    values.insert(
        "merkle_root_token1".to_string(),
        WitnessValue::Scalar(felt_to_decimal(root_token1)),
    );
    values.insert(
        "merkle_root_position".to_string(),
        WitnessValue::Scalar(felt_to_decimal(root_position)),
    );
    values.insert(
        "nullifier_position".to_string(),
        WitnessValue::Scalar(felt_to_decimal(nullifier_position)),
    );
    values.insert(
        "sqrt_price_start".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&sqrt_price_start))),
    );
    values.insert("tick_start".to_string(), WitnessValue::I32(tick_start));
    values.insert("tick_lower".to_string(), WitnessValue::I32(tick_lower));
    values.insert("tick_upper".to_string(), WitnessValue::I32(tick_upper));
    values.insert(
        "sqrt_ratio_lower".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&sqrt_ratio_lower))),
    );
    values.insert(
        "sqrt_ratio_upper".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&sqrt_ratio_upper))),
    );
    values.insert("liquidity_before".to_string(), WitnessValue::U128(liquidity_before));
    values.insert(
        "liquidity_delta".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&liquidity_delta_value))),
    );
    values.insert("fee".to_string(), WitnessValue::U128(pool_config.fee));
    values.insert(
        "fee_growth_global_0_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_global_0_before))),
    );
    values.insert(
        "fee_growth_global_1_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_global_1_before))),
    );
    values.insert(
        "fee_growth_global_0".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_global_0_before))),
    );
    values.insert(
        "fee_growth_global_1".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_global_1_before))),
    );
    values.insert(
        "prev_position_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(prev_position_commitment)),
    );
    values.insert(
        "new_position_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(new_position_commitment)),
    );
    values.insert(
        "liquidity_commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(liquidity_commitment)),
    );
    values.insert(
        "fee_growth_inside_0_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_inside_0_before))),
    );
    values.insert(
        "fee_growth_inside_1_before".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_inside_1_before))),
    );
    values.insert(
        "fee_growth_inside_0_after".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_inside_0_after))),
    );
    values.insert(
        "fee_growth_inside_1_after".to_string(),
        WitnessValue::Scalar(big_to_decimal(&u256_to_big(&fee_growth_inside_1_after))),
    );
    values.insert(
        "input_commitment_token0".to_string(),
        WitnessValue::Scalar(felt_to_decimal(token0_commitment)),
    );
    values.insert(
        "input_commitment_token1".to_string(),
        WitnessValue::Scalar(felt_to_decimal(token1_commitment)),
    );
    values.insert(
        "nullifier_token0".to_string(),
        WitnessValue::Scalar(felt_to_decimal(token0_nullifier)),
    );
    values.insert(
        "nullifier_token1".to_string(),
        WitnessValue::Scalar(felt_to_decimal(token1_nullifier)),
    );
    values.insert(
        "output_commitment_token0".to_string(),
        WitnessValue::Scalar(felt_to_decimal(output_commitment_token0)),
    );
    values.insert(
        "output_commitment_token1".to_string(),
        WitnessValue::Scalar(felt_to_decimal(output_commitment_token1)),
    );
    values.insert("protocol_fee_0".to_string(), WitnessValue::U128(protocol_fee_0));
    values.insert("protocol_fee_1".to_string(), WitnessValue::U128(protocol_fee_1));
    values.insert("token0_note_count".to_string(), WitnessValue::U128(token0_count));
    values.insert("token1_note_count".to_string(), WitnessValue::U128(token1_count));
    values.insert(
        "nullifier_token0_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&token0_nullifier_extra)),
    );
    values.insert(
        "nullifier_token1_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&token1_nullifier_extra)),
    );
    values.insert(
        "input_commitment_token0_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&token0_commitment_extra)),
    );
    values.insert(
        "input_commitment_token1_extra".to_string(),
        WitnessValue::Raw(felt_array_to_json(&token1_commitment_extra)),
    );

    values.insert("token0_note_amount".to_string(), WitnessValue::VecU128(token0_amounts));
    values.insert("token0_note_secret".to_string(), WitnessValue::VecBytes32(token0_secrets));
    values.insert(
        "token0_note_nullifier_seed".to_string(),
        WitnessValue::VecBytes32(token0_nullifier_seeds),
    );
    values.insert("token1_note_amount".to_string(), WitnessValue::VecU128(token1_amounts));
    values.insert("token1_note_secret".to_string(), WitnessValue::VecBytes32(token1_secrets));
    values.insert(
        "token1_note_nullifier_seed".to_string(),
        WitnessValue::VecBytes32(token1_nullifier_seeds),
    );
    values.insert("position_liquidity".to_string(), WitnessValue::U128(position_liquidity));
    let (position_secret_in, position_nullifier_seed_in) =
        match (position_secret_in, position_nullifier_seed_in) {
            (Some(secret), Some(nullifier)) => (secret, nullifier),
            _ => {
                let dummy = generate_position_note(
                    tick_lower,
                    tick_upper,
                    position_liquidity,
                    fee_growth_inside_0_before,
                    fee_growth_inside_1_before,
                )?;
                (dummy.secret, dummy.nullifier)
            }
        };
    values.insert(
        "position_secret_in".to_string(),
        WitnessValue::Bytes32(position_secret_in),
    );
    values.insert(
        "position_nullifier_seed_in".to_string(),
        WitnessValue::Bytes32(position_nullifier_seed_in),
    );
    values.insert(
        "position_secret_out".to_string(),
        WitnessValue::Bytes32(position_secret_out),
    );
    values.insert(
        "position_nullifier_seed_out".to_string(),
        WitnessValue::Bytes32(position_nullifier_seed_out),
    );
    values.insert(
        "out_token0_secret".to_string(),
        WitnessValue::Bytes32(out_token0_secret.unwrap_or(pad_token0_note.secret)),
    );
    values.insert(
        "out_token0_nullifier_seed".to_string(),
        WitnessValue::Bytes32(out_token0_nullifier_seed.unwrap_or(pad_token0_note.nullifier)),
    );
    values.insert(
        "out_token1_secret".to_string(),
        WitnessValue::Bytes32(out_token1_secret.unwrap_or(pad_token1_note.secret)),
    );
    values.insert(
        "out_token1_nullifier_seed".to_string(),
        WitnessValue::Bytes32(out_token1_nullifier_seed.unwrap_or(pad_token1_note.nullifier)),
    );
    values.insert("tick_spacing".to_string(), WitnessValue::U128(pool_config.tick_spacing));
    values.insert(
        "amount0_below_div_q".to_string(),
        WitnessValue::MatrixU128(amount0_below_div_q),
    );
    values.insert(
        "amount0_inside_div_q".to_string(),
        WitnessValue::MatrixU128(amount0_inside_div_q),
    );
    values.insert(
        "tick_lower_inv_div_q".to_string(),
        WitnessValue::VecU128(tick_inv_div_q(&sqrt_ratio_lower, tick_lower)?),
    );
    values.insert(
        "tick_upper_inv_div_q".to_string(),
        WitnessValue::VecU128(tick_inv_div_q(&sqrt_ratio_upper, tick_upper)?),
    );

    Ok(LpWitnessInputs { values })
}

fn build_note_public_inputs(
    notes: &[Note],
    token_id: u8,
    max_notes: usize,
) -> Result<(Felt, Felt, u128, Vec<Felt>, Vec<Felt>), ClientError> {
    if notes.len() > max_notes {
        return Err(ClientError::InvalidInput("too many notes".to_string()));
    }
    let mut commitments = Vec::with_capacity(notes.len());
    let mut nullifiers = Vec::with_capacity(notes.len());
    for note in notes {
        commitments.push(compute_commitment(note, token_id)?);
        nullifiers.push(generate_nullifier_hash(note, token_id)?);
    }
    let commitment_in = commitments.first().copied().unwrap_or(Felt::ZERO);
    let nullifier_in = nullifiers.first().copied().unwrap_or(Felt::ZERO);
    let mut commitment_extra = Vec::with_capacity(max_notes - 1);
    let mut nullifier_extra = Vec::with_capacity(max_notes - 1);
    for idx in 1..max_notes {
        if idx < commitments.len() {
            commitment_extra.push(commitments[idx]);
            nullifier_extra.push(nullifiers[idx]);
        } else {
            commitment_extra.push(Felt::ZERO);
            nullifier_extra.push(Felt::ZERO);
        }
    }
    Ok((
        commitment_in,
        nullifier_in,
        commitments.len() as u128,
        commitment_extra,
        nullifier_extra,
    ))
}

const PAD_NOTE_AMOUNT: u128 = 0;

fn pad_note_amounts(notes: &[Note], max_notes: usize) -> Vec<u128> {
    let mut amounts = Vec::with_capacity(max_notes);
    for note in notes {
        amounts.push(note.amount);
    }
    while amounts.len() < max_notes {
        amounts.push(PAD_NOTE_AMOUNT);
    }
    amounts
}

fn pad_note_bytes(values: &[[u8; 32]], max_notes: usize, pad_value: [u8; 32]) -> Vec<[u8; 32]> {
    let mut out = Vec::with_capacity(max_notes);
    for value in values {
        out.push(*value);
    }
    while out.len() < max_notes {
        out.push(pad_value);
    }
    out
}

fn compute_swap_divs_exact_in(
    sqrt_price_start: BigUint,
    sqrt_price_limit: BigUint,
    liquidity: u128,
    amount_remaining: u128,
    fee: u128,
    zero_for_one: bool,
) -> Result<(Vec<u128>, Vec<Vec<u128>>, Vec<Vec<u128>>, Vec<Vec<u128>>, Vec<u128>, Vec<u128>, Vec<u128>), ClientError> {
    let fee_amount = compute_fee(amount_remaining, fee);
    let price_impact = amount_remaining
        .checked_sub(fee_amount)
        .ok_or_else(|| ClientError::InvalidInput("fee exceeds amount".to_string()))?;

    let (next0, next0_floor, next0_ceil) =
        next_sqrt_ratio_from_amount0(&sqrt_price_start, liquidity, price_impact)?;
    let (next1, next1_floor) =
        next_sqrt_ratio_from_amount1(&sqrt_price_start, liquidity, price_impact)?;
    let next_from_amount = if zero_for_one { next0 } else { next1 };

    let amt0_limit = amount0_delta_with_q(&sqrt_price_limit, &sqrt_price_start, liquidity, true)?;
    let amt0_calc = amount0_delta_with_q(&sqrt_price_limit, &sqrt_price_start, liquidity, false)?;
    let amt1_limit = amount1_delta(&sqrt_price_limit, &sqrt_price_start, liquidity, false)?;
    let amt1_calc = amount1_delta(&sqrt_price_limit, &sqrt_price_start, liquidity, true)?;
    let specified_amount_delta = if zero_for_one { amt0_limit.amount } else { amt1_calc };
    let _calculated_amount_delta = if zero_for_one { amt1_limit } else { amt0_calc.amount };

    let (before_fee_q, _before_fee) = amount_before_fee_div_q(specified_amount_delta, fee)?;
    let amt0_out = amount0_delta_with_q(&next_from_amount, &sqrt_price_start, liquidity, false)?;

    Ok((
        before_fee_q,
        amt0_limit.div_q,
        amt0_calc.div_q,
        amt0_out.div_q,
        next0_floor,
        next0_ceil,
        next1_floor,
    ))
}

fn compute_swap_divs_exact_out(
    sqrt_price_start: BigUint,
    sqrt_price_limit: BigUint,
    liquidity: u128,
    amount_remaining: u128,
    fee: u128,
    zero_for_one: bool,
) -> Result<(Vec<u128>, Vec<Vec<u128>>, Vec<Vec<u128>>, Vec<Vec<u128>>, Vec<u128>, Vec<u128>), ClientError> {
    let (next0, next0_ceil) =
        next_sqrt_ratio_from_amount0_exact_out(&sqrt_price_start, liquidity, amount_remaining)?;
    let (next1, next1_floor) =
        next_sqrt_ratio_from_amount1_exact_out(&sqrt_price_start, liquidity, amount_remaining)?;
    let next_from_amount = if zero_for_one { next0 } else { next1 };

    let amt0_limit = amount0_delta_with_q(&sqrt_price_limit, &sqrt_price_start, liquidity, true)?;
    let amt0_calc = amount0_delta_with_q(&sqrt_price_limit, &sqrt_price_start, liquidity, false)?;
    let amt1_limit = amount1_delta(&sqrt_price_limit, &sqrt_price_start, liquidity, false)?;
    let amt1_calc = amount1_delta(&sqrt_price_limit, &sqrt_price_start, liquidity, true)?;
    let _specified_amount_delta = if zero_for_one { amt1_limit } else { amt0_limit.amount };
    let calculated_amount_delta = if zero_for_one { amt0_calc.amount } else { amt1_calc };

    let limited = if zero_for_one {
        next_from_amount < sqrt_price_limit
    } else {
        next_from_amount > sqrt_price_limit
    };

    let amt0_in = amount0_delta_with_q(&next_from_amount, &sqrt_price_start, liquidity, true)?;
    let amt1_in = amount1_delta(&next_from_amount, &sqrt_price_start, liquidity, true)?;
    let nl_amount_in_wo_fee = if zero_for_one { amt0_in.amount } else { amt1_in };
    let calc_amount_for_fee = if limited {
        calculated_amount_delta
    } else {
        nl_amount_in_wo_fee
    };

    let (before_fee_q, _before_fee) = amount_before_fee_div_q(calc_amount_for_fee, fee)?;
    Ok((
        before_fee_q,
        amt0_limit.div_q,
        amt0_calc.div_q,
        amt0_in.div_q,
        next0_ceil,
        next1_floor,
    ))
}

fn compute_fee(amount: u128, fee: u128) -> u128 {
    let product = BigUint::from(amount) * BigUint::from(fee);
    let high = (&product >> 128u32).to_u128().unwrap_or(0);
    let low_mask = BigUint::from(U128_MAX);
    let low = &product & &low_mask;
    if low.is_zero() {
        high
    } else {
        high.saturating_add(1)
    }
}

fn compute_fee_div_q(fee_amount: u128, liquidity: u128) -> Result<Vec<u128>, ClientError> {
    let numerator = BigUint::from(fee_amount) << 128u32;
    let safe_liq = if liquidity == 0 { 1u128 } else { liquidity };
    let q = numerator / BigUint::from(safe_liq);
    big_to_limbs(&q)
}

fn amount_before_fee_div_q(after_fee: u128, fee: u128) -> Result<(Vec<u128>, u128), ClientError> {
    let numerator = BigUint::from(after_fee) << 128u32;
    let denom = (BigUint::one() << 128u32) - BigUint::from(fee);
    let q = &numerator / &denom;
    let rem = &numerator - (&q * &denom);
    let before_fee = if rem.is_zero() {
        q.clone()
    } else {
        q.clone() + BigUint::one()
    };
    let before_fee_u128 = before_fee
        .to_u128()
        .ok_or_else(|| ClientError::InvalidInput("before_fee overflow".to_string()))?;
    Ok((big_to_limbs(&q)?, before_fee_u128))
}

struct Amount0DeltaResult {
    amount: u128,
    div_q: Vec<Vec<u128>>,
}

fn amount0_delta_with_q(
    sqrt_a: &BigUint,
    sqrt_b: &BigUint,
    liquidity: u128,
    round_up: bool,
) -> Result<Amount0DeltaResult, ClientError> {
    let (lower, upper) = if sqrt_a < sqrt_b {
        (sqrt_a.clone(), sqrt_b.clone())
    } else {
        (sqrt_b.clone(), sqrt_a.clone())
    };
    if lower.is_zero() {
        return Err(ClientError::InvalidInput(format!(
            "sqrt ratio is zero (a={}, b={})",
            sqrt_a, sqrt_b
        )));
    }
    let delta = &upper - &lower;
    let numerator1 = BigUint::from(liquidity) << 128u32;
    let mul = &numerator1 * &delta;
    let q_floor = &mul / &upper;
    let q_ceil = div_ceil(&mul, &upper);
    let mid = if round_up { q_ceil.clone() } else { q_floor.clone() };
    let q2_floor = &mid / &lower;
    let q2_ceil = div_ceil(&mid, &lower);
    let amount = if round_up { q2_ceil.clone() } else { q2_floor.clone() };
    let amount_u128 = amount
        .to_u128()
        .ok_or_else(|| ClientError::InvalidInput("amount0 overflow".to_string()))?;
    Ok(Amount0DeltaResult {
        amount: amount_u128,
        div_q: vec![
            big_to_limbs(&q_floor)?,
            big_to_limbs(&q_ceil)?,
            big_to_limbs(&q2_floor)?,
            big_to_limbs(&q2_ceil)?,
        ],
    })
}

fn amount1_delta(
    sqrt_a: &BigUint,
    sqrt_b: &BigUint,
    liquidity: u128,
    round_up: bool,
) -> Result<u128, ClientError> {
    let (lower, upper) = if sqrt_a < sqrt_b {
        (sqrt_a.clone(), sqrt_b.clone())
    } else {
        (sqrt_b.clone(), sqrt_a.clone())
    };
    let delta = &upper - &lower;
    let product = delta * BigUint::from(liquidity);
    let high = &product >> 128u32;
    let low_mask = BigUint::from(U128_MAX);
    let low = &product & &low_mask;
    let mut amount = high;
    if round_up && !low.is_zero() {
        amount += BigUint::one();
    }
    amount
        .to_u128()
        .ok_or_else(|| ClientError::InvalidInput("amount1 overflow".to_string()))
}

fn next_sqrt_ratio_from_amount0(
    sqrt_ratio: &BigUint,
    liquidity: u128,
    amount: u128,
) -> Result<(BigUint, Vec<u128>, Vec<u128>), ClientError> {
    let numerator1 = BigUint::from(liquidity) << 128u32;
    let denom_p1 = &numerator1 / sqrt_ratio;
    let denom_add = &denom_p1 + BigUint::from(amount);
    let denom_add2 = &denom_add + if amount == 0 { BigUint::one() } else { BigUint::zero() };
    let q_ceil = div_ceil(&numerator1, &denom_add2);
    let next_ratio = if amount == 0 { sqrt_ratio.clone() } else { q_ceil.clone() };
    Ok((next_ratio, big_to_limbs(&denom_p1)?, big_to_limbs(&q_ceil)?))
}

fn next_sqrt_ratio_from_amount1(
    sqrt_ratio: &BigUint,
    liquidity: u128,
    amount: u128,
) -> Result<(BigUint, Vec<u128>), ClientError> {
    let numerator = BigUint::from(amount) << 128u32;
    let safe_liq = if liquidity == 0 { 1u128 } else { liquidity };
    let q_floor = &numerator / BigUint::from(safe_liq);
    let next_ratio = if amount == 0 {
        sqrt_ratio.clone()
    } else {
        sqrt_ratio + &q_floor
    };
    Ok((next_ratio, big_to_limbs(&q_floor)?))
}

fn next_sqrt_ratio_from_amount0_exact_out(
    sqrt_ratio: &BigUint,
    liquidity: u128,
    amount: u128,
) -> Result<(BigUint, Vec<u128>), ClientError> {
    let numerator1 = BigUint::from(liquidity) << 128u32;
    let prod = BigUint::from(amount) * sqrt_ratio;
    if prod >= numerator1 {
        return Err(ClientError::InvalidInput("exact out overflow".to_string()));
    }
    let denom = &numerator1 - &prod;
    let numerator_mul = &numerator1 * sqrt_ratio;
    let q_ceil = div_ceil(&numerator_mul, &denom);
    let next_ratio = if amount == 0 { sqrt_ratio.clone() } else { q_ceil.clone() };
    Ok((next_ratio, big_to_limbs(&q_ceil)?))
}

fn next_sqrt_ratio_from_amount1_exact_out(
    sqrt_ratio: &BigUint,
    liquidity: u128,
    amount: u128,
) -> Result<(BigUint, Vec<u128>), ClientError> {
    let numerator = BigUint::from(amount) << 128u32;
    let safe_liq = if liquidity == 0 { 1u128 } else { liquidity };
    let q_floor = &numerator / BigUint::from(safe_liq);
    let next_ratio = if amount == 0 {
        sqrt_ratio.clone()
    } else {
        sqrt_ratio - &q_floor
    };
    Ok((next_ratio, big_to_limbs(&q_floor)?))
}

fn compute_liquidity_amounts(
    sqrt_price_start: U256,
    sqrt_ratio_lower: U256,
    sqrt_ratio_upper: U256,
    liquidity: u128,
    round_up: bool,
) -> Result<(u128, u128, Vec<Vec<u128>>, Vec<Vec<u128>>), ClientError> {
    let sqrt_price = u256_to_big(&sqrt_price_start);
    let sqrt_lower = u256_to_big(&sqrt_ratio_lower);
    let sqrt_upper = u256_to_big(&sqrt_ratio_upper);

    let amt0_below = amount0_delta_with_q(&sqrt_lower, &sqrt_upper, liquidity, round_up)?;
    let amt0_inside = amount0_delta_with_q(&sqrt_price, &sqrt_upper, liquidity, round_up)?;
    let amt1_inside = amount1_delta(&sqrt_lower, &sqrt_price, liquidity, round_up)?;
    let amt1_above = amount1_delta(&sqrt_lower, &sqrt_upper, liquidity, round_up)?;

    let (amount0, amount1) = if sqrt_price <= sqrt_lower {
        (amt0_below.amount, 0)
    } else if sqrt_price < sqrt_upper {
        (amt0_inside.amount, amt1_inside)
    } else {
        (0, amt1_above)
    };

    Ok((amount0, amount1, amt0_below.div_q, amt0_inside.div_q))
}

pub fn quote_liquidity_amounts(
    sqrt_price_start: U256,
    sqrt_ratio_lower: U256,
    sqrt_ratio_upper: U256,
    liquidity: u128,
    round_up: bool,
) -> Result<(u128, u128), ClientError> {
    let (amount0, amount1, _div_q_below, _div_q_inside) = compute_liquidity_amounts(
        sqrt_price_start,
        sqrt_ratio_lower,
        sqrt_ratio_upper,
        liquidity,
        round_up,
    )?;
    Ok((amount0, amount1))
}

fn compute_fee_amounts(
    position_liquidity: u128,
    fee_growth_inside_0_before: U256,
    fee_growth_inside_1_before: U256,
    fee_growth_inside_0_after: U256,
    fee_growth_inside_1_after: U256,
) -> Result<(u128, u128), ClientError> {
    let diff0 = u256_to_big(&fee_growth_inside_0_after)
        .checked_sub(&u256_to_big(&fee_growth_inside_0_before))
        .ok_or_else(|| ClientError::InvalidInput("fee growth decreased".to_string()))?;
    let diff1 = u256_to_big(&fee_growth_inside_1_after)
        .checked_sub(&u256_to_big(&fee_growth_inside_1_before))
        .ok_or_else(|| ClientError::InvalidInput("fee growth decreased".to_string()))?;
    let fee0 = (diff0 * BigUint::from(position_liquidity)) >> 128u32;
    let fee1 = (diff1 * BigUint::from(position_liquidity)) >> 128u32;
    let fee0_u128 = fee0
        .to_u128()
        .ok_or_else(|| ClientError::InvalidInput("fee0 overflow".to_string()))?;
    let fee1_u128 = fee1
        .to_u128()
        .ok_or_else(|| ClientError::InvalidInput("fee1 overflow".to_string()))?;
    Ok((fee0_u128, fee1_u128))
}

fn encode_signed_u256(value: i128) -> Result<U256, ClientError> {
    if value >= 0 {
        Ok(U256::from_words(value as u128, 0))
    } else {
        let mag = (-value) as u128;
        let twos = (!mag).wrapping_add(1);
        Ok(U256::from_words(twos, 0))
    }
}

fn decode_signed_u256(value: U256) -> Result<(bool, u128), ClientError> {
    let high = value.high();
    let low = value.low();
    if high != 0 {
        return Err(ClientError::InvalidInput("invalid signed u256".to_string()));
    }
    if low < (1u128 << 127) {
        Ok((false, low))
    } else {
        let mag = (!low).wrapping_add(1);
        Ok((true, mag))
    }
}

fn u256_to_big(value: &U256) -> BigUint {
    let mut out = BigUint::from(value.high());
    out <<= 128u32;
    out + BigUint::from(value.low())
}

fn big_to_decimal(value: &BigUint) -> String {
    value.to_str_radix(10)
}

fn felt_to_decimal(value: Felt) -> String {
    BigUint::from_bytes_be(&value.to_bytes_be()).to_str_radix(10)
}

fn u256_array_to_json(values: &[U256]) -> Value {
    Value::Array(values.iter().map(|value| Value::String(big_to_decimal(&u256_to_big(value)))).collect())
}

fn felt_array_to_json(values: &[Felt]) -> Value {
    Value::Array(values.iter().map(|value| Value::String(felt_to_decimal(*value))).collect())
}

fn big_to_limbs(value: &BigUint) -> Result<Vec<u128>, ClientError> {
    let mut limbs = Vec::with_capacity(4);
    let mask = BigUint::from(u64::MAX);
    let mut tmp = value.clone();
    for _ in 0..4 {
        let limb = (&tmp & &mask)
            .to_u64()
            .ok_or_else(|| ClientError::InvalidInput("limb overflow".to_string()))?;
        limbs.push(limb as u128);
        tmp >>= 64u32;
    }
    if !tmp.is_zero() {
        return Err(ClientError::InvalidInput("u256 overflow".to_string()));
    }
    Ok(limbs)
}

fn div_ceil(numer: &BigUint, denom: &BigUint) -> BigUint {
    if denom.is_zero() {
        return BigUint::zero();
    }
    let mut q = numer / denom;
    let rem = numer - (&q * denom);
    if rem.is_zero() {
        q
    } else {
        q += BigUint::one();
        q
    }
}

fn tick_inv_div_q(sqrt_ratio: &U256, tick: i32) -> Result<Vec<u128>, ClientError> {
    let sqrt_big = u256_to_big(sqrt_ratio);
    if tick > 0 {
        big_to_limbs(&sqrt_big)
    } else {
        let max = (BigUint::one() << 256u32) - BigUint::one();
        let q = max / sqrt_big;
        big_to_limbs(&q)
    }
}

fn empty_div_matrix() -> Vec<Vec<u128>> {
    vec![vec![0u128; 4]; 4]
}

async fn fetch_tick_sqrt_ratios<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    tick_lower: i32,
    tick_upper: i32,
) -> Result<(U256, U256), ClientError> {
    let lower = fetch_sqrt_ratio_at_tick(swap_client, tick_lower).await?;
    let upper = fetch_sqrt_ratio_at_tick(swap_client, tick_upper).await?;
    Ok((lower, upper))
}

async fn fetch_sqrt_ratio_at_tick<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    tick: i32,
) -> Result<U256, ClientError> {
    let selector = get_selector_from_name("get_sqrt_ratio_at_tick")
        .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
    let calldata = vec![i32_to_felt(tick)?];
    let call = FunctionCall {
        contract_address: swap_client.pool_address,
        entry_point_selector: selector,
        calldata,
    };
    let provider = swap_client.account.provider();
    let result = with_retry(swap_client.retry.clone(), || async {
        provider
            .call(call.clone(), BlockId::Tag(BlockTag::Latest))
            .await
            .map_err(|err| ClientError::Rpc(err.to_string()))
    })
    .await?;
    if result.len() < 2 {
        return Err(ClientError::Rpc("invalid sqrt ratio".to_string()));
    }
    Ok(U256::from_words(
        felt_to_u128(&result[0])?,
        felt_to_u128(&result[1])?,
    ))
}

async fn fetch_fee_growth_inside<A: ConnectedAccount + Sync>(
    swap_client: &SwapClient<A>,
    tick_lower: i32,
    tick_upper: i32,
) -> Result<(U256, U256), ClientError> {
    let selector = get_selector_from_name("get_fee_growth_inside")
        .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
    let calldata = vec![i32_to_felt(tick_lower)?, i32_to_felt(tick_upper)?];
    let call = FunctionCall {
        contract_address: swap_client.pool_address,
        entry_point_selector: selector,
        calldata,
    };
    let provider = swap_client.account.provider();
    let result = with_retry(swap_client.retry.clone(), || async {
        provider
            .call(call.clone(), BlockId::Tag(BlockTag::Latest))
            .await
            .map_err(|err| ClientError::Rpc(err.to_string()))
    })
    .await?;
    if result.len() < 4 {
        return Err(ClientError::Rpc("invalid fee growth response".to_string()));
    }
    let fee0 = U256::from_words(felt_to_u128(&result[0])?, felt_to_u128(&result[1])?);
    let fee1 = U256::from_words(felt_to_u128(&result[2])?, felt_to_u128(&result[3])?);
    Ok((fee0, fee1))
}

fn default_circuit_dir(circuit: &str) -> PathBuf {
    PathBuf::from("artifacts").join(circuit)
}

fn parse_hex_felt(value: &str) -> Result<Felt, ClientError> {
    if value.starts_with("0x") {
        Felt::from_hex(value).map_err(|_| ClientError::Asp("invalid felt".to_string()))
    } else {
        Felt::from_dec_str(value).map_err(|_| ClientError::Asp("invalid felt".to_string()))
    }
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

#[derive(Debug, serde::Deserialize)]
struct RootAtResponse {
    token: String,
    root: String,
}

#[cfg(test)]
mod vector_gen {
    use super::*;
    use rand::rngs::StdRng;
    use rand::{RngCore, SeedableRng};
    use serde::Deserialize;
    use serde_json::Value;
    use starknet::accounts::{ExecutionEncoding, SingleOwnerAccount};
    use starknet::core::types::{BlockId, BlockTag, Felt, FunctionCall, U256};
    use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
    use starknet::providers::Provider;
    use starknet::signers::{LocalWallet, SigningKey};
    use std::env;
    use std::error::Error;
    use std::fs;
    use std::path::{Path, PathBuf};
    use std::sync::Arc;
    use url::Url;
    use zylith_prover::{generate_lp_add_witness_inputs, generate_lp_remove_witness_inputs, generate_swap_witness_inputs};

    use crate::client::PoolState;
    use crate::utils::{felt_to_i32, parse_felt};

    type Account = SingleOwnerAccount<JsonRpcClient<HttpTransport>, LocalWallet>;

    #[derive(Deserialize)]
    struct DevnetAddresses {
        pool: String,
    }

    #[tokio::test(flavor = "multi_thread")]
    #[ignore]
    async fn generate_circuit_vectors() -> Result<(), Box<dyn Error>> {
        let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:5050".to_string());
        let account_address = required_felt("ACCOUNT_ADDRESS")?;
        let private_key = required_felt("PRIVATE_KEY")?;
        let repo_root = repo_root();
        let addrs = load_addresses(repo_root.join("artifacts/devnet_addresses.json"))?;
        let pool_address = parse_felt(&addrs.pool)?;

        let provider = JsonRpcClient::new(HttpTransport::new(Url::parse(&rpc_url)?));
        let chain_id = provider.chain_id().await?;
        let signer = SigningKey::from_secret_scalar(private_key);
        let mut account = SingleOwnerAccount::new(
            provider,
            LocalWallet::from(signer),
            account_address,
            chain_id,
            ExecutionEncoding::New,
        );
        account.set_block_id(BlockId::Tag(BlockTag::Latest));
        let account = Arc::new(account);

        let swap_client = SwapClient::new(account.clone(), pool_address, "");
        let pool_config = swap_client.get_pool_config().await?;
        let pool_state = fetch_pool_state(&swap_client).await?;
        if pool_state.sqrt_price == U256::from(0u128) {
            return Err("pool sqrt_price is zero; run deploy_devnet.sh (initialize) before generating vectors".into());
        }
        if pool_state.liquidity == 0 {
            return Err(format!(
                "pool liquidity is zero; add liquidity before generating vectors (tick={}, sqrt_price={})",
                pool_state.tick, pool_state.sqrt_price
            )
            .into());
        }

        let mut rng = StdRng::seed_from_u64(0x5a17b0);
        let vectors_root = repo_root.join("circuits/test/vectors");

        let (single_swap, multi_swap) = build_swap_vectors(
            &swap_client,
            &pool_config,
            &mut rng,
            5_000,
            2,
        )
        .await?;
        write_vector(
            vectors_root.join("private_swap/single_step_swap.json"),
            single_swap.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap/multi_step_swap.json"),
            multi_swap.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap/tick_crossing.json"),
            multi_swap.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap/price_transition_correct.json"),
            multi_swap.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap/output_commitment_computed.json"),
            multi_swap.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap/ten_tick_crossings_max.json"),
            multi_swap.clone(),
            false,
        )?;
        let insufficient = mutate_swap_insufficient_balance(&single_swap)?;
        write_vector(
            vectors_root.join("private_swap/insufficient_balance_fails.json"),
            insufficient,
            true,
        )?;

        let (single_exact_out, multi_exact_out) = build_swap_exact_out_vectors(
            &swap_client,
            &pool_config,
            &mut rng,
            2_000,
            2,
        )
        .await?;
        write_vector(
            vectors_root.join("private_swap_exact_out/single_step_swap_exact_out.json"),
            single_exact_out.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_swap_exact_out/multi_step_swap_exact_out.json"),
            multi_exact_out.clone(),
            false,
        )?;

        let (liq_add, liq_remove, liq_claim) = build_liquidity_vectors(
            &swap_client,
            &pool_config,
            &pool_state,
            &mut rng,
        )
        .await?;
        write_vector(
            vectors_root.join("private_liquidity/add_liquidity_in_range.json"),
            liq_add.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_liquidity/remove_liquidity_with_fees.json"),
            liq_remove.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_liquidity/fee_calculation_matches_ekubo.json"),
            liq_remove.clone(),
            false,
        )?;
        write_vector(
            vectors_root.join("private_liquidity/claim_liquidity_fees.json"),
            liq_claim.clone(),
            false,
        )?;
        let out_of_range = mutate_liquidity_out_of_range(&liq_add)?;
        write_vector(
            vectors_root.join("private_liquidity/add_liquidity_out_of_range.json"),
            out_of_range,
            true,
        )?;

        Ok(())
    }

    async fn build_swap_vectors(
        swap_client: &SwapClient<Arc<Account>>,
        pool_config: &PoolConfig,
        rng: &mut StdRng,
        base_amount: u128,
        min_steps: usize,
    ) -> Result<(Value, Value), Box<dyn Error>> {
        let single = build_swap_exact_in_vector(
            swap_client,
            pool_config,
            rng,
            base_amount,
            1,
        )
        .await?;
        let multi = build_swap_exact_in_vector(
            swap_client,
            pool_config,
            rng,
            base_amount.saturating_mul(10),
            min_steps,
        )
        .await?;
        Ok((single, multi))
    }

    async fn build_swap_exact_out_vectors(
        swap_client: &SwapClient<Arc<Account>>,
        pool_config: &PoolConfig,
        rng: &mut StdRng,
        base_amount: u128,
        min_steps: usize,
    ) -> Result<(Value, Value), Box<dyn Error>> {
        let single = build_swap_exact_out_vector(
            swap_client,
            pool_config,
            rng,
            base_amount,
            1,
        )
        .await?;
        let multi = build_swap_exact_out_vector(
            swap_client,
            pool_config,
            rng,
            base_amount.saturating_mul(10),
            min_steps,
        )
        .await?;
        Ok((single, multi))
    }

    async fn build_swap_exact_in_vector(
        swap_client: &SwapClient<Arc<Account>>,
        pool_config: &PoolConfig,
        rng: &mut StdRng,
        amount_in: u128,
        min_steps: usize,
    ) -> Result<Value, Box<dyn Error>> {
        let zero_for_one = true;
        let input_token = pool_config.token0;
        let notes = split_notes(rng, amount_in, input_token, 0)?;
        let sqrt_ratio_limit = default_sqrt_ratio_limit(pool_config, zero_for_one);
        let quote = quote_with_min_steps(
            swap_client,
            sqrt_ratio_limit,
            SignedAmount { mag: amount_in, sign: false },
            !zero_for_one,
            min_steps,
        )
        .await?;
        let step_liquidity = compute_step_liquidity(swap_client, &quote, zero_for_one).await?;
        let (_in_steps, _out_steps, amount_out_total, amount_in_consumed) =
            summarize_swap_amounts(&quote.steps)?;
        let change_amount = amount_in
            .checked_sub(amount_in_consumed)
            .ok_or("amount_in underflow")?;
        let output_note = build_output_note_for_amount(
            rng,
            amount_out_total,
            pool_config.token1,
            1,
        )?;
        let change_note = build_output_note_for_amount(rng, change_amount, input_token, 0)?;
        let output_commitment = output_note
            .as_ref()
            .map(|note| compute_commitment(note, 1))
            .transpose()?
            .unwrap_or(Felt::ZERO);
        let change_commitment = change_note
            .as_ref()
            .map(|note| compute_commitment(note, 0))
            .transpose()?
            .unwrap_or(Felt::ZERO);

        let request = SwapProveRequest {
            notes: notes.clone(),
            zero_for_one,
            exact_out: false,
            amount_out: None,
            sqrt_ratio_limit: Some(sqrt_ratio_limit),
            output_note,
            change_note,
            circuit_dir: None,
        };
        let witness = build_swap_witness_exact_in(
            &request,
            &request.output_note,
            &request.change_note,
            pool_config,
            &quote,
            &step_liquidity,
            &Felt::ONE,
            output_commitment,
            change_commitment,
        )?;
        Ok(wrap_input(generate_swap_witness_inputs(witness)?))
    }

    async fn build_swap_exact_out_vector(
        swap_client: &SwapClient<Arc<Account>>,
        pool_config: &PoolConfig,
        rng: &mut StdRng,
        amount_out: u128,
        min_steps: usize,
    ) -> Result<Value, Box<dyn Error>> {
        let zero_for_one = true;
        let sqrt_ratio_limit = default_sqrt_ratio_limit(pool_config, zero_for_one);
        let quote = quote_with_min_steps(
            swap_client,
            sqrt_ratio_limit,
            SignedAmount { mag: amount_out, sign: true },
            zero_for_one,
            min_steps,
        )
        .await?;
        let step_liquidity = compute_step_liquidity(swap_client, &quote, zero_for_one).await?;
        let (_in_steps, _out_steps, amount_out_total, amount_in_consumed) =
            summarize_swap_amounts(&quote.steps)?;
        let input_token = pool_config.token0;
        let notes = split_notes(rng, amount_in_consumed, input_token, 0)?;
        let output_note = build_output_note_for_amount(
            rng,
            amount_out_total,
            pool_config.token1,
            1,
        )?;
        let output_commitment = output_note
            .as_ref()
            .map(|note| compute_commitment(note, 1))
            .transpose()?
            .unwrap_or(Felt::ZERO);
        let request = SwapProveRequest {
            notes,
            zero_for_one,
            exact_out: true,
            amount_out: Some(amount_out_total),
            sqrt_ratio_limit: Some(sqrt_ratio_limit),
            output_note,
            change_note: None,
            circuit_dir: None,
        };
        let witness = build_swap_witness_exact_out(
            &request,
            &request.output_note,
            &request.change_note,
            pool_config,
            &quote,
            &step_liquidity,
            &Felt::ONE,
            output_commitment,
            Felt::ZERO,
            amount_out_total,
        )?;
        Ok(wrap_input(generate_swap_witness_inputs(witness)?))
    }

    async fn build_liquidity_vectors(
        swap_client: &SwapClient<Arc<Account>>,
        pool_config: &PoolConfig,
        pool_state: &PoolState,
        rng: &mut StdRng,
    ) -> Result<(Value, Value, Value), Box<dyn Error>> {
        let tick_spacing = pool_config.tick_spacing as i32;
        if tick_spacing == 0 {
            return Err("pool tick spacing is zero; pool not initialized".into());
        }
        if pool_state.sqrt_price == U256::from(0u128) {
            return Err("pool sqrt_price is zero; initialize pool before generating vectors".into());
        }
        let tick_center = align_tick(pool_state.tick, tick_spacing);
        let tick_lower = tick_center - tick_spacing;
        let tick_upper = tick_center + tick_spacing;
        let liquidity_delta = 1_000u128;
        let position_liquidity = 2_000u128;
        let sqrt_ratio_lower = fetch_sqrt_ratio_at_tick(swap_client, tick_lower).await?;
        let sqrt_ratio_upper = fetch_sqrt_ratio_at_tick(swap_client, tick_upper).await?;
        if sqrt_ratio_lower == U256::from(0u128) || sqrt_ratio_upper == U256::from(0u128) {
            return Err("get_sqrt_ratio_at_tick returned zero; pool not initialized".into());
        }
        let fee_growth_inside_before = U256::from(0u128);
        let fee_growth_inside_after = U256::from(u128::MAX);

        let add = build_liquidity_add_vector(
            pool_config,
            pool_state,
            rng,
            tick_lower,
            tick_upper,
            liquidity_delta,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            fee_growth_inside_before,
        )?;

        let remove = build_liquidity_remove_vector(
            pool_config,
            pool_state,
            rng,
            tick_lower,
            tick_upper,
            position_liquidity,
            liquidity_delta,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            fee_growth_inside_before,
            fee_growth_inside_after,
        )?;

        let claim = build_liquidity_claim_vector(
            pool_config,
            pool_state,
            rng,
            tick_lower,
            tick_upper,
            position_liquidity,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            fee_growth_inside_before,
            fee_growth_inside_after,
        )?;

        Ok((add, remove, claim))
    }

    fn build_liquidity_add_vector(
        pool_config: &PoolConfig,
        pool_state: &PoolState,
        rng: &mut StdRng,
        tick_lower: i32,
        tick_upper: i32,
        liquidity_delta: u128,
        sqrt_ratio_lower: U256,
        sqrt_ratio_upper: U256,
        fee_growth_inside: U256,
    ) -> Result<Value, Box<dyn Error>> {
        let (amount0, amount1, amount0_below_div_q, amount0_inside_div_q) =
            compute_liquidity_amounts(
                pool_state.sqrt_price,
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity_delta,
                true,
            )?;
        let token0_notes = build_input_notes(rng, amount0, pool_config.token0, 0)?;
        let token1_notes = build_input_notes(rng, amount1, pool_config.token1, 1)?;
        let input_dummy = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            liquidity_delta,
            fee_growth_inside,
            fee_growth_inside,
        )?;
        let output_position_note = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            liquidity_delta,
            fee_growth_inside,
            fee_growth_inside,
        )?;
        let new_position_commitment = compute_position_commitment(&output_position_note)?;

        let witness = build_liquidity_witness(
            pool_config,
            VK_LIQ_ADD_DEC,
            Felt::ONE,
            Felt::ONE,
            Felt::ONE,
            Felt::ZERO,
            pool_state.sqrt_price,
            pool_state.tick,
            pool_state.liquidity,
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1),
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1),
            tick_lower,
            tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            true,
            liquidity_delta,
            liquidity_delta,
            Felt::ZERO,
            new_position_commitment,
            fee_growth_inside,
            fee_growth_inside,
            fee_growth_inside,
            fee_growth_inside,
            &token0_notes,
            &token1_notes,
            Felt::ZERO,
            Felt::ZERO,
            Some(input_dummy.secret),
            Some(input_dummy.nullifier),
            output_position_note.secret,
            output_position_note.nullifier,
            None,
            None,
            None,
            None,
            0,
            0,
            amount0_below_div_q,
            amount0_inside_div_q,
        )?;
        Ok(wrap_input(generate_lp_add_witness_inputs(witness)?))
    }

    fn build_liquidity_remove_vector(
        pool_config: &PoolConfig,
        pool_state: &PoolState,
        rng: &mut StdRng,
        tick_lower: i32,
        tick_upper: i32,
        position_liquidity: u128,
        liquidity_delta: u128,
        sqrt_ratio_lower: U256,
        sqrt_ratio_upper: U256,
        fee_growth_inside_before: U256,
        fee_growth_inside_after: U256,
    ) -> Result<Value, Box<dyn Error>> {
        let position_note = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            position_liquidity,
            fee_growth_inside_before,
            fee_growth_inside_before,
        )?;
        let position_commitment = compute_position_commitment(&position_note)?;
        let nullifier_position = generate_position_nullifier_hash(&position_note)?;
        let remaining_liquidity = position_liquidity
            .checked_sub(liquidity_delta)
            .ok_or("liquidity underflow")?;
        let output_position_note = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            remaining_liquidity,
            fee_growth_inside_after,
            fee_growth_inside_after,
        )?;
        let new_position_commitment = compute_position_commitment(&output_position_note)?;

        let (amount0, amount1, amount0_below_div_q, amount0_inside_div_q) =
            compute_liquidity_amounts(
                pool_state.sqrt_price,
                sqrt_ratio_lower,
                sqrt_ratio_upper,
                liquidity_delta,
                false,
            )?;
        let (fee_amount0, fee_amount1) = compute_fee_amounts(
            position_liquidity,
            fee_growth_inside_before,
            fee_growth_inside_before,
            fee_growth_inside_after,
            fee_growth_inside_after,
        )?;
        let protocol_fee_0 = compute_fee(amount0, pool_config.fee);
        let protocol_fee_1 = compute_fee(amount1, pool_config.fee);
        let out_amount0 = amount0
            .checked_sub(protocol_fee_0)
            .and_then(|val| val.checked_add(fee_amount0))
            .ok_or("token0 output underflow")?;
        let out_amount1 = amount1
            .checked_sub(protocol_fee_1)
            .and_then(|val| val.checked_add(fee_amount1))
            .ok_or("token1 output underflow")?;
        let out_note0 =
            build_output_note_for_amount(rng, out_amount0, pool_config.token0, 0)?;
        let out_note1 =
            build_output_note_for_amount(rng, out_amount1, pool_config.token1, 1)?;
        let output_commitment_token0 = out_note0
            .as_ref()
            .map(|note| compute_commitment(note, 0))
            .transpose()?
            .unwrap_or(Felt::ZERO);
        let output_commitment_token1 = out_note1
            .as_ref()
            .map(|note| compute_commitment(note, 1))
            .transpose()?
            .unwrap_or(Felt::ZERO);

        let witness = build_liquidity_witness(
            pool_config,
            VK_LIQ_REMOVE_DEC,
            Felt::ONE,
            Felt::ONE,
            Felt::ONE,
            nullifier_position,
            pool_state.sqrt_price,
            pool_state.tick,
            pool_state.liquidity,
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1),
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1),
            tick_lower,
            tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            false,
            position_liquidity,
            liquidity_delta,
            position_commitment,
            new_position_commitment,
            fee_growth_inside_before,
            fee_growth_inside_before,
            fee_growth_inside_after,
            fee_growth_inside_after,
            &[],
            &[],
            output_commitment_token0,
            output_commitment_token1,
            Some(position_note.secret),
            Some(position_note.nullifier),
            output_position_note.secret,
            output_position_note.nullifier,
            out_note0.as_ref().map(|note| note.secret),
            out_note0.as_ref().map(|note| note.nullifier),
            out_note1.as_ref().map(|note| note.secret),
            out_note1.as_ref().map(|note| note.nullifier),
            protocol_fee_0,
            protocol_fee_1,
            amount0_below_div_q,
            amount0_inside_div_q,
        )?;
        Ok(wrap_input(generate_lp_remove_witness_inputs(witness)?))
    }

    fn build_liquidity_claim_vector(
        pool_config: &PoolConfig,
        pool_state: &PoolState,
        rng: &mut StdRng,
        tick_lower: i32,
        tick_upper: i32,
        position_liquidity: u128,
        sqrt_ratio_lower: U256,
        sqrt_ratio_upper: U256,
        fee_growth_inside_before: U256,
        fee_growth_inside_after: U256,
    ) -> Result<Value, Box<dyn Error>> {
        let position_note = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            position_liquidity,
            fee_growth_inside_before,
            fee_growth_inside_before,
        )?;
        let position_commitment = compute_position_commitment(&position_note)?;
        let nullifier_position = generate_position_nullifier_hash(&position_note)?;
        let output_position_note = next_position_note(
            rng,
            tick_lower,
            tick_upper,
            position_liquidity,
            fee_growth_inside_after,
            fee_growth_inside_after,
        )?;
        let new_position_commitment = compute_position_commitment(&output_position_note)?;
        let (fee_amount0, fee_amount1) = compute_fee_amounts(
            position_liquidity,
            fee_growth_inside_before,
            fee_growth_inside_before,
            fee_growth_inside_after,
            fee_growth_inside_after,
        )?;
        let out_note0 =
            build_output_note_for_amount(rng, fee_amount0, pool_config.token0, 0)?;
        let out_note1 =
            build_output_note_for_amount(rng, fee_amount1, pool_config.token1, 1)?;
        let output_commitment_token0 = out_note0
            .as_ref()
            .map(|note| compute_commitment(note, 0))
            .transpose()?
            .unwrap_or(Felt::ZERO);
        let output_commitment_token1 = out_note1
            .as_ref()
            .map(|note| compute_commitment(note, 1))
            .transpose()?
            .unwrap_or(Felt::ZERO);

        let witness = build_liquidity_witness(
            pool_config,
            VK_LIQ_CLAIM_DEC,
            Felt::ONE,
            Felt::ONE,
            Felt::ONE,
            nullifier_position,
            pool_state.sqrt_price,
            pool_state.tick,
            pool_state.liquidity,
            U256::from_words(pool_state.fee_growth_global_0.0, pool_state.fee_growth_global_0.1),
            U256::from_words(pool_state.fee_growth_global_1.0, pool_state.fee_growth_global_1.1),
            tick_lower,
            tick_upper,
            sqrt_ratio_lower,
            sqrt_ratio_upper,
            false,
            position_liquidity,
            0,
            position_commitment,
            new_position_commitment,
            fee_growth_inside_before,
            fee_growth_inside_before,
            fee_growth_inside_after,
            fee_growth_inside_after,
            &[],
            &[],
            output_commitment_token0,
            output_commitment_token1,
            Some(position_note.secret),
            Some(position_note.nullifier),
            output_position_note.secret,
            output_position_note.nullifier,
            out_note0.as_ref().map(|note| note.secret),
            out_note0.as_ref().map(|note| note.nullifier),
            out_note1.as_ref().map(|note| note.secret),
            out_note1.as_ref().map(|note| note.nullifier),
            0,
            0,
            empty_div_matrix(),
            empty_div_matrix(),
        )?;
        Ok(wrap_input(generate_lp_remove_witness_inputs(witness)?))
    }

    async fn quote_with_min_steps(
        swap_client: &SwapClient<Arc<Account>>,
        sqrt_ratio_limit: U256,
        amount: SignedAmount,
        is_token1: bool,
        min_steps: usize,
    ) -> Result<SwapStepsQuote, Box<dyn Error>> {
        let mut current = amount.mag;
        let mut last = None;
        for _ in 0..6 {
            let quote = swap_client
                .quote_swap_steps(SwapQuoteRequest {
                    amount: SignedAmount {
                        mag: current,
                        sign: amount.sign,
                    },
                    is_token1,
                    sqrt_ratio_limit,
                    skip_ahead: 0,
                })
                .await?;
            let active = quote
                .steps
                .iter()
                .filter(|step| step.amount_in > 0 || step.amount_out > 0)
                .count();
            if active >= min_steps {
                return Ok(quote);
            }
            last = Some(quote);
            current = current.saturating_mul(2);
        }
        Ok(last.ok_or("failed to obtain swap quote")?)
    }

    fn split_notes(
        rng: &mut StdRng,
        amount: u128,
        token: Felt,
        token_id: u8,
    ) -> Result<Vec<Note>, ClientError> {
        let first = amount / 2;
        let second = amount - first;
        let mut notes = Vec::new();
        if first > 0 {
            notes.push(next_note(rng, first, token, token_id)?);
        }
        if second > 0 {
            notes.push(next_note(rng, second, token, token_id)?);
        }
        if notes.is_empty() {
            notes.push(next_note(rng, 0, token, token_id)?);
        }
        Ok(notes)
    }

    fn build_input_notes(
        rng: &mut StdRng,
        amount: u128,
        token: Felt,
        token_id: u8,
    ) -> Result<Vec<Note>, ClientError> {
        if amount == 0 {
            return Ok(vec![next_note(rng, 0, token, token_id)?]);
        }
        Ok(vec![next_note(rng, amount, token, token_id)?])
    }

    fn build_output_note_for_amount(
        rng: &mut StdRng,
        amount: u128,
        token: Felt,
        token_id: u8,
    ) -> Result<Option<Note>, ClientError> {
        if amount == 0 {
            return Ok(None);
        }
        Ok(Some(next_note(rng, amount, token, token_id)?))
    }

    fn next_note(
        rng: &mut StdRng,
        amount: u128,
        token: Felt,
        token_id: u8,
    ) -> Result<Note, ClientError> {
        for _ in 0..64 {
            let mut secret = [0u8; 32];
            let mut nullifier = [0u8; 32];
            rng.fill_bytes(&mut secret);
            rng.fill_bytes(&mut nullifier);
            let note = Note {
                secret,
                nullifier,
                amount,
                token,
            };
            if compute_commitment(&note, token_id).is_ok() {
                return Ok(note);
            }
        }
        Err(ClientError::Crypto(
            "failed to generate note".to_string(),
        ))
    }

    fn next_position_note(
        rng: &mut StdRng,
        tick_lower: i32,
        tick_upper: i32,
        liquidity: u128,
        fee_growth_inside_0: U256,
        fee_growth_inside_1: U256,
    ) -> Result<PositionNote, ClientError> {
        for _ in 0..64 {
            let mut secret = [0u8; 32];
            let mut nullifier = [0u8; 32];
            rng.fill_bytes(&mut secret);
            rng.fill_bytes(&mut nullifier);
            let note = PositionNote {
                secret,
                nullifier,
                tick_lower,
                tick_upper,
                liquidity,
                fee_growth_inside_0,
                fee_growth_inside_1,
            };
            if compute_position_commitment(&note).is_ok() {
                return Ok(note);
            }
        }
        Err(ClientError::Crypto(
            "failed to generate position note".to_string(),
        ))
    }

    fn wrap_input(input: Value) -> Value {
        Value::Object(
            [("input".to_string(), input)]
                .into_iter()
                .collect(),
        )
    }

    fn write_vector(path: PathBuf, input: Value, should_fail: bool) -> Result<(), Box<dyn Error>> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let mut obj = match input {
            Value::Object(map) => map,
            _ => return Err("invalid vector input".into()),
        };
        if should_fail {
            obj.insert("should_fail".to_string(), Value::Bool(true));
        }
        fs::write(path, serde_json::to_string_pretty(&Value::Object(obj))?)?;
        Ok(())
    }

    fn mutate_swap_insufficient_balance(input: &Value) -> Result<Value, Box<dyn Error>> {
        let mut root = input.clone();
        let note_amounts = root
            .pointer_mut("/input/note_amount_in")
            .ok_or("missing note_amount_in")?;
        match note_amounts {
            Value::Array(values) if !values.is_empty() => {
                values[0] = Value::String("0".to_string());
            }
            _ => return Err("invalid note_amount_in".into()),
        }
        Ok(root)
    }

    fn mutate_liquidity_out_of_range(input: &Value) -> Result<Value, Box<dyn Error>> {
        let mut root = input.clone();
        let tick_upper_val = root
            .pointer("/input/tick_upper")
            .ok_or("missing tick_upper")?
            .as_str()
            .ok_or("tick_upper is not string")?;
        let tick_upper = decode_i32_twos_complement(tick_upper_val)?;
        let tick_lower = root
            .pointer_mut("/input/tick_lower")
            .ok_or("missing tick_lower")?;
        *tick_lower = Value::String(encode_i32_twos_complement(tick_upper));
        Ok(root)
    }

    fn encode_i32_twos_complement(value: i32) -> String {
        if value >= 0 {
            (value as u128).to_string()
        } else {
            let mag = (-(value as i128)) as u128;
            u128::MAX.wrapping_sub(mag).wrapping_add(1).to_string()
        }
    }

    fn align_tick(tick: i32, spacing: i32) -> i32 {
        if spacing == 0 {
            return tick;
        }
        let div = tick.div_euclid(spacing);
        div * spacing
    }

    fn decode_i32_twos_complement(value: &str) -> Result<i32, Box<dyn Error>> {
        let raw: u128 = value.parse()?;
        if raw <= i32::MAX as u128 {
            return Ok(raw as i32);
        }
        let mag = (!raw).wrapping_add(1);
        let mag_i128 = i128::try_from(mag)?;
        let neg = -mag_i128;
        let out = i32::try_from(neg)?;
        Ok(out)
    }

    fn required_felt(name: &str) -> Result<Felt, Box<dyn Error>> {
        let value = env::var(name)
            .map_err(|_| format!("missing env {}", name))?;
        Ok(parse_felt(&value)?)
    }

    fn load_addresses(path: PathBuf) -> Result<DevnetAddresses, Box<dyn Error>> {
        let raw = fs::read_to_string(path)?;
        let addrs = serde_json::from_str(&raw)?;
        Ok(addrs)
    }

    fn repo_root() -> PathBuf {
        Path::new(env!("CARGO_MANIFEST_DIR"))
            .join("..")
            .join("..")
    }

    async fn fetch_pool_state(
        swap_client: &SwapClient<Arc<Account>>,
    ) -> Result<PoolState, ClientError> {
        let selector = get_selector_from_name("get_pool_state")
            .map_err(|err| ClientError::InvalidInput(err.to_string()))?;
        let call = FunctionCall {
            contract_address: swap_client.pool_address,
            entry_point_selector: selector,
            calldata: Vec::new(),
        };
        let provider = swap_client.account.provider();
        let result = provider
            .call(call.clone(), BlockId::Tag(BlockTag::Latest))
            .await
            .map_err(|err| ClientError::Rpc(err.to_string()))?;
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
        Ok(PoolState {
            sqrt_price,
            tick,
            liquidity,
            fee_growth_global_0: (fee0_low, fee0_high),
            fee_growth_global_1: (fee1_low, fee1_high),
        })
    }
}
