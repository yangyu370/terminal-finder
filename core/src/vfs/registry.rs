//! Provider 注册表。按 `Scheme` 查找静态 provider，按 `ConnectionId` 查找动态 S3 provider。
//!
//! Phase 0 只注册 `LocalFsProvider`。Phase 1 起 workspace 服务在解析 `connection_id` 时，
//! 会调用 `register_connection` 把 S3Provider 缓存在内存里，后续读路径通过
//! `get_by_connection` 命中。`by_connection` 用 `Arc<RwLock<HashMap>>` 包裹，
//! 以便 `AppState::clone` 后多个引用共享同一份动态表（&self 接口即可写入）。

use std::collections::HashMap;
use std::sync::{Arc, RwLock};

use super::{Scheme, VfsProvider, local::LocalFsProvider};
use crate::connection::ConnectionId;

/// `Clone`：`providers` 是 Phase 0 启动期构建后只读，clone 时各自持有副本；
/// `by_connection` 共享同一个 `Arc<RwLock>`，让 `AppState::clone` 后写入仍互见。
#[derive(Clone)]
pub struct ProviderRegistry {
    providers: HashMap<Scheme, Arc<dyn VfsProvider>>,
    by_connection: Arc<RwLock<HashMap<ConnectionId, Arc<dyn VfsProvider>>>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        let mut providers: HashMap<Scheme, Arc<dyn VfsProvider>> = HashMap::new();
        providers.insert(Scheme::Local, Arc::new(LocalFsProvider));
        Self {
            providers,
            by_connection: Arc::new(RwLock::new(HashMap::new())),
        }
    }

    pub fn get(&self, scheme: &Scheme) -> Option<Arc<dyn VfsProvider>> {
        self.providers.get(scheme).cloned()
    }

    /// 缓存某个连接对应的 provider 实例。重复 register 等价于覆盖。
    pub fn register_connection(&self, id: &ConnectionId, provider: Arc<dyn VfsProvider>) {
        let mut guard = self
            .by_connection
            .write()
            .unwrap_or_else(|p| p.into_inner());
        guard.insert(id.clone(), provider);
    }

    /// 按连接 id 取 provider；未注册时返回 None，由调用方决定是否懒构造。
    pub fn get_by_connection(&self, id: &ConnectionId) -> Option<Arc<dyn VfsProvider>> {
        let guard = self.by_connection.read().unwrap_or_else(|p| p.into_inner());
        guard.get(id).cloned()
    }

    /// 解除连接到 provider 的绑定。后续 `get_by_connection` 返回 None。
    pub fn remove_connection(&self, id: &ConnectionId) {
        let mut guard = self
            .by_connection
            .write()
            .unwrap_or_else(|p| p.into_inner());
        guard.remove(id);
    }
}

impl Default for ProviderRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn local_provider_is_registered_by_default() {
        let registry = ProviderRegistry::new();
        let provider = registry
            .get(&Scheme::Local)
            .expect("local provider is registered by default");

        let caps = provider.capabilities();
        assert!(caps.can_rename);
        assert!(caps.can_symlink);
        assert!(caps.can_write);
        assert!(caps.has_native_directories);
    }

    #[test]
    fn provider_registry_register_and_get_by_connection_id() {
        use crate::connection::ConnectionId;

        let registry = ProviderRegistry::new();
        let conn_id = ConnectionId("conn-1".into());
        let provider: Arc<dyn VfsProvider> = Arc::new(LocalFsProvider);
        registry.register_connection(&conn_id, provider);

        assert!(registry.get_by_connection(&conn_id).is_some());
        assert!(
            registry
                .get_by_connection(&ConnectionId("missing".into()))
                .is_none()
        );

        registry.remove_connection(&conn_id);
        assert!(registry.get_by_connection(&conn_id).is_none());
    }

    #[test]
    fn provider_registry_connection_map_shared_across_clones() {
        use crate::connection::ConnectionId;

        let registry = ProviderRegistry::new();
        let cloned = registry.clone();
        let conn_id = ConnectionId("shared".into());
        let provider: Arc<dyn VfsProvider> = Arc::new(LocalFsProvider);
        registry.register_connection(&conn_id, provider);

        assert!(
            cloned.get_by_connection(&conn_id).is_some(),
            "cloned registry must observe newly-registered connection"
        );
    }
}
