// Garaga verifier router: calls per-proof-type verifiers with opaque calldata and decodes outputs.
use starknet::ContractAddress;
use crate::constants::generated as generated_constants;

// verification key identifiers (domain separation + stable mapping)
const VK_SWAP: felt252 = 'SWAP';
const VK_SWAP_EXACT_OUT: felt252 = 'SWAP_EXACT_OUT';
const VK_LIQ_ADD: felt252 = 'LIQ_ADD';
const VK_LIQ_REMOVE: felt252 = 'LIQ_REMOVE';
const VK_LIQ_CLAIM: felt252 = 'LIQ_CLAIM';
const VK_DEPOSIT: felt252 = 'DEPOSIT';
const VK_WITHDRAW: felt252 = 'WITHDRAW';

// public input lengths (including the leading proof-type tag)
// This implementation currently supports up to 16 initialized-tick crossings per swap proof. Swaps exceeding this must be chunked or use future recursive proofs.
const MAX_SWAP_STEPS: usize = generated_constants::MAX_SWAP_STEPS;
const MAX_INPUT_NOTES: usize = generated_constants::MAX_INPUT_NOTES;
const SWAP_PUBLIC_INPUTS_LEN: usize =
    16 + (MAX_SWAP_STEPS * 6) + (2 * (MAX_INPUT_NOTES - 1));
const LIQUIDITY_BINDING_INPUTS_LEN: usize =
    35 + (4 * (MAX_INPUT_NOTES - 1));
const DEPOSIT_PUBLIC_INPUTS_LEN: usize = 4;
const WITHDRAW_PUBLIC_INPUTS_LEN: usize = 6;
const MAX_TICK_MAGNITUDE_I32: i32 = 88722883;
const MIN_TICK_MINUS_ONE_I32: i32 = -(MAX_TICK_MAGNITUDE_I32 + 1);
const MAX_FEE_GROWTH: u256 = generated_constants::MAX_FEE_GROWTH;
const HIGH_BIT_U128: u128 = 0x80000000000000000000000000000000;
const MAX_U128: u128 = 0xffffffffffffffffffffffffffffffff;
const DEFAULT_VERIFIER_UPDATE_DELAY_SECS: u64 = 86400;

#[derive(Serde, Copy, Drop)]
pub struct SwapPublicOutputs {
    pub merkle_root: felt252,
    pub nullifier: felt252,
    pub sqrt_price_start: u256,
    pub sqrt_price_end: u256,
    pub liquidity_before: u256,
    pub fee: u256,
    pub fee_growth_global_0_before: u256,
    pub fee_growth_global_1_before: u256,
    pub output_commitment: felt252,
    pub change_commitment: felt252,
    pub is_limited: bool,
    pub zero_for_one: bool,
    pub commitment_in: felt252,
    pub token_id_in: felt252,
}

#[derive(Serde, Copy, Drop)]
pub struct LiquidityPublicOutputs {
    pub merkle_root_token0: felt252,
    pub merkle_root_token1: felt252,
    pub merkle_root_position: felt252,
    pub nullifier: felt252,
    pub sqrt_price_start: u256,
    pub tick_start: i32,
    pub tick_lower: i32,
    pub tick_upper: i32,
    pub sqrt_ratio_lower: u256,
    pub sqrt_ratio_upper: u256,
    pub liquidity_before: u256,
    pub liquidity_delta: u256,
    pub fee: u256,
    pub fee_growth_global_0_before: u256,
    pub fee_growth_global_1_before: u256,
    pub fee_growth_global_0: u256,
    pub fee_growth_global_1: u256,
    pub prev_position_commitment: felt252,
    pub new_position_commitment: felt252,
    pub liquidity_commitment: felt252,
    pub fee_growth_inside_0_before: u256,
    pub fee_growth_inside_1_before: u256,
    pub fee_growth_inside_0_after: u256,
    pub fee_growth_inside_1_after: u256,
    pub output_commitment_token0: felt252,
    pub output_commitment_token1: felt252,
    pub protocol_fee_0: u256,
    pub protocol_fee_1: u256,
    pub input_commitment_token0: felt252,
    pub input_commitment_token1: felt252,
    pub nullifier_token0: felt252,
    pub nullifier_token1: felt252,
}

#[derive(Serde, Copy, Drop)]
pub struct DepositPublicOutputs {
    pub commitment: felt252,
    pub amount: u256,
    pub token_id: felt252,
}

#[derive(Serde, Copy, Drop)]
pub struct WithdrawPublicOutputs {
    pub commitment: felt252,
    pub nullifier: felt252,
    pub amount: u256,
    pub token_id: felt252,
    pub recipient: ContractAddress,
}

