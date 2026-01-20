//! Persistence layer for ASP.

use std::collections::HashMap;

use sqlx::{PgPool, Row};
use starknet::core::types::FieldElement as Felt;

use crate::merkle::{MerkleError, MerkleTree};

#[derive(Debug)]
pub enum StorageError {
    Db(String),
    Invariant(String),
    Desync(String),
}

impl std::fmt::Display for StorageError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            StorageError::Db(msg) => write!(f, "db error: {msg}"),
            StorageError::Invariant(msg) => write!(f, "invariant error: {msg}"),
            StorageError::Desync(msg) => write!(f, "desync error: {msg}"),
        }
    }
}

impl std::error::Error for StorageError {}

impl From<sqlx::Error> for StorageError {
    fn from(err: sqlx::Error) -> Self {
        Self::Db(err.to_string())
    }
}

#[derive(Clone)]
pub struct Storage {
    pool: PgPool,
}

#[derive(Debug, Clone)]
pub struct CommitmentRecord {
    pub token: String,
    pub leaf_index: u64,
    pub commitment: String,
    pub timestamp: u64,
    pub block_number: u64,
}

#[derive(Debug, Clone)]
pub struct RootRecord {
    pub token: String,
    pub root_index: u64,
    pub root_hash: String,
    pub block_number: u64,
    pub leaf_count: u64,
}

impl Storage {
    pub async fn new(database_url: &str) -> Result<Self, StorageError> {
        let pool = sqlx::postgres::PgPoolOptions::new()
            .max_connections(5)
            .connect(database_url)
            .await?;
        let storage = Self { pool };
        storage.init_schema().await?;
        Ok(storage)
    }

    pub async fn init_schema(&self) -> Result<(), StorageError> {
        let statements = [
            "CREATE TABLE IF NOT EXISTS commitments ( \
                token TEXT NOT NULL, \
                leaf_index BIGINT NOT NULL, \
                commitment TEXT NOT NULL, \
                timestamp BIGINT NOT NULL, \
                block_number BIGINT NOT NULL, \
                PRIMARY KEY (token, leaf_index), \
                UNIQUE (token, commitment) \
            )",
            "CREATE TABLE IF NOT EXISTS roots ( \
                token TEXT NOT NULL, \
                root_index BIGINT NOT NULL, \
                root_hash TEXT NOT NULL, \
                block_number BIGINT NOT NULL, \
                leaf_count BIGINT NOT NULL DEFAULT 0, \
                PRIMARY KEY (token, root_index) \
            )",
            "CREATE TABLE IF NOT EXISTS nullifiers ( \
                nullifier_hash TEXT PRIMARY KEY, \
                used_at_block BIGINT NOT NULL \
            )",
            "CREATE TABLE IF NOT EXISTS sync_state ( \
                key TEXT PRIMARY KEY, \
                value BIGINT NOT NULL \
            )",
            "CREATE INDEX IF NOT EXISTS idx_commitment_hash ON commitments (commitment)",
            "CREATE INDEX IF NOT EXISTS idx_roots_hash ON roots (root_hash)",
        ];
        for stmt in statements {
            sqlx::query(stmt).execute(&self.pool).await?;
        }
        sqlx::query("ALTER TABLE roots ADD COLUMN IF NOT EXISTS leaf_count BIGINT NOT NULL DEFAULT 0")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn reset(&self) -> Result<(), StorageError> {
        sqlx::query("TRUNCATE commitments, roots, nullifiers, sync_state")
            .execute(&self.pool)
            .await?;
        Ok(())
    }

    pub async fn insert_commitment(&self, record: CommitmentRecord) -> Result<bool, StorageError> {
        let result = sqlx::query(
            "INSERT INTO commitments (token, leaf_index, commitment, timestamp, block_number) \
             VALUES ($1, $2, $3, $4, $5) \
             ON CONFLICT DO NOTHING",
        )
        .bind(&record.token)
        .bind(record.leaf_index as i64)
        .bind(&record.commitment)
        .bind(record.timestamp as i64)
        .bind(record.block_number as i64)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            let existing = sqlx::query(
                "SELECT commitment FROM commitments WHERE token = $1 AND leaf_index = $2",
            )
            .bind(&record.token)
            .bind(record.leaf_index as i64)
            .fetch_one(&self.pool)
            .await?;
            let commitment: String = existing.try_get("commitment")?;
            if commitment != record.commitment {
                return Err(StorageError::Invariant(format!(
                    "commitment mismatch for {}:{}",
                    record.token, record.leaf_index
                )));
            }
            return Ok(false);
        }
        Ok(true)
    }

