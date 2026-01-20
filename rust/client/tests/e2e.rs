use std::collections::HashMap;
use std::env;
use std::fs;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use num_bigint::BigUint;
use serde::Deserialize;
use starknet::accounts::{ExecutionEncoding, SingleOwnerAccount};
use starknet::core::types::{BlockId, BlockTag, Felt, U256};
use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
use starknet::providers::Provider;
use starknet::signers::{LocalWallet, SigningKey};
use tokio::time::sleep;
use url::Url;

use zylith_client::{
    compute_commitment, compute_position_commitment, generate_note_with_token_id,
    generate_nullifier_hash, parse_felt, DepositRequest, LiquidityAddProveRequest,
    LiquidityRemoveProveRequest, LiquidityRequest, Note, SwapProveRequest, WithdrawRequest,
    SwapClient, ZylithClient, ZylithConfig,
};
use zylith_prover::{prove_deposit, prove_withdraw, DepositWitnessInputs, ProofCalldata,
    WithdrawWitnessInputs, WitnessValue,
};

type Account = SingleOwnerAccount<JsonRpcClient<HttpTransport>, LocalWallet>;
type SwapAccount = SwapClient<Arc<Account>>;

#[derive(Deserialize)]
struct DevnetAddresses {
    shielded_notes: String,
    pool: String,
}

