use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use clap::{Args, Parser, Subcommand};
use num_bigint::BigUint;
use num_traits::Num;
use serde::{Deserialize, Serialize};
use starknet::accounts::{ExecutionEncoding, SingleOwnerAccount};
use starknet::core::types::{BlockId, BlockTag, Felt, U256};
use starknet::providers::jsonrpc::{HttpTransport, JsonRpcClient};
use starknet::providers::Provider;
use starknet::signers::{LocalWallet, SigningKey};
use url::Url;

use zylith_client::{
    compute_commitment, compute_position_commitment, generate_note_with_token_id,
    generate_nullifier_hash, generate_position_note, generate_position_nullifier_hash, parse_felt,
    DepositClient, DepositRequest, LiquidityAddProveRequest, LiquidityClaimProveRequest,
    LiquidityClaimRequest, LiquidityProveResult, LiquidityRemoveProveRequest, LiquidityRequest,
    MerklePath, Note, PositionNote, SignedAmount, SwapClient, SwapProveRequest, SwapProveResult,
    SwapQuoteRequest, WithdrawClient, WithdrawRequest, ZylithClient, ZylithConfig,
};
use zylith_prover::{
    prove_deposit, prove_withdraw, DepositWitnessInputs, ProofCalldata, WitnessValue,
    WithdrawWitnessInputs,
};