    pub async fn insert_root(&self, record: RootRecord) -> Result<bool, StorageError> {
        let result = sqlx::query(
            "INSERT INTO roots (token, root_index, root_hash, block_number, leaf_count) \
             VALUES ($1, $2, $3, $4, $5) \
             ON CONFLICT DO NOTHING",
        )
        .bind(&record.token)
        .bind(record.root_index as i64)
        .bind(&record.root_hash)
        .bind(record.block_number as i64)
        .bind(record.leaf_count as i64)
        .execute(&self.pool)
        .await?;
        if result.rows_affected() == 0 {
            let existing = sqlx::query(
                "SELECT root_hash, leaf_count FROM roots WHERE token = $1 AND root_index = $2",
            )
            .bind(&record.token)
            .bind(record.root_index as i64)
            .fetch_one(&self.pool)
            .await?;
            let root_hash: String = existing.try_get("root_hash")?;
            let leaf_count: i64 = existing.try_get("leaf_count")?;
            if root_hash != record.root_hash || leaf_count as u64 != record.leaf_count {
                return Err(StorageError::Invariant(format!(
                    "root mismatch for {}:{}",
                    record.token, record.root_index
                )));
            }
            return Ok(false);
        }
        Ok(true)
    }

    pub async fn update_root_leaf_count(
        &self,
        token: &str,
        root_hash: &str,
        leaf_count: u64,
    ) -> Result<(), StorageError> {
        let rows = sqlx::query(
            "SELECT leaf_count FROM roots WHERE token = $1 AND root_hash = $2",
        )
        .bind(token)
        .bind(root_hash)
        .fetch_all(&self.pool)
        .await?;
        if rows.is_empty() {
            return Ok(());
        }
        for row in &rows {
            let existing: i64 = row.try_get("leaf_count")?;
            if existing != 0 && existing as u64 != leaf_count {
                return Err(StorageError::Invariant(format!(
                    "leaf_count mismatch for root {} expected {} got {}",
                    root_hash, existing, leaf_count
                )));
            }
        }
        sqlx::query(
            "UPDATE roots SET leaf_count = $1 \
             WHERE token = $2 AND root_hash = $3 AND leaf_count = 0",
        )
        .bind(leaf_count as i64)
        .bind(token)
        .bind(root_hash)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn insert_nullifier(&self, nullifier: &str, block_number: u64) -> Result<(), StorageError> {
        sqlx::query(
            "INSERT INTO nullifiers (nullifier_hash, used_at_block) \
             VALUES ($1, $2) \
             ON CONFLICT DO NOTHING",
        )
        .bind(nullifier)
        .bind(block_number as i64)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn get_commitment(
        &self,
        commitment: &str,
    ) -> Result<Option<(String, u64, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT token, leaf_index, block_number FROM commitments WHERE commitment = $1 LIMIT 1",
        )
        .bind(commitment)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let token: String = row.try_get("token")?;
            let leaf_index: i64 = row.try_get("leaf_index")?;
            let block_number: i64 = row.try_get("block_number")?;
            return Ok(Some((token, leaf_index as u64, block_number as u64)));
        }
        Ok(None)
    }

