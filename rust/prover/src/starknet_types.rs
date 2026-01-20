//! Helper types for Starknet calldata.

#[derive(Debug, Clone)]
pub struct ProofCalldata {
    pub full_proof: Vec<String>,
}

impl ProofCalldata {
    pub fn new(full_proof: Vec<String>) -> Self {
        Self { full_proof }
    }

    pub fn as_proof(&self) -> &[String] {
        &self.full_proof
    }

    pub fn to_calldata(&self) -> Vec<String> {
        if let Some(len) = parse_len_token(self.full_proof.first()) {
            if len == self.full_proof.len().saturating_sub(1) {
                return self.full_proof.clone();
            }
        }
        let mut calldata = Vec::with_capacity(self.full_proof.len() + 1);
        calldata.push(format!("0x{:x}", self.full_proof.len()));
        calldata.extend(self.full_proof.clone());
        calldata
    }
}

fn parse_len_token(token: Option<&String>) -> Option<usize> {
    let token = token?;
    if let Some(hex) = token.strip_prefix("0x") {
        usize::from_str_radix(hex, 16).ok()
    } else {
        token.parse::<usize>().ok()
    }
}
