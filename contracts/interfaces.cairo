// Interface module aggregator for Zylith
pub mod IERC20;
pub mod IVerifier;
pub mod IZylithPool;

pub mod erc20 {
    pub use crate::clmm::interfaces::erc20::*;
}
pub mod core {
    pub use crate::clmm::interfaces::core::*;
}
pub mod upgradeable {
    pub use crate::clmm::interfaces::upgradeable::*;
}
