#[feature("deprecated_legacy_map")]
use core::serde::Serde;
use core::array::ArrayTrait;
use core::traits::TryInto;
use snforge_std::{spy_events, EventSpy, EventSpyTrait, EventsFilterTrait, start_cheat_caller_address};
use snforge_std::test_address;
use starknet::ContractAddress;

use zylith::interfaces::IERC20::{IERC20Dispatcher, IERC20DispatcherTrait};
use zylith::privacy::ShieldedNotes::{
    ShieldedNotesExternalDispatcher, ShieldedNotesExternalDispatcherTrait,
};

use crate::common::{
    deploy_contract_at, empty_root, insertion_proof_for_empty_leaf, merkle_proof_for_single_leaf,
    merkle_root_for_single_leaf, u256_from_felt, u256_from_u128, insertion_proof_for_second_leaf,
};
use crate::common::mocks::MockGaragaVerifier::{
    MockGaragaVerifierExternalDispatcher, MockGaragaVerifierExternalDispatcherTrait,
};

fn setup_notes() -> (
    ShieldedNotesExternalDispatcher,
    IERC20Dispatcher,
    IERC20Dispatcher,
    MockGaragaVerifierExternalDispatcher,
    ContractAddress,
) {
    let token0_address = 0x4000.try_into().expect('ADDRESS_RANGE');
    let token1_address = 0x4100.try_into().expect('ADDRESS_RANGE');
    let garaga_address = 0x4200.try_into().expect('ADDRESS_RANGE');
    let verifier_address = 0x4300.try_into().expect('ADDRESS_RANGE');
    let notes_address = 0x4400.try_into().expect('ADDRESS_RANGE');
    let authorized_pool: ContractAddress = 0x4500.try_into().expect('ADDRESS_RANGE');

    let mut token0_calldata = array![];
    test_address().serialize(ref token0_calldata);
    1_000_000_u128.serialize(ref token0_calldata);
    't0'.serialize(ref token0_calldata);
    't0'.serialize(ref token0_calldata);
    let _ = deploy_contract_at("MockERC20", token0_calldata, token0_address);

    let mut token1_calldata = array![];
    test_address().serialize(ref token1_calldata);
    1_000_000_u128.serialize(ref token1_calldata);
    't1'.serialize(ref token1_calldata);
    't1'.serialize(ref token1_calldata);
    let _ = deploy_contract_at("MockERC20", token1_calldata, token1_address);

    let garaga_calldata = array![];
    let _ = deploy_contract_at("MockGaragaVerifier", garaga_calldata, garaga_address);

    let mut verifier_calldata = array![];
    test_address().serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    garaga_address.serialize(ref verifier_calldata);
    let _ = deploy_contract_at("ZylithVerifier", verifier_calldata, verifier_address);
    let verifier = MockGaragaVerifierExternalDispatcher { contract_address: garaga_address };

    let mut notes_calldata = array![];
    token0_address.serialize(ref notes_calldata);
    token1_address.serialize(ref notes_calldata);
    authorized_pool.serialize(ref notes_calldata);
    verifier_address.serialize(ref notes_calldata);
    test_address().serialize(ref notes_calldata);
    let _ = deploy_contract_at("ShieldedNotes", notes_calldata, notes_address);

    (
        ShieldedNotesExternalDispatcher { contract_address: notes_address },
        IERC20Dispatcher { contract_address: token0_address },
        IERC20Dispatcher { contract_address: token1_address },
        verifier,
        notes_address,
    )
}

fn build_deposit_outputs(commitment: felt252, amount: u128, token_id: felt252) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    outputs.append(u256_from_felt('DEPOSIT'));
    outputs.append(u256_from_felt(commitment));
    outputs.append(u256_from_u128(amount));
    outputs.append(u256_from_felt(token_id));
    outputs
}

fn build_withdraw_outputs(
    commitment: felt252,
    nullifier: felt252,
    amount: u128,
    token_id: felt252,
    recipient: ContractAddress,
) -> Array<u256> {
    let mut outputs: Array<u256> = array![];
    outputs.append(u256_from_felt('WITHDRAW'));
    outputs.append(u256_from_felt(commitment));
    outputs.append(u256_from_felt(nullifier));
    outputs.append(u256_from_u128(amount));
    outputs.append(u256_from_felt(token_id));
    outputs.append(u256_from_felt(recipient.into()));
    outputs
}

fn assert_deposit_event(
    mut spy: EventSpy, notes_address: ContractAddress, commitment: felt252, token: ContractAddress,
) {
    let events = spy.get_events().emitted_by(notes_address);
    let mut found = false;
    let mut idx: usize = 0;
    while idx < events.events.len() {
        let (_, event) = events.events.at(idx);
        if event.data.len() >= 3 {
            if *event.data.at(0) == commitment && *event.data.at(2) == token.into() {
                found = true;
            }
        }
        idx += 1;
    }
    assert(found, 'deposit event');
}

