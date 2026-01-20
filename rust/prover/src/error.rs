use std::fmt;

#[derive(Debug)]
pub enum ProverError {
    Io(String),
    Json(String),
    Snarkjs(String),
    Garaga(String),
    Conversion(String),
    InvalidInput(String),
}

impl fmt::Display for ProverError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            ProverError::Io(msg) => write!(f, "io error: {msg}"),
            ProverError::Json(msg) => write!(f, "json error: {msg}"),
            ProverError::Snarkjs(msg) => write!(f, "snarkjs error: {msg}"),
            ProverError::Garaga(msg) => write!(f, "garaga error: {msg}"),
            ProverError::Conversion(msg) => write!(f, "conversion error: {msg}"),
            ProverError::InvalidInput(msg) => write!(f, "invalid input: {msg}"),
        }
    }
}

impl std::error::Error for ProverError {}

impl From<std::io::Error> for ProverError {
    fn from(err: std::io::Error) -> Self {
        ProverError::Io(err.to_string())
    }
}

impl From<serde_json::Error> for ProverError {
    fn from(err: serde_json::Error) -> Self {
        ProverError::Json(err.to_string())
    }
}
