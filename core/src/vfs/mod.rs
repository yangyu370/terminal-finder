//! Virtual filesystem 抽象层。
//!
//! Phase 0：定义 `VfsProvider` trait、`Location` 位置描述符、`Scheme` 与 `ProviderCaps`，
//! 并通过 `ProviderRegistry` 按 scheme 路由到具体 provider 实现。
//! 当前只注册 `LocalFsProvider`；后续 Phase 1 会新增 S3Provider，Phase 2/3 视情况扩展。

pub mod local;
pub mod registry;

use crate::{
    error::ApiError,
    workspace::{DirectoryEntry, dto::ListDirectoryResponse},
};

pub use local::LocalFsProvider;
pub use registry::ProviderRegistry;

/// 位置 scheme。Phase 1 引入 S3，对应 OpenDAL 的 services-s3 provider。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub enum Scheme {
    Local,
    S3,
}

/// 统一位置标识。所有 workspace 操作按此路由到对应 provider。
///
/// `path` 用 `String` 而非 `PathBuf`——S3 路径 (`bucket/prefix/key`) 不是 OS 路径，
/// 不能假设 OsString 语义；LocalFsProvider 在内部自行 `PathBuf::from()`。
#[derive(Debug, Clone)]
pub struct Location {
    pub scheme: Scheme,
    pub connection_id: Option<String>,
    pub path: String,
}

impl Location {
    /// 便捷构造器：本地路径 → `Location { scheme: Local, connection_id: None, path }`。
    pub fn local(path: impl Into<String>) -> Self {
        Self {
            scheme: Scheme::Local,
            connection_id: None,
            path: path.into(),
        }
    }
}

/// Provider 能力声明。client 据此决定哪些 UI 操作可用。
///
/// Phase 0 只占位，逻辑层不消费；Phase 1 client 会根据这些 caps 灰显
/// 对象存储不支持的动作（例如原子 rename、symlink）。
#[derive(Debug, Clone)]
pub struct ProviderCaps {
    pub can_rename: bool,
    pub can_symlink: bool,
    pub can_write: bool,
    pub has_native_directories: bool,
}

/// 虚拟文件系统 provider trait。Phase 0 只定义当前 workspace 浏览所需的方法，
/// 不预先声明 `read`/`write`/`delete` 等未实现接口（避免空 impl 与 trait drift）。
#[async_trait::async_trait]
pub trait VfsProvider: Send + Sync {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError>;
    async fn open_directory(&self, path: &str)
    -> Result<(String, ListDirectoryResponse), ApiError>;
    /// 取单一条目的元数据。S3 用于「stat 一个对象」，Local 走 symlink_metadata。
    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError>;
    /// 声明 provider 的能力边界。
    fn capabilities(&self) -> ProviderCaps;
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn location_local_sets_scheme_and_path_with_none_connection() {
        let location = Location::local("/tmp/example");

        assert_eq!(location.scheme, Scheme::Local);
        assert!(location.connection_id.is_none());
        assert_eq!(location.path, "/tmp/example");
    }

    #[test]
    fn scheme_includes_s3_variant() {
        let local = Scheme::Local;
        let s3 = Scheme::S3;
        assert_ne!(local, s3);
    }
}