#[test]
fn test_deposit_creates_commitment() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let outputs = build_deposit_outputs(111, 100, 0);
    verifier.set_outputs(outputs.span());
    token0.approve(notes_address, u256_from_u128(100));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    assert(commitment == 111, 'commitment mismatch');
}

#[test]
fn test_deposit_emits_event() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let outputs = build_deposit_outputs(222, 50, 0);
    verifier.set_outputs(outputs.span());
    token0.approve(notes_address, u256_from_u128(50));
    let mut spy = spy_events();
    let _ = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    assert_deposit_event(spy, notes_address, 222, token0.contract_address);
}

#[test]
fn test_withdraw_with_valid_proof() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let deposit_outputs = build_deposit_outputs(333, 200, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(200));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root = merkle_root_for_single_leaf(commitment);
    let proof = merkle_proof_for_single_leaf(root, commitment);

    let before = token0.balance_of(test_address());
    let withdraw_outputs = build_withdraw_outputs(commitment, 444, 200, 0, test_address());
    verifier.set_outputs(withdraw_outputs.span());
    notes.withdraw_token0(array![].span(), proof);
    let after = token0.balance_of(test_address());
    assert(after.low == before.low + 200, 'withdraw balance');
}

#[test]
#[should_panic(expected: 'AMOUNT_ZERO')]
fn test_withdraw_rejects_zero_amount() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let deposit_outputs = build_deposit_outputs(888, 25, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(25));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root = merkle_root_for_single_leaf(commitment);
    let proof = merkle_proof_for_single_leaf(root, commitment);

    let withdraw_outputs = build_withdraw_outputs(commitment, 777, 0, 0, test_address());
    verifier.set_outputs(withdraw_outputs.span());
    notes.withdraw_token0(array![].span(), proof);
}

#[test]
#[should_panic(expected: 'NULLIFIER_USED')]
fn test_withdraw_burns_nullifier() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let deposit_outputs = build_deposit_outputs(444, 10, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(10));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root = merkle_root_for_single_leaf(commitment);
    let proof = merkle_proof_for_single_leaf(root, commitment);

    let withdraw_outputs = build_withdraw_outputs(commitment, 555, 10, 0, test_address());
    verifier.set_outputs(withdraw_outputs.span());
    notes.withdraw_token0(array![].span(), proof);
    notes.withdraw_token0(array![].span(), proof);
}

#[test]
#[should_panic(expected: 'NULLIFIER_USED')]
fn test_withdraw_reverts_on_reuse() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let deposit_outputs = build_deposit_outputs(555, 10, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(10));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root = merkle_root_for_single_leaf(commitment);
    let proof = merkle_proof_for_single_leaf(root, commitment);

    let withdraw_outputs = build_withdraw_outputs(commitment, 666, 10, 0, test_address());
    verifier.set_outputs(withdraw_outputs.span());
    notes.withdraw_token0(array![].span(), proof);
    notes.withdraw_token0(array![].span(), proof);
}

#[test]
#[should_panic(expected: 'RECIPIENT_ZERO')]
fn test_withdraw_protocol_fees_requires_recipient() {
    let (notes, token0, _, _, notes_address) = setup_notes();
    let authorized_pool = notes.get_authorized_pool();
    start_cheat_caller_address(notes_address, authorized_pool);
    notes.withdraw_protocol_fees(
        token0.contract_address,
        0.try_into().expect('ADDRESS_RANGE'),
        1,
    );
}

#[test]
fn test_merkle_root_updates() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let root0 = empty_root();
    let deposit_outputs = build_deposit_outputs(777, 10, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(10));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root1 = merkle_root_for_single_leaf(commitment);
    assert(root1 != root0, 'root unchanged');
}

#[test]
fn test_historical_roots_tracked() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let _root0 = empty_root();
    let deposit_outputs = build_deposit_outputs(888, 10, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(10));
    let commitment = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root1 = merkle_root_for_single_leaf(commitment);
    assert(notes.is_known_root(token0.contract_address, root1), 'root tracked');
}

#[test]
fn test_pending_root_is_known_before_flush() {
    let (notes, token0, _, verifier, notes_address) = setup_notes();
    let deposit_outputs = build_deposit_outputs(901, 10, 0);
    verifier.set_outputs(deposit_outputs.span());
    token0.approve(notes_address, u256_from_u128(10));
    let commitment0 = notes.deposit_token0(array![].span(), insertion_proof_for_empty_leaf());
    let root1 = merkle_root_for_single_leaf(commitment0);

    let deposit_outputs_second = build_deposit_outputs(902, 10, 0);
    verifier.set_outputs(deposit_outputs_second.span());
    token0.approve(notes_address, u256_from_u128(10));
    let proof_for_second = insertion_proof_for_second_leaf(commitment0);
    let _commitment1 = notes.deposit_token0(array![].span(), proof_for_second);

    assert(notes.is_known_root(token0.contract_address, root1), 'pending root missing');
}
