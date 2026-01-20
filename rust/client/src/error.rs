use std::fmt;

#[derive(Debug)]
pub enum ClientError {
    InvalidInput(String),
    Rpc(String),
    Asp(String),
    Crypto(String),
    Serde(String),
    Prover(String),
    Io(String),
    NotImplemented(String),
}

impl fmt::Display for ClientError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ClientError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
            ClientError::Rpc(msg) => write!(f, "rpc error: {msg}"),
            ClientError::Asp(msg) => write!(f, "asp error: {msg}"),
            ClientError::Crypto(msg) => write!(f, "crypto error: {msg}"),
            ClientError::Serde(msg) => write!(f, "serde error: {msg}"),
            ClientError::Prover(msg) => write!(f, "prover error: {msg}"),
            ClientError::Io(msg) => write!(f, "io error: {msg}"),
            ClientError::NotImplemented(msg) => write!(f, "not implemented: {msg}"),
        }
    }
}

impl std::error::Error for ClientError {}

impl From<serde_json::Error> for ClientError {
    fn from(err: serde_json::Error) -> Self {
        ClientError::Serde(err.to_string())
    }
}

impl From<std::io::Error> for ClientError {
    fn from(err: std::io::Error) -> Self {
        ClientError::Io(err.to_string())
    }
}

impl From<reqwest::Error> for ClientError {
    fn from(err: reqwest::Error) -> Self {
        ClientError::Asp(err.to_string())
    }
}
