//! Connection 模型：S3 / 未来扩展 (SFTP / Docker) 的配置与凭据容器。
//!
//! 凭据安全约束：
//! - `S3Credential` 实现自定义 `Debug` 输出 `***` 掩码，绝不暴露明文。
//! - 凭据仅经 FFI 由 client 一次性传入，在 `ConnectionRegistry` 的内存里持有。
//! - 严禁 `tracing` / `println` / `serde::Serialize` 暴露 `access_key_id` / `secret_access_key`。

use std::fmt;

pub mod registry;
pub use registry::ConnectionRegistry;

/// 连接唯一标识。生成规则：UUID v4 字符串。
#[derive(Debug, Clone, PartialEq, Eq, Hash)]
pub struct ConnectionId(pub String);

impl fmt::Display for ConnectionId {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.0)
    }
}

/// 连接类型。Phase 1 只有 S3。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionKind {
    S3,
}

/// S3 连接配置。不含凭据。
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct S3ConnectionConfig {
    pub display_name: String,
    pub endpoint: String,
    pub region: String,
    pub bucket: String,
    pub base_prefix: String,
    pub path_style: bool,
}

/// 连接配置（enum dispatch，未来可加 Sftp / Docker）。
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum ConnectionConfig {
    S3(S3ConnectionConfig),
}

impl ConnectionConfig {
    pub fn display_name(&self) -> &str {
        match self {
            ConnectionConfig::S3(config) => &config.display_name,
        }
    }

    pub fn kind(&self) -> ConnectionKind {
        match self {
            ConnectionConfig::S3(_) => ConnectionKind::S3,
        }
    }
}

/// S3 凭据。
///
/// 安全约束：
/// - **绝不** derive `Debug` —— 自定义 `Debug` 输出 `***`。
/// - **绝不** derive `serde::Serialize` —— 序列化即泄漏，没有合法用例。
#[derive(Clone)]
pub struct S3Credential {
    pub access_key_id: String,
    pub secret_access_key: String,
}

impl fmt::Debug for S3Credential {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.debug_struct("S3Credential")
            .field("access_key_id", &"***")
            .field("secret_access_key", &"***")
            .finish()
    }
}

/// 凭据（enum dispatch）。
#[derive(Debug, Clone)]
pub enum Credential {
    S3(S3Credential),
}
