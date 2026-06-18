//! Provider 注册表。按 `Scheme` 查找具体 provider 实例。
//!
//! Phase 0 只注册 `LocalFsProvider`。Phase 1 起在 `ConnectionRegistry` 创建连接后，
//! 会执行 `providers.insert(Scheme::S3, Arc::new(S3Provider::new(config)))`。

use std::collections::HashMap;
use std::sync::Arc;

use super::{Scheme, VfsProvider, local::LocalFsProvider};

/// `Clone`：`Arc<dyn VfsProvider>` 与 `HashMap` 都是 Clone，
/// `AppState` 需要在测试中克隆并验证共享语义。
#[derive(Clone)]
pub struct ProviderRegistry {
    providers: HashMap<Scheme, Arc<dyn VfsProvider>>,
}

impl ProviderRegistry {
    pub fn new() -> Self {
        let mut providers: HashMap<Scheme, Arc<dyn VfsProvider>> = HashMap::new();
        providers.insert(Scheme::Local, Arc::new(LocalFsProvider));
        Self { providers }
    }

    pub fn get(&self, scheme: &Scheme) -> Option<Arc<dyn VfsProvider>> {
        self.providers.get(scheme).cloned()
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
}
