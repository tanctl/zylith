// verifier interface for Groth16/Plonk systems
#[starknet::interface]
pub trait IVerifier<TContractState> {
    // returns decoded public inputs if proof is valid
    fn verify(self: @TContractState, proof: Span<felt252>) -> Option<Span<u256>>;
}