#[tokio::test]
async fn e2e_flow() -> Result<(), Box<dyn std::error::Error>> {
    if env::var("E2E").ok().as_deref() != Some("1") {
        return Ok(());
    }

    let rpc_url = env::var("RPC_URL").unwrap_or_else(|_| "http://127.0.0.1:5050".to_string());
    let asp_url = env::var("ASP_URL").unwrap_or_else(|_| "http://127.0.0.1:8080".to_string());
    let account_address = required_felt("ACCOUNT_ADDRESS")?;
    let private_key = required_felt("PRIVATE_KEY")?;

    let token0 = env::var("TOKEN0")
        .map(|v| parse_felt(&v))
        .unwrap_or_else(|_| parse_felt("0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d"))
        ?;
    let token1 = env::var("TOKEN1")
        .map(|v| parse_felt(&v))
        .unwrap_or_else(|_| parse_felt("0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7"))
        ?;

    let (pool_address, shielded_notes) = resolve_addresses()?;

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

    let client = ZylithClient::new(ZylithConfig {
        account,
        asp_url: asp_url.clone(),
        pool_address,
        shielded_notes_address: shielded_notes,
        token0,
        token1,
    });
    ensure_pool_initialized(&client, "startup").await?;
    let swap_client = client.swap_client();

    let note_liq0 = generate_note_with_token_id(1_000_000_000, token0, 0)?;
    let note_liq1 = generate_note_with_token_id(1_000_000_000, token1, 1)?;

    deposit_note(&client, &swap_client, &note_liq0, token0, 0)
        .await
        .map_err(|e| format!("deposit token0: {e}"))?;
    deposit_note(&client, &swap_client, &note_liq1, token1, 1)
        .await
        .map_err(|e| format!("deposit token1: {e}"))?;

    let add_result = client
        .prove_liquidity_add(LiquidityAddProveRequest {
            token0_notes: vec![note_liq0.clone()],
            token1_notes: vec![note_liq1.clone()],
            position_note: None,
            tick_lower: -180,
            tick_upper: 180,
            liquidity_delta: 1_000_000,
            output_position_note: None,
            output_note_token0: None,
            output_note_token1: None,
            circuit_dir: Some(default_circuit_dir("private_liquidity")),
        })
        .await?;

    client
        .add_liquidity(LiquidityRequest {
            proof: add_result.proof,
            proofs_token0: add_result.proofs_token0,
            proofs_token1: add_result.proofs_token1,
            proof_position: add_result.proof_position,
            insert_proof_position: add_result.insert_proof_position,
            output_proof_token0: add_result.output_proof_token0,
            output_proof_token1: add_result.output_proof_token1,
        })
        .await?;
    ensure_pool_initialized(&client, "after first add").await?;

    let position_note = add_result
        .output_position_note
        .ok_or("missing output position note")?;
    let position_commitment = compute_position_commitment(&position_note)?;
    wait_for_path(&swap_client, position_commitment).await?;
    wait_for_optional_note_paths(
        &swap_client,
        add_result.output_note_token0.as_ref(),
        add_result.output_note_token1.as_ref(),
    )
    .await?;

    let note_liq0_b = generate_note_with_token_id(1_000_000_000, token0, 0)?;
    let note_liq1_b = generate_note_with_token_id(1_000_000_000, token1, 1)?;
    deposit_note(&client, &swap_client, &note_liq0_b, token0, 0)
        .await
        .map_err(|e| format!("deposit token0 (second): {e}"))?;
    deposit_note(&client, &swap_client, &note_liq1_b, token1, 1)
        .await
        .map_err(|e| format!("deposit token1 (second): {e}"))?;

    let add_result_b = client
        .prove_liquidity_add(LiquidityAddProveRequest {
            token0_notes: vec![note_liq0_b.clone()],
            token1_notes: vec![note_liq1_b.clone()],
            position_note: Some(position_note.clone()),
            tick_lower: -180,
            tick_upper: 180,
            liquidity_delta: 500_000,
            output_position_note: None,
            output_note_token0: None,
            output_note_token1: None,
            circuit_dir: Some(default_circuit_dir("private_liquidity")),
        })
        .await?;

    client
        .add_liquidity(LiquidityRequest {
            proof: add_result_b.proof,
            proofs_token0: add_result_b.proofs_token0,
            proofs_token1: add_result_b.proofs_token1,
            proof_position: add_result_b.proof_position,
            insert_proof_position: add_result_b.insert_proof_position,
            output_proof_token0: add_result_b.output_proof_token0,
            output_proof_token1: add_result_b.output_proof_token1,
        })
        .await?;
    ensure_pool_initialized(&client, "after second add").await?;

    let position_note_b = add_result_b
        .output_position_note
        .ok_or("missing updated position note")?;
    let position_commitment_b = compute_position_commitment(&position_note_b)?;
    wait_for_path(&swap_client, position_commitment_b).await?;
    wait_for_optional_note_paths(
        &swap_client,
        add_result_b.output_note_token0.as_ref(),
        add_result_b.output_note_token1.as_ref(),
    )
    .await?;

    let remove_result = client
        .prove_liquidity_remove(LiquidityRemoveProveRequest {
            position_note: position_note_b.clone(),
            liquidity_delta: 300_000,
            output_position_note: None,
            output_note_token0: None,
            output_note_token1: None,
            circuit_dir: Some(default_circuit_dir("private_liquidity")),
        })
        .await?;

    let proof_position = remove_result
        .proof_position
        .ok_or("missing position proof")?;
    client
        .remove_liquidity(
            remove_result.proof,
            proof_position,
            remove_result.insert_proof_position,
            remove_result.output_proof_token0,
            remove_result.output_proof_token1,
        )
        .await?;
    ensure_pool_initialized(&client, "after remove").await?;
    wait_for_optional_note_paths(
        &swap_client,
        remove_result.output_note_token0.as_ref(),
        remove_result.output_note_token1.as_ref(),
    )
    .await?;

    let note_swap0 = generate_note_with_token_id(50_000_000, token0, 0)?;
    let note_swap1 = generate_note_with_token_id(50_000_000, token0, 0)?;
    deposit_note(&client, &swap_client, &note_swap0, token0, 0)
        .await
        .map_err(|e| format!("deposit swap note0: {e}"))?;
    deposit_note(&client, &swap_client, &note_swap1, token0, 0)
        .await
        .map_err(|e| format!("deposit swap note1: {e}"))?;

    let swap_debug_config = client.get_pool_config().await?;
    let swap_debug_limit = if true { swap_debug_config.min_sqrt_ratio } else { swap_debug_config.max_sqrt_ratio };
    let debug_quote = swap_client
        .quote_swap_steps(zylith_client::SwapQuoteRequest {
            amount: zylith_client::SignedAmount { mag: 100_000_000, sign: false },
            is_token1: false,
            sqrt_ratio_limit: swap_debug_limit,
            skip_ahead: 0,
        })
        .await
        .map_err(|e| format!("swap quote debug: {e}"))?;
    if let Some(first) = debug_quote.steps.first() {
        println!(
            "[e2e] quote debug: sqrt_limit={}, sqrt_next={}, tick_next={}",
            first.sqrt_price_limit, first.sqrt_price_next, first.tick_next
        );
    }
    for (idx, step) in debug_quote.steps.iter().enumerate() {
        if step.sqrt_price_limit == U256::from(0u128) {
            println!(
                "[e2e] quote debug: zero sqrt_limit at step {}, sqrt_next={}, tick_next={}",
                idx, step.sqrt_price_next, step.tick_next
            );
        }
    }

    let swap_result = client
        .prove_swap(SwapProveRequest {
            notes: vec![note_swap0.clone(), note_swap1.clone()],
            zero_for_one: true,
            exact_out: false,
            amount_out: None,
            sqrt_ratio_limit: None,
            output_note: None,
            change_note: None,
            circuit_dir: Some(default_circuit_dir("private_swap")),
        })
        .await
        .map_err(|e| format!("prove swap: {e}"))?;

    client
        .swap(
            swap_result.proof,
            &swap_result.input_proofs,
            &swap_result.output_proofs,
            false,
        )
        .await
        .map_err(|e| format!("swap tx: {e}"))?;

    let output_note = swap_result
        .output_note
        .ok_or("missing swap output note")?;
    let output_commitment = compute_commitment(&output_note, 1)?;
    let withdraw_path = wait_for_path(&swap_client, output_commitment).await?;
    let withdraw_proof = prove_withdraw_note(&output_note, 1, account_address).await?;

    client
        .withdraw_client()
        .withdraw(WithdrawRequest {
            note: output_note,
            token_id: 1,
            token_address: token1,
            recipient: account_address,
            proof: withdraw_proof,
            merkle_proof: withdraw_path,
        })
        .await
        .map_err(|e| format!("withdraw: {e}"))?;

    Ok(())
}