#[derive(Parser)]
#[command(name = "zylith-cli")]
#[command(about = "zylith cli for local dev flows", long_about = None)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Subcommand)]
enum Commands {
    NoteNew {
        #[arg(long)]
        amount: u128,
        #[arg(long)]
        token: String,
        #[arg(long)]
        token_id: u8,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    PositionNoteNew {
        #[arg(long)]
        tick_lower: i32,
        #[arg(long)]
        tick_upper: i32,
        #[arg(long)]
        liquidity: u128,
        #[arg(long)]
        fee_growth_inside_0: String,
        #[arg(long)]
        fee_growth_inside_1: String,
        #[arg(long)]
        out: Option<PathBuf>,
    },
    PositionNoteCommitment {
        #[arg(long)]
        note: PathBuf,
    },
    Deposit {
        #[arg(long)]
        note: PathBuf,
        #[arg(long)]
        token_id: u8,
        #[arg(long)]
        token_address: String,
        #[arg(long)]
        notes_address: String,
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    Withdraw {
        #[arg(long)]
        note: PathBuf,
        #[arg(long)]
        token_id: u8,
        #[arg(long)]
        token_address: String,
        #[arg(long)]
        notes_address: String,
        #[arg(long)]
        recipient: String,
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    Swap {
        #[arg(long, num_args = 1.., value_delimiter = ',')]
        note_in: Vec<PathBuf>,
        #[arg(long)]
        pool_address: String,
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        zero_for_one: bool,
        #[arg(long)]
        exact_out: bool,
        #[arg(long)]
        amount_out: Option<u128>,
        #[arg(long)]
        output_note: Option<PathBuf>,
        #[arg(long)]
        change_note: Option<PathBuf>,
        #[arg(long)]
        output_note_out: Option<PathBuf>,
        #[arg(long)]
        change_note_out: Option<PathBuf>,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    SwapQuote {
        #[arg(long)]
        pool_address: String,
        #[arg(long)]
        amount: u128,
        #[arg(long)]
        zero_for_one: bool,
        #[arg(long)]
        exact_out: bool,
        #[arg(long)]
        sqrt_ratio_limit: String,
        #[arg(long, default_value_t = 0)]
        skip_ahead: u128,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    LiquidityAdd {
        #[arg(long)]
        asp_url: String,
        #[arg(long, num_args = 0.., value_delimiter = ',')]
        token0_notes: Vec<PathBuf>,
        #[arg(long, num_args = 0.., value_delimiter = ',')]
        token1_notes: Vec<PathBuf>,
        #[arg(long)]
        position_note: Option<PathBuf>,
        #[arg(long)]
        tick_lower: i32,
        #[arg(long)]
        tick_upper: i32,
        #[arg(long)]
        liquidity_delta: u128,
        #[arg(long)]
        output_position_note: Option<PathBuf>,
        #[arg(long)]
        output_note_token0: Option<PathBuf>,
        #[arg(long)]
        output_note_token1: Option<PathBuf>,
        #[arg(long)]
        output_position_note_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token0_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token1_out: Option<PathBuf>,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[arg(long)]
        pool_address: String,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    LiquidityRemove {
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        position_note: PathBuf,
        #[arg(long)]
        liquidity_delta: u128,
        #[arg(long)]
        output_position_note: Option<PathBuf>,
        #[arg(long)]
        output_note_token0: Option<PathBuf>,
        #[arg(long)]
        output_note_token1: Option<PathBuf>,
        #[arg(long)]
        output_position_note_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token0_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token1_out: Option<PathBuf>,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[arg(long)]
        pool_address: String,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    LiquidityClaim {
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        position_note: PathBuf,
        #[arg(long)]
        output_position_note: Option<PathBuf>,
        #[arg(long)]
        output_note_token0: Option<PathBuf>,
        #[arg(long)]
        output_note_token1: Option<PathBuf>,
        #[arg(long)]
        output_position_note_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token0_out: Option<PathBuf>,
        #[arg(long)]
        output_note_token1_out: Option<PathBuf>,
        #[arg(long)]
        circuit_dir: Option<PathBuf>,
        #[arg(long)]
        pool_address: String,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    PoolState {
        #[arg(long)]
        pool_address: String,
        #[command(flatten)]
        network: NetworkArgs,
        #[command(flatten)]
        account: AccountArgs,
    },
    AspRootLatest {
        #[arg(long)]
        asp_url: String,
        #[arg(long)]
        token: String,
    },
}

#[derive(Args, Clone)]
struct NetworkArgs {
    #[arg(long)]
    rpc_url: String,
    #[arg(long)]
    chain_id: Option<String>,
}

#[derive(Args, Clone)]
struct AccountArgs {
    #[arg(long)]
    account_address: String,
    #[arg(long)]
    private_key: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct NoteFile {
    secret: String,
    nullifier: String,
    amount: String,
    token: String,
}

#[derive(Debug, Serialize, Deserialize)]
struct PositionNoteFile {
    secret: String,
    nullifier: String,
    tick_lower: i32,
    tick_upper: i32,
    liquidity: String,
    fee_growth_inside_0: String,
    fee_growth_inside_1: String,
}

#[derive(Debug, Deserialize)]
struct PathResponse {
    token: String,
    leaf_index: u64,
    path: Vec<String>,
    indices: Vec<bool>,
}

#[derive(Debug, Deserialize)]
struct RootAtResponse {
    token: String,
    root_index: u64,
    root: String,
    #[serde(default)]
    leaf_count: u64,
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


#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let cli = Cli::parse();
    match cli.command {
        Commands::NoteNew {
            amount,
            token,
            token_id,
            out,
        } => {
            let token_felt = parse_felt_arg(&token)?;
            let note = generate_note_with_token_id(amount, token_felt, token_id)?;
            let note_file = NoteFile {
                secret: bytes32_to_hex(&note.secret),
                nullifier: bytes32_to_hex(&note.nullifier),
                amount: note.amount.to_string(),
                token: felt_to_hex(note.token),
            };
            let serialized = serde_json::to_string_pretty(&note_file)?;
            if let Some(path) = out {
                fs::write(path, serialized)?;
            } else {
                println!("{serialized}");
            }
        }
        Commands::PositionNoteNew {
            tick_lower,
            tick_upper,
            liquidity,
            fee_growth_inside_0,
            fee_growth_inside_1,
            out,
        } => {
            let fee_growth_inside_0 = parse_u256_arg(&fee_growth_inside_0)?;
            let fee_growth_inside_1 = parse_u256_arg(&fee_growth_inside_1)?;
            let note = generate_position_note(
                tick_lower,
                tick_upper,
                liquidity,
                fee_growth_inside_0,
                fee_growth_inside_1,
            )?;
            let note_file = PositionNoteFile {
                secret: bytes32_to_hex(&note.secret),
                nullifier: bytes32_to_hex(&note.nullifier),
                tick_lower: note.tick_lower,
                tick_upper: note.tick_upper,
                liquidity: note.liquidity.to_string(),
                fee_growth_inside_0: u256_to_hex(&note.fee_growth_inside_0),
                fee_growth_inside_1: u256_to_hex(&note.fee_growth_inside_1),
            };
            let serialized = serde_json::to_string_pretty(&note_file)?;
            if let Some(path) = out {
                fs::write(path, serialized)?;
            } else {
                println!("{serialized}");
            }
        }
        Commands::PositionNoteCommitment { note } => {
            let note = load_position_note(&note)?;
            let commitment = compute_position_commitment(&note).map_err(|e| e.to_string())?;
            let nullifier = generate_position_nullifier_hash(&note).map_err(|e| e.to_string())?;
            println!("commitment={}", felt_to_hex(commitment));
            println!("nullifier={}", felt_to_hex(nullifier));
        }
        Commands::Deposit {
            note,
            token_id,
            token_address,
            notes_address,
            asp_url,
            circuit_dir,
            network,
            account,
        } => {
            let token_address = parse_felt_arg(&token_address)?;
            let notes_address = parse_felt_arg(&notes_address)?;
            let note = load_note(&note)?;
            if note.token != token_address {
                return Err("note token does not match token_address".into());
            }
            let proof = prove_deposit_proof(&note, token_id, circuit_dir).await?;
            let insertion = asp_fetch_insertion_path(&asp_url, token_address).await?;

            let account = build_account(&network, &account).await?;
            let client = DepositClient::new(account, notes_address);
            let request = DepositRequest {
                note,
                token_id,
                token_address,
                proof,
                insertion_proof: insertion,
            };
            let result = match token_id {
                0 => client.deposit_token0(request).await?,
                1 => client.deposit_token1(request).await?,
                _ => return Err("token_id must be 0 or 1".into()),
            };
            println!("tx_hash={}", result.tx_hash);
            println!("commitment=0x{:x}", result.commitment);
        }
        Commands::Withdraw {
            note,
            token_id,
            token_address,
            notes_address,
            recipient,
            asp_url,
            circuit_dir,
            network,
            account,
        } => {
            let token_address = parse_felt_arg(&token_address)?;
            let notes_address = parse_felt_arg(&notes_address)?;
            let recipient = parse_felt_arg(&recipient)?;
            let note = load_note(&note)?;
            if note.token != token_address {
                return Err("note token does not match token_address".into());
            }
            let proof = prove_withdraw_proof(&note, token_id, recipient, circuit_dir).await?;
            let commitment = compute_commitment(&note, token_id)?;
            let merkle_proof = asp_fetch_merkle_path(&asp_url, commitment, None, None).await?;

            let account = build_account(&network, &account).await?;
            let client = WithdrawClient::new(account, notes_address);
            let tx_hash = client
                .withdraw(WithdrawRequest {
                    note,
                    token_id,
                    token_address,
                    recipient,
                    proof,
                    merkle_proof,
                })
                .await?;
            println!("tx_hash={tx_hash}");
        }
        Commands::Swap {
            note_in,
            pool_address,
            asp_url,
            zero_for_one,
            exact_out,
            amount_out,
            output_note,
            change_note,
            output_note_out,
            change_note_out,
            circuit_dir,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;

            let mut notes = Vec::new();
            for path in &note_in {
                notes.push(load_note(path)?);
            }
            if notes.is_empty() {
                return Err("missing --note-in".into());
            }
            if exact_out && amount_out.is_none() {
                return Err("missing --amount-out for exact-out swap".into());
            }

            let output_note = match output_note {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let change_note = match change_note {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };

            let account = build_account(&network, &account).await?;
            let client = ZylithClient::new(ZylithConfig {
                account,
                asp_url: asp_url.clone(),
                pool_address,
                shielded_notes_address: Felt::ZERO,
                token0: Felt::ZERO,
                token1: Felt::ZERO,
            });
            let request = SwapProveRequest {
                notes,
                zero_for_one,
                exact_out,
                amount_out,
                sqrt_ratio_limit: None,
                output_note,
                change_note,
                circuit_dir,
            };
            let result = client.prove_swap(request).await?;
            let SwapProveResult {
                proof,
                input_proofs,
                output_proofs,
                output_note,
                change_note,
                ..
            } = result;
            let tx_hash = client
                .swap(proof, &input_proofs, &output_proofs, exact_out)
                .await?;
            println!("tx_hash={tx_hash}");
            write_note_output("output_note", output_note, output_note_out)?;
            write_note_output("change_note", change_note, change_note_out)?;
        }
        Commands::SwapQuote {
            pool_address,
            amount,
            zero_for_one,
            exact_out,
            sqrt_ratio_limit,
            skip_ahead,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;
            let sqrt_ratio_limit = parse_u256_arg(&sqrt_ratio_limit)?;
            let is_token1 = if exact_out { zero_for_one } else { !zero_for_one };
            let request = SwapQuoteRequest {
                amount: SignedAmount { mag: amount, sign: exact_out },
                is_token1,
                sqrt_ratio_limit,
                skip_ahead,
            };
            let account = build_account(&network, &account).await?;
            let client = SwapClient::new(account, pool_address, "");
            let quote = client.simulate_swap(request).await?;
            println!("delta_amount0_mag={}", quote.delta_amount0.mag);
            println!("delta_amount0_sign={}", quote.delta_amount0.sign);
            println!("delta_amount1_mag={}", quote.delta_amount1.mag);
            println!("delta_amount1_sign={}", quote.delta_amount1.sign);
            println!("sqrt_price_after={}", u256_to_hex(&quote.sqrt_price_after));
            println!("tick_after={}", quote.tick_after);
            println!("liquidity_after={}", quote.liquidity_after);
        }
        Commands::LiquidityAdd {
            asp_url,
            token0_notes,
            token1_notes,
            position_note,
            tick_lower,
            tick_upper,
            liquidity_delta,
            output_position_note,
            output_note_token0,
            output_note_token1,
            output_position_note_out,
            output_note_token0_out,
            output_note_token1_out,
            circuit_dir,
            pool_address,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;
            let account = build_account(&network, &account).await?;
            let client = ZylithClient::new(ZylithConfig {
                account,
                asp_url: asp_url.clone(),
                pool_address,
                shielded_notes_address: Felt::ZERO,
                token0: Felt::ZERO,
                token1: Felt::ZERO,
            });
            let token0_notes = load_notes(&token0_notes)?;
            let token1_notes = load_notes(&token1_notes)?;
            let position_note = match position_note {
                Some(path) => Some(load_position_note(&path)?),
                None => None,
            };
            let output_position_note = match output_position_note {
                Some(path) => Some(load_position_note(&path)?),
                None => None,
            };
            let output_note_token0 = match output_note_token0 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let output_note_token1 = match output_note_token1 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let request = LiquidityAddProveRequest {
                token0_notes,
                token1_notes,
                position_note,
                tick_lower,
                tick_upper,
                liquidity_delta,
                output_position_note,
                output_note_token0,
                output_note_token1,
                circuit_dir,
            };
            let result = client.prove_liquidity_add(request).await?;
            let LiquidityProveResult {
                proof,
                proofs_token0,
                proofs_token1,
                proof_position,
                insert_proof_position,
                output_proof_token0,
                output_proof_token1,
                output_note_token0,
                output_note_token1,
                output_position_note,
            } = result;
            let tx_hash = client
                .add_liquidity(LiquidityRequest {
                    proof,
                    proofs_token0,
                    proofs_token1,
                    proof_position,
                    insert_proof_position,
                    output_proof_token0,
                    output_proof_token1,
                })
                .await?;
            println!("tx_hash={tx_hash}");
            write_position_note_output("position_note", output_position_note, output_position_note_out)?;
            write_note_output("output_note_token0", output_note_token0, output_note_token0_out)?;
            write_note_output("output_note_token1", output_note_token1, output_note_token1_out)?;
        }
        Commands::LiquidityRemove {
            asp_url,
            position_note,
            liquidity_delta,
            output_position_note,
            output_note_token0,
            output_note_token1,
            output_position_note_out,
            output_note_token0_out,
            output_note_token1_out,
            circuit_dir,
            pool_address,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;
            let account = build_account(&network, &account).await?;
            let client = ZylithClient::new(ZylithConfig {
                account,
                asp_url: asp_url.clone(),
                pool_address,
                shielded_notes_address: Felt::ZERO,
                token0: Felt::ZERO,
                token1: Felt::ZERO,
            });
            let position_note = load_position_note(&position_note)?;
            let output_position_note = match output_position_note {
                Some(path) => Some(load_position_note(&path)?),
                None => None,
            };
            let output_note_token0 = match output_note_token0 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let output_note_token1 = match output_note_token1 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let request = LiquidityRemoveProveRequest {
                position_note,
                liquidity_delta,
                output_position_note,
                output_note_token0,
                output_note_token1,
                circuit_dir,
            };
            let result = client.prove_liquidity_remove(request).await?;
            let LiquidityProveResult {
                proof,
                proof_position,
                insert_proof_position,
                output_proof_token0,
                output_proof_token1,
                output_note_token0,
                output_note_token1,
                output_position_note,
                ..
            } = result;
            let proof_position = proof_position.ok_or("missing proof_position")?;
            let tx_hash = client
                .remove_liquidity(
                    proof,
                    proof_position,
                    insert_proof_position,
                    output_proof_token0,
                    output_proof_token1,
                )
                .await?;
            println!("tx_hash={tx_hash}");
            write_position_note_output("position_note", output_position_note, output_position_note_out)?;
            write_note_output("output_note_token0", output_note_token0, output_note_token0_out)?;
            write_note_output("output_note_token1", output_note_token1, output_note_token1_out)?;
        }
        Commands::LiquidityClaim {
            asp_url,
            position_note,
            output_position_note,
            output_note_token0,
            output_note_token1,
            output_position_note_out,
            output_note_token0_out,
            output_note_token1_out,
            circuit_dir,
            pool_address,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;
            let account = build_account(&network, &account).await?;
            let client = ZylithClient::new(ZylithConfig {
                account,
                asp_url: asp_url.clone(),
                pool_address,
                shielded_notes_address: Felt::ZERO,
                token0: Felt::ZERO,
                token1: Felt::ZERO,
            });
            let position_note = load_position_note(&position_note)?;
            let output_position_note = match output_position_note {
                Some(path) => Some(load_position_note(&path)?),
                None => None,
            };
            let output_note_token0 = match output_note_token0 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let output_note_token1 = match output_note_token1 {
                Some(path) => Some(load_note(&path)?),
                None => None,
            };
            let request = LiquidityClaimProveRequest {
                position_note,
                output_position_note,
                output_note_token0,
                output_note_token1,
                circuit_dir,
            };
            let result = client.prove_liquidity_claim(request).await?;
            let LiquidityProveResult {
                proof,
                proof_position,
                insert_proof_position,
                output_proof_token0,
                output_proof_token1,
                output_note_token0,
                output_note_token1,
                output_position_note,
                ..
            } = result;
            let proof_position = proof_position.ok_or("missing proof_position")?;
            let claim = LiquidityClaimRequest {
                proof,
                proof_position,
                insert_proof_position,
                output_proof_token0,
                output_proof_token1,
            };
            let tx_hash = client.claim_liquidity_fees(claim).await?;
            println!("tx_hash={tx_hash}");
            write_position_note_output("position_note", output_position_note, output_position_note_out)?;
            write_note_output("output_note_token0", output_note_token0, output_note_token0_out)?;
            write_note_output("output_note_token1", output_note_token1, output_note_token1_out)?;
        }
        Commands::PoolState {
            pool_address,
            network,
            account,
        } => {
            let pool_address = parse_felt_arg(&pool_address)?;
            let account = build_account(&network, &account).await?;
            let client = SwapClient::new(account, pool_address, "");
            let state = client.get_pool_state().await?;
            println!("sqrt_price={}", state.0);
            println!("tick={}", state.1);
            println!("liquidity={}", state.2);
        }
        Commands::AspRootLatest { asp_url, token } => {
            let token_label = if token == "position" {
                token
            } else {
                felt_to_hex(parse_felt_arg(&token)?)
            };
            let (root, root_index, leaf_count) =
                asp_fetch_latest_root(&asp_url, &token_label).await?;
            println!("token={token_label}");
            println!("root_index={root_index}");
            println!("leaf_count={leaf_count}");
            println!("root={}", felt_to_hex(root));
        }
    }
    Ok(())
}

async fn build_account(
    network: &NetworkArgs,
    account: &AccountArgs,
) -> Result<SingleOwnerAccount<JsonRpcClient<HttpTransport>, LocalWallet>, String> {
    let rpc_url = Url::parse(&network.rpc_url).map_err(|e| e.to_string())?;
    let provider = JsonRpcClient::new(HttpTransport::new(rpc_url));
    let chain_id = match &network.chain_id {
        Some(chain_id) => parse_felt_arg(chain_id)?,
        None => provider
            .chain_id()
            .await
            .map_err(|e| e.to_string())?,
    };
    let account_address = parse_felt_arg(&account.account_address)?;
    let private_key = parse_felt_arg(&account.private_key)?;
    let signing_key = SigningKey::from_secret_scalar(private_key);
    let mut account = SingleOwnerAccount::new(
        provider,
        LocalWallet::from(signing_key),
        account_address,
        chain_id,
        ExecutionEncoding::New,
    );
    account.set_block_id(BlockId::Tag(BlockTag::Latest));
    Ok(account)
}

async fn prove_deposit_proof(
    note: &Note,
    token_id: u8,
    circuit_dir: Option<PathBuf>,
) -> Result<ProofCalldata, String> {
    if token_id > 1 {
        return Err("token_id must be 0 or 1".to_string());
    }
    let commitment = compute_commitment(note, token_id).map_err(|e| e.to_string())?;
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
    let circuit_dir = circuit_dir.unwrap_or_else(|| default_circuit_dir("private_deposit"));
    prove_deposit(witness, &circuit_dir)
        .await
        .map_err(|e| e.to_string())
}

async fn prove_withdraw_proof(
    note: &Note,
    token_id: u8,
    recipient: Felt,
    circuit_dir: Option<PathBuf>,
) -> Result<ProofCalldata, String> {
    if token_id > 1 {
        return Err("token_id must be 0 or 1".to_string());
    }
    let commitment = compute_commitment(note, token_id).map_err(|e| e.to_string())?;
    let nullifier = generate_nullifier_hash(note, token_id).map_err(|e| e.to_string())?;
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
    let circuit_dir = circuit_dir.unwrap_or_else(|| default_circuit_dir("private_withdraw"));
    prove_withdraw(witness, &circuit_dir)
        .await
        .map_err(|e| e.to_string())
}

fn default_circuit_dir(circuit: &str) -> PathBuf {
    PathBuf::from("artifacts").join(circuit)
}

fn load_note(path: &Path) -> Result<Note, String> {
    let contents = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let note: NoteFile = serde_json::from_str(&contents).map_err(|e| e.to_string())?;
    let secret = parse_bytes32(&note.secret)?;
    let nullifier = parse_bytes32(&note.nullifier)?;
    let amount = note.amount.parse::<u128>().map_err(|e| e.to_string())?;
    let token = parse_felt_arg(&note.token)?;
    Ok(Note {
        secret,
        nullifier,
        amount,
        token,
    })
}

fn load_notes(paths: &[PathBuf]) -> Result<Vec<Note>, String> {
    let mut notes = Vec::with_capacity(paths.len());
    for path in paths {
        notes.push(load_note(path)?);
    }
    Ok(notes)
}

fn load_position_note(path: &Path) -> Result<PositionNote, String> {
    let contents = fs::read_to_string(path).map_err(|e| e.to_string())?;
    let note: PositionNoteFile = serde_json::from_str(&contents).map_err(|e| e.to_string())?;
    let secret = parse_bytes32(&note.secret)?;
    let nullifier = parse_bytes32(&note.nullifier)?;
    let liquidity = note.liquidity.parse::<u128>().map_err(|e| e.to_string())?;
    let fee_growth_inside_0 = parse_u256_arg(&note.fee_growth_inside_0)?;
    let fee_growth_inside_1 = parse_u256_arg(&note.fee_growth_inside_1)?;
    Ok(PositionNote {
        secret,
        nullifier,
        tick_lower: note.tick_lower,
        tick_upper: note.tick_upper,
        liquidity,
        fee_growth_inside_0,
        fee_growth_inside_1,
    })
}

fn write_note_output(
    label: &str,
    note: Option<Note>,
    out: Option<PathBuf>,
) -> Result<(), String> {
    let Some(note) = note else {
        return Ok(());
    };
    let file = NoteFile {
        secret: bytes32_to_hex(&note.secret),
        nullifier: bytes32_to_hex(&note.nullifier),
        amount: note.amount.to_string(),
        token: felt_to_hex(note.token),
    };
    let serialized = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
    if let Some(path) = out {
        fs::write(path, serialized).map_err(|e| e.to_string())?;
    } else {
        println!("{label}={serialized}");
    }
    Ok(())
}

fn write_position_note_output(
    label: &str,
    note: Option<PositionNote>,
    out: Option<PathBuf>,
) -> Result<(), String> {
    let Some(note) = note else {
        return Ok(());
    };
    let file = PositionNoteFile {
        secret: bytes32_to_hex(&note.secret),
        nullifier: bytes32_to_hex(&note.nullifier),
        tick_lower: note.tick_lower,
        tick_upper: note.tick_upper,
        liquidity: note.liquidity.to_string(),
        fee_growth_inside_0: u256_to_hex(&note.fee_growth_inside_0),
        fee_growth_inside_1: u256_to_hex(&note.fee_growth_inside_1),
    };
    let serialized = serde_json::to_string_pretty(&file).map_err(|e| e.to_string())?;
    if let Some(path) = out {
        fs::write(path, serialized).map_err(|e| e.to_string())?;
    } else {
        println!("{label}={serialized}");
    }
    Ok(())
}


async fn asp_fetch_merkle_path(
    asp_url: &str,
    commitment: Felt,
    root_index: Option<u64>,
    root_hash: Option<Felt>,
) -> Result<MerklePath, String> {
    if root_index.is_some() && root_hash.is_some() {
        return Err("root_index and root_hash are mutually exclusive".to_string());
    }
    let mut payload = serde_json::Map::new();
    payload.insert(
        "commitment".to_string(),
        serde_json::Value::String(felt_to_hex(commitment)),
    );
    if let Some(index) = root_index {
        payload.insert(
            "root_index".to_string(),
            serde_json::Value::Number(serde_json::Number::from(index)),
        );
    }
    if let Some(hash) = root_hash {
        payload.insert(
            "root_hash".to_string(),
            serde_json::Value::String(felt_to_hex(hash)),
        );
    }

    let url = format!("{}/path", asp_url.trim_end_matches('/'));
    let client = asp_client()?;
    let response = client
        .post(url)
        .json(&payload)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("asp path error: {}", response.status()));
    }
    let body: PathResponse = response.json().await.map_err(|e| e.to_string())?;
    let token_label = body.token;
    let token = if token_label == "position" {
        Felt::ZERO
    } else {
        parse_felt_arg(&token_label)?
    };
    let path = parse_felt_vec(&body.path)?;

    let root = if let Some(hash) = root_hash {
        hash
    } else if let Some(index) = root_index {
        asp_fetch_root_at(asp_url, &token_label, index).await?
    } else {
        let (latest_root, _latest_root_index, latest_leaf_count) =
            asp_fetch_latest_root(asp_url, &token_label).await?;
        if latest_leaf_count != 0 && latest_leaf_count <= body.leaf_index {
            return Err("latest root does not include commitment".to_string());
        }
        latest_root
    };

    Ok(MerklePath {
        token,
        root,
        commitment,
        leaf_index: body.leaf_index,
        path,
        indices: body.indices,
    })
}

async fn asp_fetch_insertion_path(asp_url: &str, token: Felt) -> Result<MerklePath, String> {
    let token_label = felt_to_hex(token);
    let mut payload = serde_json::Map::new();
    payload.insert(
        "token".to_string(),
        serde_json::Value::String(token_label.clone()),
    );

    let url = format!("{}/insert_path", asp_url.trim_end_matches('/'));
    let client = asp_client()?;
    let response = client
        .post(url)
        .json(&payload)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("asp insert path error: {}", response.status()));
    }
    let body: InsertPathResponse = response.json().await.map_err(|e| e.to_string())?;
    if body.token != token_label {
        return Err("token mismatch".to_string());
    }
    let root = parse_felt_arg(&body.root)?;
    let commitment = parse_felt_arg(&body.commitment)?;
    let path = parse_felt_vec(&body.path)?;
    Ok(MerklePath {
        token,
        root,
        commitment,
        leaf_index: body.leaf_index,
        path,
        indices: body.indices,
    })
}

async fn asp_fetch_latest_root(asp_url: &str, token: &str) -> Result<(Felt, u64, u64), String> {
    let url = format!(
        "{}/root/latest?token={}",
        asp_url.trim_end_matches('/'),
        token
    );
    let client = asp_client()?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("asp root error: {}", response.status()));
    }
    let body: RootAtResponse = response.json().await.map_err(|e| e.to_string())?;
    if body.token != token {
        return Err("token mismatch".to_string());
    }
    let root = parse_felt_arg(&body.root)?;
    let leaf_count = body.leaf_count;
    Ok((root, body.root_index, leaf_count))
}

async fn asp_fetch_root_at(
    asp_url: &str,
    token: &str,
    index: u64,
) -> Result<Felt, String> {
    let url = format!("{}/root/{}?token={}", asp_url.trim_end_matches('/'), index, token);
    let client = asp_client()?;
    let response = client
        .get(url)
        .send()
        .await
        .map_err(|e| e.to_string())?;
    if !response.status().is_success() {
        return Err(format!("asp root error: {}", response.status()));
    }
    let body: RootAtResponse = response.json().await.map_err(|e| e.to_string())?;
    if body.token != token {
        return Err("token mismatch".to_string());
    }
    if body.root_index != index {
        return Err("root index mismatch".to_string());
    }
    parse_felt_arg(&body.root)
}

fn asp_timeout() -> Result<Duration, String> {
    if let Ok(value) = std::env::var("ZYLITH_ASP_TIMEOUT_SECS") {
        let secs = value
            .parse::<u64>()
            .map_err(|_| "invalid ZYLITH_ASP_TIMEOUT_SECS".to_string())?;
        if secs == 0 {
            return Err("ZYLITH_ASP_TIMEOUT_SECS must be > 0".to_string());
        }
        Ok(Duration::from_secs(secs))
    } else {
        Ok(Duration::from_secs(60))
    }
}

fn asp_client() -> Result<reqwest::Client, String> {
    let timeout = asp_timeout()?;
    reqwest::Client::builder()
        .timeout(timeout)
        .build()
        .map_err(|e| e.to_string())
}

fn parse_felt_vec(values: &[String]) -> Result<Vec<Felt>, String> {
    values.iter().map(|value| parse_felt_arg(value)).collect()
}

fn parse_felt_arg(value: &str) -> Result<Felt, String> {
    parse_felt(value).map_err(|e| e.to_string())
}

fn parse_u256_arg(value: &str) -> Result<U256, String> {
    let (radix, digits) = if let Some(hex) = value.strip_prefix("0x") {
        (16, hex)
    } else {
        (10, value)
    };
    let parsed = BigUint::from_str_radix(digits, radix).map_err(|e| e.to_string())?;
    let bytes = parsed.to_bytes_be();
    if bytes.len() > 32 {
        return Err("u256 overflow".to_string());
    }
    let mut padded = [0u8; 32];
    padded[32 - bytes.len()..].copy_from_slice(&bytes);
    let high = u128::from_be_bytes(padded[0..16].try_into().unwrap());
    let low = u128::from_be_bytes(padded[16..32].try_into().unwrap());
    Ok(U256::from_words(low, high))
}

fn parse_bytes32(value: &str) -> Result<[u8; 32], String> {
    let hex = value.strip_prefix("0x").unwrap_or(value);
    if hex.len() != 64 {
        return Err("expected 32-byte hex string".to_string());
    }
    let mut out = [0u8; 32];
    for i in 0..32 {
        let start = i * 2;
        let byte = u8::from_str_radix(&hex[start..start + 2], 16)
            .map_err(|e| e.to_string())?;
        out[i] = byte;
    }
    Ok(out)
}

fn bytes32_to_hex(value: &[u8; 32]) -> String {
    let mut out = String::from("0x");
    for byte in value {
        out.push_str(&format!("{:02x}", byte));
    }
    out
}

fn felt_to_hex(value: Felt) -> String {
    format!("0x{:x}", value)
}

fn u256_to_hex(value: &U256) -> String {
    let mut buf = [0u8; 32];
    buf[0..16].copy_from_slice(&value.high().to_be_bytes());
    buf[16..32].copy_from_slice(&value.low().to_be_bytes());
    format!("0x{}", BigUint::from_bytes_be(&buf).to_str_radix(16))
}

fn bytes_to_decimal(value: &[u8; 32]) -> String {
    BigUint::from_bytes_be(value).to_str_radix(10)
}

fn felt_to_decimal(value: Felt) -> String {
    BigUint::from_bytes_be(&value.to_bytes_be()).to_str_radix(10)
}

fn vk_tag(tag: &str) -> Result<u64, String> {
    match tag {
        "DEPOSIT" => Ok(0x4445504f534954),
        "WITHDRAW" => Ok(0x5749544844524157),
        _ => Err("unknown verifier tag".to_string()),
    }
}
