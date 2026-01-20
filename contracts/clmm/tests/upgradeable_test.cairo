use starknet::ClassHash;
use snforge_std::{start_cheat_caller_address, stop_cheat_caller_address};
use crate::interfaces::upgradeable::IUpgradeableDispatcherTrait;
use crate::tests::helper::{Deployer, DeployerTrait, default_owner};
use crate::tests::mocks::mock_upgradeable::MockUpgradeable;

#[test]
#[should_panic(expected: ('UPGRADE_DISABLED_MVP',))]
fn test_replace_class_hash() {
    let mut d: Deployer = Default::default();
    let mock_upgradeable = d.deploy_mock_upgradeable();
    let class_hash: ClassHash = MockUpgradeable::TEST_CLASS_HASH.try_into().unwrap();
    start_cheat_caller_address(mock_upgradeable.contract_address, default_owner());
    mock_upgradeable.replace_class_hash(class_hash);
    stop_cheat_caller_address(mock_upgradeable.contract_address);
}
