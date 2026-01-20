// historical roots component with circular buffer (default max_history = 256)
#[starknet::component]
pub mod HistoricalRoots0 {
    use starknet::storage::{
        Map, StorageMapReadAccess, StorageMapWriteAccess, StoragePointerReadAccess,
        StoragePointerWriteAccess,
    };

    const MAX_HISTORY: u64 = 256;

    #[storage]
    pub struct Storage {
        pub roots: Map<u64, felt252>, // index -> root
        pub roots_present: Map<u64, bool>,
        pub root_refcount: Map<felt252, u32>, // root -> count
        pub current_index: u64,
        pub max_history: u64,
    }

    #[event]
    #[derive(Drop, starknet::Event)]
    pub enum Event {}

    #[generate_trait]
    pub impl HistoricalRootsImpl<
        TContractState, +HasComponent<TContractState>,
    > of HistoricalRootsTrait<TContractState> {
        fn initializer(ref self: ComponentState<TContractState>) {
            self.current_index.write(0);
            self.max_history.write(MAX_HISTORY);
        }

        fn add_root(ref self: ComponentState<TContractState>, root: felt252) -> u64 {
            let idx = self.current_index.read();
            let cap = self.max_history.read();
            let slot = idx % cap;

            // remove ref for overwritten root (if any)
            if self.roots_present.read(slot) {
                let old_root = self.roots.read(slot);
                let old_count = self.root_refcount.read(old_root);
                assert(old_count > 0, 'ROOT_REFCOUNT_UNDERFLOW');
                self.root_refcount.write(old_root, old_count - 1);
            }

            self.roots.write(slot, root);
            self.roots_present.write(slot, true);
            let new_count = self.root_refcount.read(root);
            self.root_refcount.write(root, new_count + 1);
            self.current_index.write(idx + 1);
            idx
        }

        fn is_known_root(self: @ComponentState<TContractState>, root: felt252) -> bool {
            self.root_refcount.read(root) > 0
        }

        fn get_root(self: @ComponentState<TContractState>, index: u64) -> felt252 {
            let cap = self.max_history.read();
            let current = self.current_index.read();
            if current == 0 {
                return 0;
            }
            let oldest = if current > cap { current - cap } else { 0 };
            assert((index >= oldest) & (index < current), 'ROOT_INDEX_RANGE');
            self.roots.read(index % cap)
        }

        fn get_current_root(self: @ComponentState<TContractState>) -> felt252 {
            let cap = self.max_history.read();
            let idx = self.current_index.read();
            if idx == 0 {
                0
            } else {
                self.roots.read((idx - 1) % cap)
            }
        }

        fn get_current_index(self: @ComponentState<TContractState>) -> u64 {
            let idx = self.current_index.read();
            if idx == 0 {
                0
            } else {
                idx - 1
            }
        }
    }
}