#[starknet::interface]
pub trait IGaragaVerifier<TContractState> {
    fn verify_groth16_proof_bn254(
        self: @TContractState, calldata: Span<felt252>
    ) -> Option<Span<u256>>;
}

#[starknet::interface]
pub trait IZylithVerifier<TContractState> {
    fn verify_private_swap(self: @TContractState, calldata: Span<felt252>) -> Option<Span<u256>>;
    fn verify_private_swap_exact_out(
        self: @TContractState, calldata: Span<felt252>
    ) -> Option<Span<u256>>;
    fn verify_private_liquidity_add(self: @TContractState, calldata: Span<felt252>) -> Option<Span<u256>>;
    fn verify_private_liquidity_remove(self: @TContractState, calldata: Span<felt252>) -> Option<Span<u256>>;
    fn verify_private_liquidity_claim(self: @TContractState, calldata: Span<felt252>) -> Option<Span<u256>>;
    fn verify_deposit(self: @TContractState, calldata: Span<felt252>) -> Option<DepositPublicOutputs>;
    fn verify_withdraw(self: @TContractState, calldata: Span<felt252>) -> Option<WithdrawPublicOutputs>;

    fn update_swap_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_swap_exact_out_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_liquidity_add_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_liquidity_remove_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_liquidity_claim_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_deposit_verifier(ref self: TContractState, new_address: ContractAddress);
    fn update_withdraw_verifier(ref self: TContractState, new_address: ContractAddress);
    fn set_verifier_update_delay(ref self: TContractState, delay_secs: u64);
}

#[starknet::contract]
pub mod ZylithVerifier {
    use super::{
        ContractAddress, IGaragaVerifierDispatcher, IGaragaVerifierDispatcherTrait, IZylithVerifier,
        DepositPublicOutputs, VK_DEPOSIT, VK_LIQ_ADD, VK_LIQ_CLAIM, VK_LIQ_REMOVE, VK_SWAP,
        VK_SWAP_EXACT_OUT, VK_WITHDRAW, WithdrawPublicOutputs, SWAP_PUBLIC_INPUTS_LEN,
        LIQUIDITY_BINDING_INPUTS_LEN, DEPOSIT_PUBLIC_INPUTS_LEN, WITHDRAW_PUBLIC_INPUTS_LEN,
        MAX_SWAP_STEPS, MAX_INPUT_NOTES, MAX_TICK_MAGNITUDE_I32, MIN_TICK_MINUS_ONE_I32,
        MAX_FEE_GROWTH, HIGH_BIT_U128, MAX_U128, DEFAULT_VERIFIER_UPDATE_DELAY_SECS,
    };
    use core::num::traits::Zero;
    use crate::clmm::components::owned::Owned as owned_component;
    use core::traits::TryInto;
    use starknet::get_block_timestamp;
    use starknet::storage::{Map, StorageMapReadAccess, StorageMapWriteAccess};

    component!(path: owned_component, storage: owned, event: OwnedEvent);
    #[abi(embed_v0)]
    impl Owned = owned_component::OwnedImpl<ContractState>;
    impl OwnableImpl = owned_component::OwnableImpl<ContractState>;

    #[storage]
    struct Storage {
        swap_verifier: ContractAddress,
        swap_exact_out_verifier: ContractAddress,
        liquidity_add_verifier: ContractAddress,
        liquidity_remove_verifier: ContractAddress,
        liquidity_claim_verifier: ContractAddress,
        deposit_verifier: ContractAddress,
        withdraw_verifier: ContractAddress,
        verifier_update_delay: u64,
        pending_verifiers: Map<felt252, ContractAddress>,
        pending_verifier_ready_at: Map<felt252, u64>,
        #[substorage(v0)]
        owned: owned_component::Storage,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    enum Event {
        #[flat]
        OwnedEvent: owned_component::Event,
    }

