# Zylith

## What is Zylith
Zylith is a proof-driven, shielded concentrated liquidity market maker on Starknet. It preserves a public CLMM state machine while hiding ownership of notes and positions.

## Motivation
Public AMMs provide deterministic pricing and composability but expose per-user balances and positions. A shielded AMM should preserve the public price process while minimizing disclosure of ownership. Zylith separates ownership privacy (off-chain notes + ZK proofs) from on-chain pool state (public).

## High-level system overview
Zylith uses Groth16 proofs generated off-chain to prove correctness of private inputs and CLMM transitions. The pool contract verifies proofs and applies the resulting state deltas to a public CLMM core via an adapter. The chain verifies membership and nullifier freshness, it does not recompute swap math.

## Core components

### Shielded Notes
- `ShieldedNotes` maintains commitment trees for token0, token1, and positions.
- Commitments are Poseidon(Poseidon(secret, nullifier), amount) over BN254.
- Nullifiers are recorded on-chain to prevent double spends.
- Merkle roots are stored on-chain, full trees are maintained off-chain.
- Membership verification uses on-chain Starknet Poseidon and historical root windows.

### CLMM Pool State
- `ZylithPool` is the entrypoint for swaps and liquidity operations.
- `PoolAdapter` applies verified state transitions to the CLMM core.
- The CLMM core tracks sqrt price (Q128.128), tick, active liquidity, fee growth, and tick bitmap similar to Ekubo.
- Pool state is public, correctness derives from proof-verified transitions.
- Implementation provenance: only the CLMM core and math layer under `contracts/clmm/` are adapted from Ekubo.

### Proof System
- Groth16 over BN254, verified on Starknet via Garaga.
- Circuits:
  - `private_deposit` and `private_withdraw`.
  - `private_swap` and `private_swap_exact_out`.
  - `private_liquidity` for add/remove/claim.
- Circuits prove swap and liquidity math off-chain; the chain does not recompute swap math.

## Privacy model
Private:
- Ownership of token notes and position notes.
- Note secrets and nullifier seeds.

Public:
- Commitments, nullifiers, and Merkle roots.
- Pool state: sqrt price, tick, liquidity, fee growth, protocol fee accounting.
- Deposit and withdraw amounts and recipients.
- Tick bounds for positions (MVP).

Limitations (MVP):
- Amount privacy is not provided. Swap and liquidity amounts are public or derivable from public state transitions.
- Position ranges are public.
- Pool initialization parameters are public.

## End-to-end flows

### Deposit
1) User constructs a token note off-chain.
2) Prover generates a Groth16 proof (`private_deposit`) of note correctness.
3) `ShieldedNotes` verifies the proof, inserts the commitment, transfers ERC20 into custody, and updates the Merkle root.

### Swap (exact-in / exact-out)
1) User fetches membership paths from the ASP.
2) Prover generates a swap proof (`private_swap` or `private_swap_exact_out`).
3) `ZylithPool` verifies the proof, checks:
   - membership path validity against on-chain roots,
   - nullifier freshness,
   - pool state consistency for the verified transition.
4) `PoolAdapter` applies swap deltas to the CLMM core.
5) Output commitments are inserted into `ShieldedNotes`.

### Liquidity add / remove / claim
1) User proves liquidity math in `private_liquidity`.
2) `ZylithPool` verifies the proof and applies liquidity deltas via `PoolAdapter`.
3) Position and change commitments are inserted into `ShieldedNotes`.

### Withdraw
1) User proves note opening and nullifier in `private_withdraw`.
2) `ShieldedNotes` verifies membership on-chain, marks the nullifier, and transfers ERC20 to the recipient.

## Off-chain infrastructure and trust assumptions

### Prover backend
- Generates witnesses and proofs with `snarkjs`.
- Converts proofs to Starknet calldata via `garaga`.
- Trust: correctness depends on circuit and verifier; the backend is not trusted for correctness but is required for liveness.

### ASP (Association Set Provider)
- Reconstructs Merkle trees from on-chain events.
- Serves membership paths and insertion paths.
- Trust: integrity is enforced on-chain by root verification. Incorrect paths cause proof or on-chain verification to fail; ASP is a liveness dependency.

### Frontend vault
- Stores encrypted notes in browser IndexedDB.
- Vault key is derived from wallet signatures; losing the key loses notes.
- Trust: user must back up notes; the protocol cannot recover them.

## Security considerations
- Circuit correctness is a primary assumption; bugs can create invalid but verifiable proofs.
- Groth16 requires a trusted setup; if toxic waste is compromised, an attacker can forge proofs for false statements and bypass circuit constraints.
- Garaga and on-chain verifiers are assumed correct.
- Vault storage is a single point of user recovery; losing the vault key loses access to funds.

## Repository structure
- `contracts/`: Cairo contracts for pool, notes, adapter, verifier, interfaces.
- `contracts/clmm/`: Ekubo-derived CLMM core and math modules.
- `circuits/`: Circom circuits and constants.
- `rust/`: prover, backend API, ASP indexer, and client helpers.
- `frontend/`: React UI and encrypted vault.
- `scripts/`: deployment and setup utilities.
- `docs/`: runbook and security model references.

## Status & disclaimers
Zylith is an MVP. The system is unaudited and experimental. Expect breaking changes and incomplete privacy properties as described above.

## License
The repository is licensed under AGPL-3.0, except for `contracts/clmm/` which is licensed under the Ekubo DAO Shared Revenue License 1.0 (`ekubo-license-v1.eth`).