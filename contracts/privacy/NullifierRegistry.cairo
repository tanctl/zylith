// nullifier registry component to prevent double spends
#[starknet::component]
pub mod NullifierRegistry {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };
    use starknet::get_block_timestamp;

    #[storage]
    pub struct Storage {
        pub nullifiers: Map<felt252, bool>,
        pub nullifier_count: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {
        NullifierUsed: NullifierUsed,
    }

    #[derive(Drop, starknet::Event)]
    pub struct NullifierUsed {
        pub nullifier: felt252,
        pub count: u64,
        pub timestamp: u64,
    }

    #[generate_trait]
    pub impl NullifierRegistryImpl<
        TContractState, +HasComponent<TContractState>,
    > of NullifierRegistryTrait<TContractState> {
        fn is_used(self: @ComponentState<TContractState>, nullifier: felt252) -> bool {
            self.nullifiers.read(nullifier)
        }

        fn mark_used(ref self: ComponentState<TContractState>, nullifier: felt252) {
            // Access control enforced by ShieldedNotes only.
            assert(nullifier != 0, 'NULLIFIER_ZERO');
            assert(!self.nullifiers.read(nullifier), 'NULLIFIER_ALREADY_USED');
            self.nullifiers.write(nullifier, true);
            let count = self.nullifier_count.read() + 1;
            self.nullifier_count.write(count);
            self.emit(NullifierUsed { nullifier, count, timestamp: get_block_timestamp() });
        }

        fn get_count(self: @ComponentState<TContractState>) -> u64 {
            self.nullifier_count.read()
        }
    }
}