async fn ensure_pool_initialized(
    client: &ZylithClient<Account>,
    label: &str,
) -> Result<(), Box<dyn std::error::Error>> {
    let pool_state = client.get_pool_state().await?;
    if pool_state.sqrt_price == U256::from(0u128) {
        return Err(format!("pool sqrt_price is zero ({label})").into());
    }
    let pool_config = client.get_pool_config().await?;
    if pool_config.min_sqrt_ratio == U256::from(0u128)
        || pool_config.max_sqrt_ratio == U256::from(0u128)
    {
        return Err(format!("pool config sqrt ratio is zero ({label})").into());
    }
    println!(
        "[e2e] pool_state {label}: sqrt_price={}, tick={}, liquidity={}",
        pool_state.sqrt_price, pool_state.tick, pool_state.liquidity
    );
    println!(
        "[e2e] pool_config {label}: min_sqrt_ratio={}, max_sqrt_ratio={}, fee={}, tick_spacing={}",
        pool_config.min_sqrt_ratio,
        pool_config.max_sqrt_ratio,
        pool_config.fee,
        pool_config.tick_spacing
    );
    Ok(())
}

async fn deposit_note(
    client: &ZylithClient<Account>,
    swap_client: &SwapAccount,
    note: &Note,
    token: Felt,
    token_id: u8,
) -> Result<(), Box<dyn std::error::Error>> {
    let proof = prove_deposit_note(note, token_id).await?;
    let insertion = wait_for_insertion_path(swap_client, token).await?;
    client
        .deposit(DepositRequest {
            note: note.clone(),
            token_id,
            token_address: token,
            proof,
            insertion_proof: insertion,
        })
        .await?;

    let commitment = compute_commitment(note, token_id)?;
    wait_for_path(swap_client, commitment).await?;
    Ok(())
}

async fn wait_for_insertion_path(
    swap_client: &SwapAccount,
    token: Felt,
) -> Result<zylith_client::MerklePath, Box<dyn std::error::Error>> {
    let mut attempts = 0;
    loop {
        match swap_client.fetch_insertion_path(token).await {
            Ok(path) => return Ok(path),
            Err(err) => {
                attempts += 1;
                if attempts > 20 {
                    return Err(Box::new(err));
                }
                sleep(Duration::from_millis(500)).await;
            }
        }
    }
}

async fn wait_for_path(
    swap_client: &SwapAccount,
    commitment: Felt,
) -> Result<zylith_client::MerklePath, Box<dyn std::error::Error>> {
    let mut attempts = 0;
    loop {
        match swap_client.fetch_merkle_path(commitment, None, None).await {
            Ok(path) => return Ok(path),
            Err(err) => {
                attempts += 1;
                if attempts > 30 {
                    return Err(Box::new(err));
                }
                sleep(Duration::from_millis(700)).await;
            }
        }
    }
}

