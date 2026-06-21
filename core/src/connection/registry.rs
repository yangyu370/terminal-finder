//! Connection registry.
//!
//! 内存表，按 `ConnectionId` 索引活跃 S3 连接。
//! `Arc<RwLock>` 包裹使 `AppState` clone 后多个引用共享同一份。

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use uuid::Uuid;

use super::{ConnectionConfig, ConnectionId, Credential};
use crate::error::ApiError;

/// 一条活跃连接的完整记录。
#[derive(Debug, Clone)]
pub struct ConnectionEntry {
    pub id: ConnectionId,
    pub config: ConnectionConfig,
    pub credential: Credential,
}

#[derive(Clone)]
pub struct ConnectionRegistry {
    entries: Arc<RwLock<HashMap<ConnectionId, ConnectionEntry>>>,
}

impl ConnectionRegistry {
    pub fn new() -> Self {
        Self {
            entries: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn create(&self, config: ConnectionConfig, credential: Credential) -> ConnectionId {
        let id = ConnectionId(Uuid::new_v4().to_string());
        let entry = ConnectionEntry {
            id: id.clone(),
            config,
            credential,
        };
        let mut guard = self.entries.write().unwrap_or_else(|p| p.into_inner());
        guard.insert(id.clone(), entry);
        id
    }

    /// Insert an entry with a caller-provided id. Used on app startup to
    /// rehydrate connections from the client-side persistent store so the
    /// `connection_id` recorded in JSON stays stable across restarts.
    /// Returns `InvalidParams` if the id is already registered — callers
    /// should treat this as a programmer error (double-restore in one run).
    pub fn insert_with_id(
        &self,
        id: ConnectionId,
        config: ConnectionConfig,
        credential: Credential,
    ) -> Result<(), ApiError> {
        let mut guard = self.entries.write().unwrap_or_else(|p| p.into_inner());
        if guard.contains_key(&id) {
            return Err(ApiError::InvalidParams {
                method: "connection.restore".into(),
                message: format!("connection_id already registered: {}", id.0),
            });
        }
        let entry = ConnectionEntry {
            id: id.clone(),
            config,
            credential,
        };
        guard.insert(id, entry);
        Ok(())
    }

    pub fn get(&self, id: &ConnectionId) -> Option<ConnectionEntry> {
        let guard = self.entries.read().unwrap_or_else(|p| p.into_inner());
        guard.get(id).cloned()
    }

    pub fn list(&self) -> Vec<ConnectionEntry> {
        let guard = self.entries.read().unwrap_or_else(|p| p.into_inner());
        guard.values().cloned().collect()
    }

    pub fn remove(&self, id: &ConnectionId) -> bool {
        let mut guard = self.entries.write().unwrap_or_else(|p| p.into_inner());
        guard.remove(id).is_some()
    }

    pub fn is_shared_with(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.entries, &other.entries)
    }
}

impl Default for ConnectionRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::connection::{S3ConnectionConfig, S3Credential};

    fn sample_config() -> ConnectionConfig {
        ConnectionConfig::S3(S3ConnectionConfig {
            display_name: "test".into(),
            endpoint: "http://localhost:9000".into(),
            region: "us-east-1".into(),
            bucket: "test-bucket".into(),
            base_prefix: String::new(),
            path_style: true,
        })
    }

    fn sample_credential() -> Credential {
        Credential::S3(S3Credential {
            access_key_id: "minioadmin".into(),
            secret_access_key: "minioadmin".into(),
        })
    }

    #[test]
    fn connection_create_returns_unique_id() {
        let registry = ConnectionRegistry::new();
        let id1 = registry.create(sample_config(), sample_credential());
        let id2 = registry.create(sample_config(), sample_credential());
        assert_ne!(id1, id2);
    }

    #[test]
    fn connection_get_returns_entry_by_id() {
        let registry = ConnectionRegistry::new();
        let id = registry.create(sample_config(), sample_credential());
        let entry = registry.get(&id).expect("entry exists");
        assert_eq!(entry.id, id);
        assert_eq!(entry.config.display_name(), "test");
    }

    #[test]
    fn connection_get_missing_returns_none() {
        let registry = ConnectionRegistry::new();
        let missing = ConnectionId("nonexistent".into());
        assert!(registry.get(&missing).is_none());
    }

    #[test]
    fn connection_list_returns_all_entries() {
        let registry = ConnectionRegistry::new();
        registry.create(sample_config(), sample_credential());
        registry.create(sample_config(), sample_credential());
        registry.create(sample_config(), sample_credential());
        assert_eq!(registry.list().len(), 3);
    }

    #[test]
    fn connection_remove_deletes_entry() {
        let registry = ConnectionRegistry::new();
        let id = registry.create(sample_config(), sample_credential());
        assert!(registry.remove(&id));
        assert!(registry.get(&id).is_none());
        assert!(!registry.remove(&id), "second remove returns false");
    }

    #[test]
    fn insert_with_id_preserves_caller_id_for_rehydration() {
        let registry = ConnectionRegistry::new();
        let preset = ConnectionId("26e3b59e-c346-4480-a25d-07c7f8e5b467".into());
        registry
            .insert_with_id(preset.clone(), sample_config(), sample_credential())
            .expect("first restore succeeds");
        let entry = registry.get(&preset).expect("entry lookup by preset id");
        assert_eq!(entry.id, preset);
        assert_eq!(entry.config.display_name(), "test");
    }

    #[test]
    fn insert_with_id_rejects_duplicate_id() {
        let registry = ConnectionRegistry::new();
        let preset = ConnectionId("dup".into());
        registry
            .insert_with_id(preset.clone(), sample_config(), sample_credential())
            .expect("first restore");
        let err = registry
            .insert_with_id(preset.clone(), sample_config(), sample_credential())
            .expect_err("second restore with same id must fail");
        assert_eq!(err.code(), "invalid_params");
    }

    #[test]
    fn connection_registry_shared_across_clones() {
        let registry = ConnectionRegistry::new();
        let cloned = registry.clone();
        assert!(registry.is_shared_with(&cloned));

        let id = registry.create(sample_config(), sample_credential());
        assert!(
            cloned.get(&id).is_some(),
            "entry visible through cloned handle"
        );
    }
}