    pub async fn get_commitment_by_index(
        &self,
        token: &str,
        leaf_index: u64,
    ) -> Result<Option<(String, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT commitment, block_number FROM commitments WHERE token = $1 AND leaf_index = $2",
        )
        .bind(token)
        .bind(leaf_index as i64)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let commitment: String = row.try_get("commitment")?;
            let block_number: i64 = row.try_get("block_number")?;
            return Ok(Some((commitment, block_number as u64)));
        }
        Ok(None)
    }

    pub async fn get_root_at(
        &self,
        token: &str,
        root_index: u64,
    ) -> Result<Option<(String, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_hash, leaf_count FROM roots WHERE token = $1 AND root_index = $2",
        )
        .bind(token)
        .bind(root_index as i64)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_hash: String = row.try_get("root_hash")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            return Ok(Some((root_hash, leaf_count as u64)));
        }
        Ok(None)
    }

    pub async fn get_root_at_with_block(
        &self,
        token: &str,
        root_index: u64,
    ) -> Result<Option<(String, u64, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_hash, leaf_count, block_number FROM roots \
             WHERE token = $1 AND root_index = $2",
        )
        .bind(token)
        .bind(root_index as i64)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_hash: String = row.try_get("root_hash")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            let block_number: i64 = row.try_get("block_number")?;
            return Ok(Some((
                root_hash,
                leaf_count as u64,
                block_number as u64,
            )));
        }
        Ok(None)
    }

    pub async fn get_root_by_hash(
        &self,
        token: &str,
        root_hash: &str,
    ) -> Result<Option<(u64, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_index, leaf_count FROM roots WHERE token = $1 AND root_hash = $2 LIMIT 1",
        )
        .bind(token)
        .bind(root_hash)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_index: i64 = row.try_get("root_index")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            return Ok(Some((root_index as u64, leaf_count as u64)));
        }
        Ok(None)
    }

    pub async fn get_root_by_hash_with_block(
        &self,
        token: &str,
        root_hash: &str,
    ) -> Result<Option<(u64, u64, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_index, leaf_count, block_number FROM roots \
             WHERE token = $1 AND root_hash = $2 LIMIT 1",
        )
        .bind(token)
        .bind(root_hash)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_index: i64 = row.try_get("root_index")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            let block_number: i64 = row.try_get("block_number")?;
            return Ok(Some((
                root_index as u64,
                leaf_count as u64,
                block_number as u64,
            )));
        }
        Ok(None)
    }

    pub async fn get_latest_root(
        &self,
        token: &str,
    ) -> Result<Option<(u64, String, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_index, root_hash, leaf_count FROM roots \
             WHERE token = $1 ORDER BY root_index DESC LIMIT 1",
        )
        .bind(token)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_index: i64 = row.try_get("root_index")?;
            let root_hash: String = row.try_get("root_hash")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            return Ok(Some((
                root_index as u64,
                root_hash,
                leaf_count as u64,
            )));
        }
        Ok(None)
    }

    pub async fn get_latest_root_before(
        &self,
        token: &str,
        max_block: u64,
    ) -> Result<Option<(u64, String, u64, u64)>, StorageError> {
        let row = sqlx::query(
            "SELECT root_index, root_hash, leaf_count, block_number FROM roots \
             WHERE token = $1 AND block_number <= $2 \
             ORDER BY root_index DESC LIMIT 1",
        )
        .bind(token)
        .bind(max_block as i64)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let root_index: i64 = row.try_get("root_index")?;
            let root_hash: String = row.try_get("root_hash")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            let block_number: i64 = row.try_get("block_number")?;
            return Ok(Some((
                root_index as u64,
                root_hash,
                leaf_count as u64,
                block_number as u64,
            )));
        }
        Ok(None)
    }

    pub async fn get_latest_leaf_count(
        &self,
        token: &str,
    ) -> Result<Option<u64>, StorageError> {
        let row = sqlx::query(
            "SELECT leaf_count FROM roots WHERE token = $1 ORDER BY root_index DESC LIMIT 1",
        )
        .bind(token)
        .fetch_optional(&self.pool)
        .await?;
        if let Some(row) = row {
            let leaf_count: i64 = row.try_get("leaf_count")?;
            return Ok(Some(leaf_count as u64));
        }
        Ok(None)
    }

    pub async fn get_last_block(&self) -> Result<Option<u64>, StorageError> {
        let row = sqlx::query("SELECT value FROM sync_state WHERE key = 'last_block'")
            .fetch_optional(&self.pool)
            .await?;
        if let Some(row) = row {
            let value: i64 = row.try_get("value")?;
            return Ok(Some(value as u64));
        }
        Ok(None)
    }

    pub async fn set_last_block(&self, block: u64) -> Result<(), StorageError> {
        sqlx::query(
            "INSERT INTO sync_state (key, value) VALUES ('last_block', $1) \
             ON CONFLICT (key) DO UPDATE SET value = excluded.value",
        )
        .bind(block as i64)
        .execute(&self.pool)
        .await?;
        Ok(())
    }

    pub async fn load_trees(
        &self,
        height: usize,
    ) -> Result<HashMap<String, MerkleTree>, StorageError> {
        let rows = sqlx::query(
            "SELECT token, leaf_index, commitment FROM commitments ORDER BY token, leaf_index",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut trees: HashMap<String, MerkleTree> = HashMap::new();
        for row in rows {
            let token: String = row.try_get("token")?;
            let leaf_index: i64 = row.try_get("leaf_index")?;
            let commitment: String = row.try_get("commitment")?;
            let tree = trees
                .entry(token.clone())
                .or_insert_with(|| MerkleTree::new(height));
            let leaf = Felt::from_hex_be(&commitment)
                .map_err(|e| StorageError::Invariant(e.to_string()))?;
            tree
                .insert_at(leaf_index as u64, leaf)
                .map_err(|err| match err {
                    MerkleError::IndexGap { expected, got } => StorageError::Invariant(format!(
                        "merkle index gap for {} expected {} got {}",
                        token, expected, got
                    )),
                    MerkleError::LeafMismatch { index } => StorageError::Invariant(format!(
                        "merkle leaf mismatch for {} at {}",
                        token, index
                    )),
                    MerkleError::TreeFull { max } => StorageError::Invariant(format!(
                        "merkle tree full for {} max_leaves={}",
                        token, max
                    )),
                    MerkleError::InvalidLeaf { reason } => StorageError::Invariant(format!(
                        "merkle invalid leaf for {} reason={}",
                        token, reason
                    )),
                })?;
        }
        Ok(trees)
    }

    pub async fn load_recent_roots(
        &self,
        max_entries: usize,
    ) -> Result<HashMap<String, Vec<(u64, String, u64, u64)>>, StorageError> {
        let rows = sqlx::query(
            "SELECT token, root_index, root_hash, block_number, leaf_count \
             FROM roots \
             ORDER BY token, root_index DESC",
        )
        .fetch_all(&self.pool)
        .await?;
        let mut map: HashMap<String, Vec<(u64, String, u64, u64)>> = HashMap::new();
        for row in rows {
            let token: String = row.try_get("token")?;
            let root_index: i64 = row.try_get("root_index")?;
            let root_hash: String = row.try_get("root_hash")?;
            let block_number: i64 = row.try_get("block_number")?;
            let leaf_count: i64 = row.try_get("leaf_count")?;
            let entry = map.entry(token).or_default();
            if entry.len() < max_entries {
                entry.push((
                    root_index as u64,
                    root_hash,
                    block_number as u64,
                    leaf_count as u64,
                ));
            }
        }
        Ok(map)
    }
}