async fn wait_for_optional_note_paths(
    swap_client: &SwapAccount,
    note0: Option<&Note>,
    note1: Option<&Note>,
) -> Result<(), Box<dyn std::error::Error>> {
    if let Some(note) = note0 {
        let commitment = compute_commitment(note, 0)?;
        wait_for_path(swap_client, commitment).await?;
    }
    if let Some(note) = note1 {
        let commitment = compute_commitment(note, 1)?;
        wait_for_path(swap_client, commitment).await?;
    }
    Ok(())
}

async fn prove_deposit_note(note: &Note, token_id: u8) -> Result<ProofCalldata, Box<dyn std::error::Error>> {
    let commitment = compute_commitment(note, token_id)?;
    let tag = vk_tag("DEPOSIT")?;
    let mut values = HashMap::new();
    values.insert("tag".to_string(), WitnessValue::Scalar(tag.to_string()));
    values.insert(
        "commitment".to_string(),
        WitnessValue::Scalar(felt_to_decimal(commitment)),
    );
    values.insert("amount".to_string(), WitnessValue::U128(note.amount));
    values.insert("token_id".to_string(), WitnessValue::U128(token_id as u128));
    values.insert(
        "secret".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.secret)),
    );
    values.insert(
        "nullifier_seed".to_string(),
        WitnessValue::Scalar(bytes_to_decimal(&note.nullifier)),
    );
    let witness = DepositWitnessInputs { values };
    let circuit_dir = default_circuit_dir("private_deposit");
    Ok(prove_deposit(witness, &circuit_dir).await?)
}

async fn prove_withdraw_note(
    note: &Note,
    token_id: u8,
    recipient: Felt,
) -> Result<ProofCalldata, Box<dyn std::error::Error>> {
    let commitment = compute_commitment(note, token_id)?;
    let nullifier = generate_nullifier_hash(note, token_id)?;
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
    values.insert("token_id".to_string(), WitnessValue::U128(token_id as u128));
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
    let circuit_dir = default_circuit_dir("private_withdraw");
    Ok(prove_withdraw(witness, &circuit_dir).await?)
}

fn default_circuit_dir(circuit: &str) -> PathBuf {
    repo_root().join("artifacts").join(circuit)
}

fn bytes_to_decimal(value: &[u8; 32]) -> String {
    BigUint::from_bytes_be(value).to_str_radix(10)
}

fn felt_to_decimal(value: Felt) -> String {
    BigUint::from_bytes_be(&value.to_bytes_be()).to_str_radix(10)
}

fn vk_tag(tag: &str) -> Result<u64, Box<dyn std::error::Error>> {
    match tag {
        "DEPOSIT" => Ok(0x4445504f534954),
        "WITHDRAW" => Ok(0x5749544844524157),
        _ => Err("unknown verifier tag".into()),
    }
}

fn required_felt(key: &str) -> Result<Felt, Box<dyn std::error::Error>> {
    let value = env::var(key)?;
    Ok(parse_felt(&value)?)
}

fn load_addresses(path: PathBuf) -> Result<DevnetAddresses, Box<dyn std::error::Error>> {
    let raw = fs::read_to_string(path)?;
    Ok(serde_json::from_str(&raw)?)
}

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .join("..")
        .join("..")
}

fn resolve_addresses() -> Result<(Felt, Felt), Box<dyn std::error::Error>> {
    if let Ok(value) = env::var("POOL") {
        let pool = parse_felt(&value)?;
        let notes = env::var("SHIELDED_NOTES")
            .or_else(|_| env::var("SHIELDED_NOTES_ADDRESS"))
            .map(|v| parse_felt(&v))??;
        return Ok((pool, notes));
    }
    if let Ok(value) = env::var("POOL_ADDRESS") {
        let pool = parse_felt(&value)?;
        let notes = env::var("SHIELDED_NOTES")
            .or_else(|_| env::var("SHIELDED_NOTES_ADDRESS"))
            .map(|v| parse_felt(&v))??;
        return Ok((pool, notes));
    }
    let addrs = load_addresses(repo_root().join("artifacts/devnet_addresses.json"))?;
    let pool_address = parse_felt(&addrs.pool)?;
    let shielded_notes = parse_felt(&addrs.shielded_notes)?;
    Ok((pool_address, shielded_notes))
}
