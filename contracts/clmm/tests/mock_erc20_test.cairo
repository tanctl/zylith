use snforge_std::{
    EventSpyTrait, EventsFilterTrait, spy_events, start_cheat_caller_address,
    stop_cheat_caller_address,
};
use starknet::{ContractAddress, get_contract_address};
use crate::tests::helper::{Deployer, DeployerTrait};
use crate::tests::mock_erc20::MockERC20IERC20ImplTrait;

#[test]
fn test_constructor() {
    let mut d: Deployer = Default::default();
    let mut spy = spy_events();

    let owner: ContractAddress = 1234.try_into().unwrap();
    let erc20 = d
        .deploy_mock_token_with_balance(owner, 0xffffffffffffffffffffffffffffffff);
    assert(
        erc20.balanceOf(owner) == 0xffffffffffffffffffffffffffffffff,
        'balance of this',
    );
    let events = spy.get_events().emitted_by(erc20.contract_address);
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    let mut found = false;
    let mut idx: usize = 0;
    while idx < events.events.len() {
        let (_, event) = events.events.at(idx);
        if event.data.len() >= 4 {
            if *event.data.at(0) == zero_addr.into()
                && *event.data.at(1) == owner.into()
                && *event.data.at(2) == 0xffffffffffffffffffffffffffffffff_u128.into()
                && *event.data.at(3) == 0_u128.into()
            {
                found = true;
            }
        }
        idx += 1;
    }
    assert(found, 'transfer event');
}

#[test]
fn test_transfer() {
    let mut d: Deployer = Default::default();
    let mut spy = spy_events();
    let erc20 = d
        .deploy_mock_token_with_balance(get_contract_address(), 0xffffffffffffffffffffffffffffffff);

    let recipient: ContractAddress = 0x1234.try_into().unwrap();
    let amount = 1234_u256;
    start_cheat_caller_address(erc20.contract_address, get_contract_address());
    assert(erc20.transfer(recipient, amount) == true, 'transfer');
    stop_cheat_caller_address(erc20.contract_address);
    assert(
        erc20.balanceOf(get_contract_address()) == (0xffffffffffffffffffffffffffffffff - 1234),
        'balance sender',
    );
    assert(erc20.balanceOf(recipient) == amount, 'balance recipient');
    let events = spy.get_events().emitted_by(erc20.contract_address);
    let zero_addr: ContractAddress = 0.try_into().unwrap();
    let mut found_mint = false;
    let mut found_transfer = false;
    let mut idx: usize = 0;
    while idx < events.events.len() {
        let (_, event) = events.events.at(idx);
        if event.data.len() >= 4 {
            if *event.data.at(0) == zero_addr.into()
                && *event.data.at(1) == get_contract_address().into()
                && *event.data.at(2) == 0xffffffffffffffffffffffffffffffff_u128.into()
                && *event.data.at(3) == 0_u128.into()
            {
                found_mint = true;
            }
            if *event.data.at(0) == get_contract_address().into()
                && *event.data.at(1) == recipient.into()
                && *event.data.at(2) == amount.low.into()
                && *event.data.at(3) == amount.high.into()
            {
                found_transfer = true;
            }
        }
        idx += 1;
    }
    assert(found_mint, 'mint event');
    assert(found_transfer, 'transfer event');
}
