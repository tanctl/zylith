// Any contract that is upgradeable must implement this
#[starknet::interface]
pub trait IHasInterface<TContractState> {
    fn get_primary_interface_id(self: @TContractState) -> felt252;
}

#[starknet::component]
pub mod Upgradeable {
    use core::array::SpanTrait;
    use core::num::traits::Zero;
    use core::result::ResultTrait;
    use starknet::ClassHash;
    use starknet::get_block_timestamp;
    use starknet::syscalls::{library_call_syscall, replace_class_syscall};
    use crate::components::owned::Ownable;
    use crate::interfaces::upgradeable::IUpgradeable;
    use super::IHasInterface;

    const UPGRADE_DELAY_SECS: u64 = 86400;

    #[storage]
    pub struct Storage {
        pub pending_class_hash: ClassHash,
        pub pending_ready_at: u64,
    }

    #[derive(starknet::Event, Drop)]
    pub struct ClassHashReplaced {
        pub new_class_hash: ClassHash,
    }

    #[derive(starknet::Event, Drop)]
    pub struct ClassHashScheduled {
        pub new_class_hash: ClassHash,
        pub ready_at: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        ClassHashReplaced: ClassHashReplaced,
        ClassHashScheduled: ClassHashScheduled,
    }


    #[embeddable_as(UpgradeableImpl)]
    pub impl Upgradeable<
        TContractState,
        +HasComponent<TContractState>,
        +IHasInterface<TContractState>,
        +Ownable<TContractState>,
    > of IUpgradeable<ComponentState<TContractState>> {
        fn replace_class_hash(ref self: ComponentState<TContractState>, class_hash: ClassHash) {
            let _ = class_hash;
            // todo(post-mvp): re-enable with timelock + multisig governance.
            assert(false, 'UPGRADE_DISABLED_MVP');
            let this_contract = self.get_contract();
            this_contract.require_owner();
            assert(!class_hash.is_zero(), 'INVALID_CLASS_HASH');

            if UPGRADE_DELAY_SECS != 0 {
                let now = get_block_timestamp();
                let pending = self.pending_class_hash.read();
                let ready_at = self.pending_ready_at.read();
                if (pending == class_hash) & (ready_at != 0) & (now >= ready_at) {
                    self.pending_class_hash.write(Zero::zero());
                    self.pending_ready_at.write(0);
                } else {
                    let scheduled_at = now + UPGRADE_DELAY_SECS;
                    assert(scheduled_at >= now, 'TIME_OVERFLOW');
                    self.pending_class_hash.write(class_hash);
                    self.pending_ready_at.write(scheduled_at);
                    self.emit(ClassHashScheduled { new_class_hash: class_hash, ready_at: scheduled_at });
                    return ();
                }
            }

            let id = this_contract.get_primary_interface_id();

            let mut result = library_call_syscall(
                class_hash, selector!("get_primary_interface_id"), array![].span(),
            )
                .expect('MISSING_PRIMARY_INTERFACE_ID');

            let next_id = result.pop_front().expect('INVALID_RETURN_DATA');

            assert(@id == next_id, 'UPGRADEABLE_ID_MISMATCH');

            replace_class_syscall(class_hash).expect('UPGRADE_FAILED');

            self.emit(ClassHashReplaced { new_class_hash: class_hash });
        }
    }
}