    #[constructor]
    fn constructor(
        ref self: ContractState,
        owner: ContractAddress,
        swap_verifier: ContractAddress,
        swap_exact_out_verifier: ContractAddress,
        liquidity_add_verifier: ContractAddress,
        liquidity_remove_verifier: ContractAddress,
        liquidity_claim_verifier: ContractAddress,
        deposit_verifier: ContractAddress,
        withdraw_verifier: ContractAddress,
    ) {
        assert(owner.is_non_zero(), 'OWNER_ZERO');
        assert(swap_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(swap_exact_out_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(liquidity_add_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(liquidity_remove_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(liquidity_claim_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(deposit_verifier.is_non_zero(), 'VERIFIER_ZERO');
        assert(withdraw_verifier.is_non_zero(), 'VERIFIER_ZERO');
        self.initialize_owned(owner);
        self.swap_verifier.write(swap_verifier);
        self.swap_exact_out_verifier.write(swap_exact_out_verifier);
        self.liquidity_add_verifier.write(liquidity_add_verifier);
        self.liquidity_remove_verifier.write(liquidity_remove_verifier);
        self.liquidity_claim_verifier.write(liquidity_claim_verifier);
        self.deposit_verifier.write(deposit_verifier);
        self.withdraw_verifier.write(withdraw_verifier);
        self.verifier_update_delay.write(DEFAULT_VERIFIER_UPDATE_DELAY_SECS);
    }

    #[abi(embed_v0)]
    impl VerifierImpl of IZylithVerifier<ContractState> {
        fn verify_private_swap(self: @ContractState, calldata: Span<felt252>) -> Option<Span<u256>> {
            let verified_inputs = self.call_verifier(self.swap_verifier.read(), calldata)?;
            let outputs = self.decode_swap_outputs(verified_inputs)?;
            let tag = tag_from_inputs(verified_inputs);
            assert(tag == VK_SWAP, 'SWAP_TAG_MISMATCH');
            Option::Some(outputs)
        }

        fn verify_private_swap_exact_out(
            self: @ContractState, calldata: Span<felt252>
        ) -> Option<Span<u256>> {
            let verified_inputs =
                self.call_verifier(self.swap_exact_out_verifier.read(), calldata)?;
            let outputs = self.decode_swap_outputs(verified_inputs)?;
            let tag = tag_from_inputs(verified_inputs);
            assert(tag == VK_SWAP_EXACT_OUT, 'SWAP_TAG_MISMATCH');
            Option::Some(outputs)
        }

        fn verify_private_liquidity_add(
            self: @ContractState,
            calldata: Span<felt252>,
        ) -> Option<Span<u256>> {
            let verified_inputs = self.call_verifier(self.liquidity_add_verifier.read(), calldata)?;
            let outputs = self.decode_liquidity_outputs(verified_inputs)?;
            let tag = tag_from_liquidity_inputs(verified_inputs);
            assert(tag == VK_LIQ_ADD, 'LIQ_TAG_MISMATCH');
            let (sign, mag) = signed_u256_to_sign_mag(*verified_inputs.at(12));
            assert(!sign, 'LIQ_DELTA_SIGN');
            assert(mag.is_non_zero(), 'LIQ_DELTA_ZERO');
            Option::Some(outputs)
        }

        fn verify_private_liquidity_remove(
            self: @ContractState,
            calldata: Span<felt252>,
        ) -> Option<Span<u256>> {
            let verified_inputs =
                self.call_verifier(self.liquidity_remove_verifier.read(), calldata)?;
            let outputs = self.decode_liquidity_outputs(verified_inputs)?;
            let tag = tag_from_liquidity_inputs(verified_inputs);
            assert(tag == VK_LIQ_REMOVE, 'LIQ_TAG_MISMATCH');
            let (sign, mag) = signed_u256_to_sign_mag(*verified_inputs.at(12));
            assert(sign, 'LIQ_DELTA_SIGN');
            assert(mag.is_non_zero(), 'LIQ_DELTA_ZERO');
            Option::Some(outputs)
        }

        fn verify_private_liquidity_claim(
            self: @ContractState,
            calldata: Span<felt252>,
        ) -> Option<Span<u256>> {
            let verified_inputs = self.call_verifier(self.liquidity_claim_verifier.read(), calldata)?;
            let outputs = self.decode_liquidity_outputs(verified_inputs)?;
            let tag = tag_from_liquidity_inputs(verified_inputs);
            assert(tag == VK_LIQ_CLAIM, 'LIQ_TAG_MISMATCH');
            let (sign, mag) = signed_u256_to_sign_mag(*verified_inputs.at(12));
            assert(!sign, 'LIQ_DELTA_SIGN');
            assert(mag == 0, 'LIQ_DELTA_NONZERO');
            Option::Some(outputs)
        }

        fn verify_deposit(self: @ContractState, calldata: Span<felt252>) -> Option<DepositPublicOutputs> {
            let verified_inputs = self.call_verifier(self.deposit_verifier.read(), calldata)?;
            self.decode_deposit_outputs(verified_inputs)
        }

        fn verify_withdraw(self: @ContractState, calldata: Span<felt252>) -> Option<WithdrawPublicOutputs> {
            let verified_inputs = self.call_verifier(self.withdraw_verifier.read(), calldata)?;
            self.decode_withdraw_outputs(verified_inputs)
        }

        fn update_swap_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            // todo(post-mvp): re-enable with timelock + multisig governance.
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_swap_exact_out_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_liquidity_add_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_liquidity_remove_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_liquidity_claim_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_deposit_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn update_withdraw_verifier(ref self: ContractState, new_address: ContractAddress) {
            let _ = new_address;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }

        fn set_verifier_update_delay(ref self: ContractState, delay_secs: u64) {
            let _ = delay_secs;
            assert(false, 'VERIFIER_UPDATES_DISABLED');
        }
    }

    fn tag_from_inputs(inputs: Span<u256>) -> felt252 {
        let tag_u256 = *inputs.at(0);
        assert(tag_u256.high == 0, 'TAG_RANGE');
        tag_u256.low.into()
    }

    fn tag_from_liquidity_inputs(inputs: Span<u256>) -> felt252 {
        let tag_u256 = *inputs.at(0);
        assert(tag_u256.high == 0, 'TAG_RANGE');
        tag_u256.low.into()
    }

    fn update_verifier_with_delay(
        ref self: ContractState, kind: felt252, new_address: ContractAddress
    ) {
        self.require_owner();
        assert(new_address.is_non_zero(), 'VERIFIER_ZERO');
        let delay = self.verifier_update_delay.read();
        if delay == 0 {
            set_verifier(ref self, kind, new_address);
            return ();
        }
        let now = get_block_timestamp();
        let pending = self.pending_verifiers.read(kind);
        let ready_at = self.pending_verifier_ready_at.read(kind);
        if (pending == new_address) & (ready_at != 0) & (now >= ready_at) {
            set_verifier(ref self, kind, new_address);
            self.pending_verifier_ready_at.write(kind, 0);
        } else {
            let scheduled_at = now + delay;
            assert(scheduled_at >= now, 'TIME_OVERFLOW');
            self.pending_verifiers.write(kind, new_address);
            self.pending_verifier_ready_at.write(kind, scheduled_at);
        }
    }

    fn set_verifier(ref self: ContractState, kind: felt252, address: ContractAddress) {
        if kind == VK_SWAP {
            self.swap_verifier.write(address);
        } else if kind == VK_SWAP_EXACT_OUT {
            self.swap_exact_out_verifier.write(address);
        } else if kind == VK_LIQ_ADD {
            self.liquidity_add_verifier.write(address);
        } else if kind == VK_LIQ_REMOVE {
            self.liquidity_remove_verifier.write(address);
        } else if kind == VK_LIQ_CLAIM {
            self.liquidity_claim_verifier.write(address);
        } else if kind == VK_DEPOSIT {
            self.deposit_verifier.write(address);
        } else if kind == VK_WITHDRAW {
            self.withdraw_verifier.write(address);
        } else {
            assert(false, 'UNKNOWN_VERIFIER_KIND');
        }
    }

    #[generate_trait]
    impl VerifierHelpersImpl of VerifierHelpers {
        fn call_verifier(
            self: @ContractState,
            verifier: ContractAddress,
            calldata: Span<felt252>,
        ) -> Option<Span<u256>> {
            IGaragaVerifierDispatcher { contract_address: verifier }
                .verify_groth16_proof_bn254(calldata)
        }

        fn decode_swap_outputs(self: @ContractState, public_inputs: Span<u256>) -> Option<Span<u256>> {
            if public_inputs.len() != SWAP_PUBLIC_INPUTS_LEN {
                return Option::None;
            }
            // public input order (including domain tag):
            // [0] proof type tag (VK_SWAP or VK_SWAP_EXACT_OUT)
            // [1] merkle_root
            // [2] nullifier
            // [3] sqrt_price_start
            // [4] sqrt_price_end
            // [5] liquidity_before
            // [6] fee
            // [7] fee_growth_global_0_before
            // [8] fee_growth_global_1_before
            // [9] output_commitment
            // [10] change_commitment
            // [11] is_limited
            // [12] zero_for_one
            // [13..] step arrays (6 * MAX_SWAP_STEPS)
            // [commitment_in_index] commitment_in (note 0)
            // [token_id_index] token_id_in
            // [note_count_index] note_count
            // [nullifier_extra_start..] nullifier_extra (notes 1..)
            // [commitment_extra_start..] commitment_extra (notes 1..)
            let mut idx: usize = 0;
            let tag: felt252 = assert_high_zero(*public_inputs.at(idx)).try_into().expect('TAG_RANGE');
            if (tag != VK_SWAP) & (tag != VK_SWAP_EXACT_OUT) {
                return Option::None;
            }
            idx += 1;
            let _merkle_root: felt252 = (*public_inputs.at(idx)).try_into().expect('ROOT_RANGE');
            idx += 1;
            let _nullifier: felt252 = (*public_inputs.at(idx)).try_into().expect('NULLIFIER_RANGE');
            idx += 1;
            // u256 fields are reconstructed from low/high limbs, do not truncate to low
            let _sqrt_price_start: u256 = *public_inputs.at(idx);
            idx += 1;
            let _sqrt_price_end: u256 = *public_inputs.at(idx);
            idx += 1;
            let _liquidity_before: u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let _fee: u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let _fee_growth_global_0_before: u256 = *public_inputs.at(idx);
            idx += 1;
            let _fee_growth_global_1_before: u256 = *public_inputs.at(idx);
            idx += 1;
            assert_fee_growth_max(_fee_growth_global_0_before);
            assert_fee_growth_max(_fee_growth_global_1_before);
            let _output_commitment: felt252 =
                (*public_inputs.at(idx)).try_into().expect('OUTPUT_RANGE');
            idx += 1;
            let _change_commitment: felt252 =
                (*public_inputs.at(idx)).try_into().expect('CHANGE_RANGE');
            idx += 1;
            let is_limited: felt252 =
                assert_high_zero(*public_inputs.at(idx)).try_into().expect('LIMIT_RANGE');
            assert((is_limited == 0) | (is_limited == 1), 'LIMIT_BOOL');
            idx += 1;
            let zero_for_one: felt252 =
                assert_high_zero(*public_inputs.at(idx)).try_into().expect('ZFO_RANGE');
            assert((zero_for_one == 0) | (zero_for_one == 1), 'ZFO_BOOL');
            let step_fee_growth_0_start = 13 + (MAX_SWAP_STEPS * 4);
            let step_fee_growth_1_start = step_fee_growth_0_start + MAX_SWAP_STEPS;
            let mut step_idx: usize = 0;
            while step_idx < MAX_SWAP_STEPS {
                let fee0 = *public_inputs.at(step_fee_growth_0_start + step_idx);
                let fee1 = *public_inputs.at(step_fee_growth_1_start + step_idx);
                assert_fee_growth_max(fee0);
                assert_fee_growth_max(fee1);
                step_idx += 1;
            }
            let commitment_in_index: usize = 13 + (MAX_SWAP_STEPS * 6);
            let token_id_index: usize = commitment_in_index + 1;
            let note_count_index: usize = token_id_index + 1;
            let nullifier_extra_start: usize = note_count_index + 1;
            let commitment_extra_start: usize = nullifier_extra_start + (MAX_INPUT_NOTES - 1);

            let _commitment_in: felt252 =
                (*public_inputs.at(commitment_in_index)).try_into().expect('COMMITMENT_IN_RANGE');
            let _token_id_in: felt252 =
                assert_high_zero(*public_inputs.at(token_id_index))
                    .try_into()
                    .expect('TOKEN_ID_RANGE');
            let note_count_u256 = assert_high_zero(*public_inputs.at(note_count_index));
            let note_count_u128: u128 = note_count_u256.low;
            let note_count: usize = note_count_u128.try_into().expect('NOTE_COUNT_RANGE');
            assert(note_count > 0, 'NOTE_COUNT_ZERO');
            assert(note_count <= MAX_INPUT_NOTES, 'NOTE_COUNT_MAX');

            let mut extra_idx: usize = 0;
            while extra_idx < (MAX_INPUT_NOTES - 1) {
                let nullifier_extra: felt252 =
                    (*public_inputs.at(nullifier_extra_start + extra_idx))
                        .try_into()
                        .expect('NULLIFIER_RANGE');
                let commitment_extra: felt252 =
                    (*public_inputs.at(commitment_extra_start + extra_idx))
                        .try_into()
                        .expect('COMMITMENT_RANGE');
                if (extra_idx + 1) >= note_count {
                    assert(nullifier_extra == 0, 'NULLIFIER_EXTRA_NONZERO');
                    assert(commitment_extra == 0, 'COMMITMENT_EXTRA_NONZERO');
                }
                extra_idx += 1;
            }
            Option::Some(public_inputs)
        }

        fn decode_liquidity_outputs(
            self: @ContractState, public_inputs: Span<u256>
        ) -> Option<Span<u256>> {
            // public input order (including domain tag):
            // [0] proof type tag (VK_LIQ_ADD or VK_LIQ_REMOVE)
            // [1] merkle_root_token0
            // [2] merkle_root_token1
            // [3] merkle_root_position
            // [4] nullifier
            // [5] sqrt_price_start
            // [6] tick_start
            // [7] tick_lower
            // [8] tick_upper
            // [9] sqrt_ratio_lower
            // [10] sqrt_ratio_upper
            // [11] liquidity_before
            // [12] liquidity_delta
            // [13] fee
            // [14] fee_growth_global_0_before
            // [15] fee_growth_global_1_before
            // [16] fee_growth_global_0
            // [17] fee_growth_global_1
            // [18] prev_position_commitment
            // [19] new_position_commitment
            // [20] liquidity_commitment
            // [21] fee_growth_inside_0_before
            // [22] fee_growth_inside_1_before
            // [23] fee_growth_inside_0_after
            // [24] fee_growth_inside_1_after
            // [25] input_commitment_token0
            // [26] input_commitment_token1
            // [27] nullifier_token0
            // [28] nullifier_token1
            // [29] output_commitment_token0
            // [30] output_commitment_token1
            // [31] protocol_fee_0
            // [32] protocol_fee_1
            // [33] token0_note_count
            // [34] token1_note_count
            // [35..] nullifier_token0_extra (notes 1..)
            // [nullifier_token1_start..] nullifier_token1_extra (notes 1..)
            // [commitment_token0_start..] input_commitment_token0_extra (notes 1..)
            // [commitment_token1_start..] input_commitment_token1_extra (notes 1..)
            if public_inputs.len() != LIQUIDITY_BINDING_INPUTS_LEN {
                return Option::None;
            }
            let mut idx: usize = 0;
            let tag: felt252 = assert_high_zero(*public_inputs.at(idx)).try_into().expect('TAG_RANGE');
            if (tag != VK_LIQ_ADD) & (tag != VK_LIQ_REMOVE) & (tag != VK_LIQ_CLAIM) {
                return Option::None;
            }
            idx += 1;
            let _merkle_root_token0: felt252 =
                (*public_inputs.at(idx)).try_into().expect('ROOT0_RANGE');
            idx += 1;
            let _merkle_root_token1: felt252 =
                (*public_inputs.at(idx)).try_into().expect('ROOT1_RANGE');
            idx += 1;
            let _merkle_root_position: felt252 =
                (*public_inputs.at(idx)).try_into().expect('ROOT_POSITION_RANGE');
            idx += 1;
            let _nullifier: felt252 = (*public_inputs.at(idx)).try_into().expect('NULLIFIER_RANGE');
            idx += 1;
            let _sqrt_price_start: u256 = *public_inputs.at(idx);
            idx += 1;
            let tick_start: i32 = decode_i32_signed(*public_inputs.at(idx)).expect('TICK_START_RANGE');
            idx += 1;
            let tick_lower: i32 = decode_i32_signed(*public_inputs.at(idx)).expect('TICK_LOWER_RANGE');
            idx += 1;
            let tick_upper: i32 = decode_i32_signed(*public_inputs.at(idx)).expect('TICK_UPPER_RANGE');
            idx += 1;
            // allow min_tick - 1 for the current tick
            assert(tick_start >= MIN_TICK_MINUS_ONE_I32, 'TICK_START_MIN');
            assert(tick_start <= MAX_TICK_MAGNITUDE_I32, 'TICK_START_MAX');
            assert(tick_lower >= -MAX_TICK_MAGNITUDE_I32, 'TICK_LOWER_MIN');
            assert(tick_lower <= MAX_TICK_MAGNITUDE_I32, 'TICK_LOWER_MAX');
            assert(tick_upper >= -MAX_TICK_MAGNITUDE_I32, 'TICK_UPPER_MIN');
            assert(tick_upper <= MAX_TICK_MAGNITUDE_I32, 'TICK_UPPER_MAX');
            let _sqrt_ratio_lower: u256 = *public_inputs.at(idx);
            idx += 1;
            let _sqrt_ratio_upper: u256 = *public_inputs.at(idx);
            idx += 1;
            let _liquidity_before: u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let liquidity_delta: u256 = *public_inputs.at(idx);
            let _ = signed_u256_to_sign_mag(liquidity_delta);
            idx += 1;
            let _fee: u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;

            let fee_growth_global_0_before: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_global_1_before: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_global_0: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_global_1: u256 = *public_inputs.at(idx);
            idx += 1;
            assert_fee_growth_max(fee_growth_global_0_before);
            assert_fee_growth_max(fee_growth_global_1_before);
            assert_fee_growth_max(fee_growth_global_0);
            assert_fee_growth_max(fee_growth_global_1);

            let _prev_position_commitment: felt252 =
                (*public_inputs.at(idx)).try_into().expect('POS_PREV_RANGE');
            idx += 1;
            let _new_position_commitment: felt252 =
                (*public_inputs.at(idx)).try_into().expect('POS_NEW_RANGE');
            idx += 1;
            let _liquidity_commitment: felt252 =
                (*public_inputs.at(idx)).try_into().expect('LIQ_COMMITMENT_RANGE');
            idx += 1;

            let fee_growth_inside_0_before: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_inside_1_before: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_inside_0_after: u256 = *public_inputs.at(idx);
            idx += 1;
            let fee_growth_inside_1_after: u256 = *public_inputs.at(idx);
            idx += 1;
            assert_fee_growth_max(fee_growth_inside_0_before);
            assert_fee_growth_max(fee_growth_inside_1_before);
            assert_fee_growth_max(fee_growth_inside_0_after);
            assert_fee_growth_max(fee_growth_inside_1_after);

            let _input_commitment_token0: felt252 =
                (*public_inputs.at(idx)).try_into().expect('IN0_RANGE');
            idx += 1;
            let _input_commitment_token1: felt252 =
                (*public_inputs.at(idx)).try_into().expect('IN1_RANGE');
            idx += 1;
            let _nullifier_token0: felt252 =
                (*public_inputs.at(idx)).try_into().expect('NULL0_RANGE');
            idx += 1;
            let _nullifier_token1: felt252 =
                (*public_inputs.at(idx)).try_into().expect('NULL1_RANGE');
            idx += 1;
            let _output_commitment_token0: felt252 =
                (*public_inputs.at(idx)).try_into().expect('OUT0_RANGE');
            idx += 1;
            let _output_commitment_token1: felt252 =
                (*public_inputs.at(idx)).try_into().expect('OUT1_RANGE');
            idx += 1;
            let _protocol_fee_0 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let _protocol_fee_1 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;

            let note_count0_u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let note_count1_u256 = assert_high_zero(*public_inputs.at(idx));
            idx += 1;
            let note_count0: usize =
                note_count0_u256.low.try_into().expect('NOTE_COUNT0_RANGE');
            let note_count1: usize =
                note_count1_u256.low.try_into().expect('NOTE_COUNT1_RANGE');
            assert(note_count0 <= MAX_INPUT_NOTES, 'NOTE_COUNT0_MAX');
            assert(note_count1 <= MAX_INPUT_NOTES, 'NOTE_COUNT1_MAX');
            if note_count0 == 0 {
                assert(_input_commitment_token0 == 0, 'IN0_NONZERO');
                assert(_nullifier_token0 == 0, 'NULL0_NONZERO');
            } else {
                assert(_input_commitment_token0 != 0, 'IN0_ZERO');
                assert(_nullifier_token0 != 0, 'NULL0_ZERO');
            }
            if note_count1 == 0 {
                assert(_input_commitment_token1 == 0, 'IN1_NONZERO');
                assert(_nullifier_token1 == 0, 'NULL1_NONZERO');
            } else {
                assert(_input_commitment_token1 != 0, 'IN1_ZERO');
                assert(_nullifier_token1 != 0, 'NULL1_ZERO');
            }

            let nullifier_token1_start: usize = idx + (MAX_INPUT_NOTES - 1);
            let commitment_token0_start: usize = nullifier_token1_start + (MAX_INPUT_NOTES - 1);
            let commitment_token1_start: usize = commitment_token0_start + (MAX_INPUT_NOTES - 1);

            let mut extra_idx: usize = 0;
            while extra_idx < (MAX_INPUT_NOTES - 1) {
                let _null0: felt252 = (*public_inputs.at(idx + extra_idx))
                    .try_into()
                    .expect('NULL0_RANGE');
                let _null1: felt252 = (*public_inputs.at(nullifier_token1_start + extra_idx))
                    .try_into()
                    .expect('NULL1_RANGE');
                let _com0: felt252 = (*public_inputs.at(commitment_token0_start + extra_idx))
                    .try_into()
                    .expect('IN0_RANGE');
                let _com1: felt252 = (*public_inputs.at(commitment_token1_start + extra_idx))
                    .try_into()
                    .expect('IN1_RANGE');
                if (extra_idx + 1) >= note_count0 {
                    assert(_null0 == 0, 'NULL0_EXTRA_NONZERO');
                    assert(_com0 == 0, 'IN0_EXTRA_NONZERO');
                }
                if (extra_idx + 1) >= note_count1 {
                    assert(_null1 == 0, 'NULL1_EXTRA_NONZERO');
                    assert(_com1 == 0, 'IN1_EXTRA_NONZERO');
                }
                extra_idx += 1;
            }

            Option::Some(public_inputs)
        }

        fn decode_deposit_outputs(
            self: @ContractState, public_inputs: Span<u256>
        ) -> Option<DepositPublicOutputs> {
            // public input order:
            // [0] proof type tag (VK_DEPOSIT)
            // [1] commitment
            // [2] amount
            // [3] token_id
            if public_inputs.len() != DEPOSIT_PUBLIC_INPUTS_LEN {
                return Option::None;
            }
            let tag: felt252 = assert_high_zero(*public_inputs.at(0)).try_into().expect('TAG_RANGE');
            if tag != VK_DEPOSIT {
                return Option::None;
            }
            Option::Some(
                DepositPublicOutputs {
                    commitment: (*public_inputs.at(1)).try_into().expect('COMMITMENT_RANGE'),
                    amount: assert_high_zero(*public_inputs.at(2)),
                    token_id: assert_high_zero(*public_inputs.at(3)).try_into().expect('TOKEN_ID_RANGE'),
                },
            )
        }

        fn decode_withdraw_outputs(
            self: @ContractState, public_inputs: Span<u256>
        ) -> Option<WithdrawPublicOutputs> {
            // public input order:
            // [0] proof type tag (VK_WITHDRAW)
            // [1] commitment
            // [2] nullifier
            // [3] amount
            // [4] token_id
            // [5] recipient
            if public_inputs.len() != WITHDRAW_PUBLIC_INPUTS_LEN {
                return Option::None;
            }
            let tag: felt252 = assert_high_zero(*public_inputs.at(0)).try_into().expect('TAG_RANGE');
            if tag != VK_WITHDRAW {
                return Option::None;
            }
            let recipient_felt: felt252 =
                (*public_inputs.at(5)).try_into().expect('RECIPIENT_RANGE');
            let recipient: ContractAddress = recipient_felt.try_into().expect('RECIPIENT_ADDR');
            Option::Some(
                WithdrawPublicOutputs {
                    commitment: (*public_inputs.at(1)).try_into().expect('COMMITMENT_RANGE'),
                    nullifier: (*public_inputs.at(2)).try_into().expect('NULLIFIER_RANGE'),
                    amount: assert_high_zero(*public_inputs.at(3)),
                    token_id: assert_high_zero(*public_inputs.at(4)).try_into().expect('TOKEN_ID_RANGE'),
                    recipient,
                },
            )
        }
    }

    fn assert_high_zero(input: u256) -> u256 {
        assert(input.high == 0, 'UNEXPECTED_U256_HIGH');
        input
    }

    fn assert_fee_growth_max(value: u256) {
        assert(value <= MAX_FEE_GROWTH, 'FEE_GROWTH_MAX');
    }

    fn signed_u256_to_sign_mag(value: u256) -> (bool, u128) {
        assert(value.high == 0, 'LIQ_DELTA_HIGH');
        if value.low < HIGH_BIT_U128 {
            (false, value.low)
        } else {
            let mag = if value.low == HIGH_BIT_U128 {
                HIGH_BIT_U128
            } else {
                (MAX_U128 - value.low) + 1
            };
            (true, mag)
        }
    }

    // decode a signed i128 from a sign-extended two's complement u256 (supports i128::MIN)
    fn decode_i128_signed(input: u256) -> Option<i128> {
        if input.high != 0 {
            return Option::None;
        }
        let sign_bit_set = input.low >= HIGH_BIT_U128;
        if !sign_bit_set {
            match input.low.try_into() {
                Option::Some(v) => Option::Some(v),
                Option::None => Option::None,
            }
        } else if input.low == HIGH_BIT_U128 {
            // i128::MIN
            Option::Some(-170141183460469231731687303715884105728_i128)
        } else {
            let twos_mag: u128 = (MAX_U128 - input.low) + 1; // 2^128 - low
            match twos_mag.try_into() {
                Option::Some(mag_i128) => Option::Some(-mag_i128),
                Option::None => Option::None,
            }
        }
    }

    // decode a signed i32 using the i128 decoder and range check
    fn decode_i32_signed(input: u256) -> Option<i32> {
        match decode_i128_signed(input) {
            Option::Some(value) => {
                // explicit bounds to avoid overflow on cast
                if (value < (-2147483648_i128)) || (value > 2147483647_i128) {
                    Option::None
                } else {
                    Option::Some(value.try_into().unwrap())
                }
            },
            Option::None => Option::None,
        }
    }
}
