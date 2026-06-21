//! S3-compatible VfsProvider using OpenDAL 0.53 (`services-s3`).
//!
//! 写约束（在 spike Task 3.2 锁定）：
//! - MinIO 走 path-style，构造时 **不**调 `enable_virtual_host_style`
//! - R2 走 virtual-hosted，构造时**必须**调 `enable_virtual_host_style`
//! - region：MinIO 接受 "us-east-1"，R2 强制 "auto"
//!
//! capabilities 当前声明 `can_write: true` 是面向客户端 UI 的能力广播；
//! 真正的 write / delete / rename 在 PR 7/8 落地。在那之前 trait 上还没有这些方法，
//! 客户端调不到。

use std::sync::Arc;

use opendal::{EntryMode, ErrorKind, Operator, services::S3};

use crate::{
    connection::{ConnectionId, S3ConnectionConfig, S3Credential},
    error::ApiError,
    workspace::{DirectoryEntry, EntryKind as VfsEntryKind, dto::ListDirectoryResponse},
};

pub struct S3Provider {
    operator: Operator,
    connection_id: ConnectionId,
    base_prefix: String,
}

impl S3Provider {
    /// 构造一个 S3 provider。**不**触发网络请求，只组装 builder + Operator。
    /// 任何网络/鉴权错误延迟到首次 list/stat/read 才浮现。
    pub fn new(
        id: ConnectionId,
        config: &S3ConnectionConfig,
        credential: &S3Credential,
    ) -> Result<Arc<Self>, ApiError> {
        let mut builder = S3::default()
            .endpoint(&config.endpoint)
            .region(&config.region)
            .bucket(&config.bucket)
            .access_key_id(&credential.access_key_id)
            .secret_access_key(&credential.secret_access_key);

        // path-style 是 OpenDAL 0.53 的默认值。
        // R2 / 公网 AWS 走 virtual-hosted 时，client 在 config 里把 path_style 设为 false。
        if !config.path_style {
            builder = builder.enable_virtual_host_style();
        }

        let operator = Operator::new(builder)
            .map_err(|e| map_opendal_error("s3.new", id.0.clone(), e))?
            .finish();

        Ok(Arc::new(Self {
            operator,
            connection_id: id,
            base_prefix: config.base_prefix.clone(),
        }))
    }

    /// 把客户端传入的相对路径拼到 `base_prefix` 上。
    /// 约定：
    /// - 客户端永远不需要知道 `base_prefix`
    /// - 空路径或 `/` 表示 base_prefix 自身
    /// - 不会出现连续斜线，保证 S3 key 合法
    fn absolute_path(&self, relative: &str) -> String {
        let trimmed = relative.trim_start_matches('/');
        if self.base_prefix.is_empty() {
            trimmed.to_string()
        } else {
            let base = self.base_prefix.trim_end_matches('/');
            if trimmed.is_empty() {
                format!("{base}/")
            } else {
                format!("{base}/{trimmed}")
            }
        }
    }

    /// 把内部 S3 key 还原成客户端可见的相对路径，去掉 `base_prefix` 前缀。
    /// `absolute_path` 的反操作：客户端拿回相对路径，下次再调 list/stat 时
    /// `absolute_path` 会再把 base_prefix 加回去，**永远不重叠**。
    fn relative_path(&self, absolute: &str) -> String {
        if self.base_prefix.is_empty() {
            return absolute.to_string();
        }
        let base = self.base_prefix.trim_end_matches('/');
        if absolute == base {
            return String::new();
        }
        let base_with_slash = format!("{base}/");
        absolute
            .strip_prefix(&base_with_slash)
            .unwrap_or(absolute)
            .to_string()
    }
}

/// 把 opendal::Error 翻译成 ApiError，保持与 `error::ApiError::code()` 的稳定 code 一致。
fn map_opendal_error(
    operation: &'static str,
    connection_id: String,
    err: opendal::Error,
) -> ApiError {
    let message = err.to_string();
    match err.kind() {
        ErrorKind::NotFound => ApiError::ObjectNotFound { path: message },
        ErrorKind::PermissionDenied | ErrorKind::ConfigInvalid => ApiError::AuthenticationFailed {
            connection_id,
            message,
        },
        ErrorKind::Unexpected
            if message.to_lowercase().contains("timed out")
                || message.to_lowercase().contains("connection") =>
        {
            ApiError::NetworkError { operation, message }
        }
        _ => ApiError::ProviderError { operation, message },
    }
}

#[async_trait::async_trait]
impl crate::vfs::VfsProvider for S3Provider {
    async fn list(&self, path: &str) -> Result<ListDirectoryResponse, ApiError> {
        let prefix = self.absolute_path(path);
        // S3 列目录式查询要求 prefix 以 '/' 结束（空字符串表示 bucket 根）。
        let dir_prefix = if prefix.is_empty() || prefix.ends_with('/') {
            prefix.clone()
        } else {
            format!("{prefix}/")
        };

        let connection_id = self.connection_id.0.clone();
        // OpenDAL 0.53：`list_with` 的 `recursive` 默认 false，等价于走 S3 delimiter='/'
        // 的层级列表（只看 prefix 直接子项），无需手动设。
        let entries = self
            .operator
            .list_with(&dir_prefix)
            .await
            .map_err(|e| map_opendal_error("s3.list", connection_id.clone(), e))?;

        // 返回给客户端的路径必须去掉 base_prefix；客户端下次再传回时
        // `absolute_path` 会重新 prepend，保证 round-trip 不双前缀。
        let client_dir_prefix = self.relative_path(&dir_prefix);

        let mut directory_entries: Vec<DirectoryEntry> = entries
            .into_iter()
            .filter_map(|entry| {
                let raw_name = entry.name().to_string();
                // OpenDAL 在列结果里会把 prefix 自身回填一次（name == ""），过滤掉。
                if raw_name.is_empty() || raw_name == "/" {
                    return None;
                }
                let metadata = entry.metadata();
                let is_dir = matches!(metadata.mode(), EntryMode::DIR);
                let display_name = raw_name.trim_end_matches('/').to_string();
                Some(DirectoryEntry {
                    name: display_name.clone(),
                    path: format!("{client_dir_prefix}{display_name}"),
                    kind: if is_dir {
                        VfsEntryKind::Directory
                    } else {
                        VfsEntryKind::File
                    },
                    is_directory: is_dir,
                    size: if is_dir {
                        None
                    } else {
                        Some(metadata.content_length())
                    },
                    modified_at: metadata.last_modified().map(|t| t.to_rfc3339()),
                })
            })
            .collect();

        directory_entries.sort_by(|left, right| {
            right
                .is_directory
                .cmp(&left.is_directory)
                .then_with(|| left.name.to_lowercase().cmp(&right.name.to_lowercase()))
                .then_with(|| left.name.cmp(&right.name))
        });

        Ok(ListDirectoryResponse {
            path: client_dir_prefix,
            entries: directory_entries,
        })
    }

    async fn open_directory(
        &self,
        path: &str,
    ) -> Result<(String, ListDirectoryResponse), ApiError> {
        let listing = self.list(path).await?;
        let canonical = listing.path.clone();
        Ok((canonical, listing))
    }

    async fn stat(&self, path: &str) -> Result<DirectoryEntry, ApiError> {
        let key = self.absolute_path(path);
        let connection_id = self.connection_id.0.clone();
        let metadata = self
            .operator
            .stat(&key)
            .await
            .map_err(|e| map_opendal_error("s3.stat", connection_id, e))?;

        let is_dir = matches!(metadata.mode(), EntryMode::DIR);
        let name = key
            .trim_end_matches('/')
            .rsplit('/')
            .next()
            .unwrap_or("")
            .to_string();
        // Strip base_prefix for the client-facing path so stat → list/open round-trips.
        let client_path = self.relative_path(&key);

        Ok(DirectoryEntry {
            name,
            path: client_path,
            kind: if is_dir {
                VfsEntryKind::Directory
            } else {
                VfsEntryKind::File
            },
            is_directory: is_dir,
            size: if is_dir {
                None
            } else {
                Some(metadata.content_length())
            },
            modified_at: metadata.last_modified().map(|t| t.to_rfc3339()),
        })
    }

    fn capabilities(&self) -> crate::vfs::ProviderCaps {
        // can_write: true 在此刻是给客户端 UI 的能力广播；trait 上还没有 write 方法，
        // PR 7/8 落地后就直接生效。can_rename / can_symlink / has_native_directories
        // 反映 S3 对象语义：没有原子 rename、没有符号链接、目录是逻辑前缀。
        crate::vfs::ProviderCaps {
            can_rename: false,
            can_symlink: false,
            can_write: true,
            has_native_directories: false,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::vfs::VfsProvider;

    fn sample_config() -> S3ConnectionConfig {
        S3ConnectionConfig {
            display_name: "test".into(),
            endpoint: "http://localhost:9000".into(),
            region: "us-east-1".into(),
            bucket: "test-bucket".into(),
            base_prefix: String::new(),
            path_style: true,
        }
    }

    fn sample_credential() -> S3Credential {
        S3Credential {
            access_key_id: "minioadmin".into(),
            secret_access_key: "minioadmin".into(),
        }
    }

    #[test]
    fn s3_provider_new_constructs_without_network() {
        let cfg = sample_config();
        let cred = sample_credential();
        let id = ConnectionId("conn-1".into());
        let provider = S3Provider::new(id.clone(), &cfg, &cred).expect("constructs");
        assert_eq!(provider.connection_id, id);
        let caps = provider.capabilities();
        assert!(!caps.can_rename);
        assert!(!caps.can_symlink);
        assert!(caps.can_write);
        assert!(!caps.has_native_directories);
    }

    #[test]
    fn s3_provider_capabilities_declare_no_rename_no_symlink() {
        let cfg = sample_config();
        let cred = sample_credential();
        let id = ConnectionId("conn-2".into());
        let provider = S3Provider::new(id, &cfg, &cred).expect("constructs");
        let caps = provider.capabilities();
        assert!(!caps.can_rename, "S3 must declare can_rename=false");
        assert!(!caps.can_symlink, "S3 must declare can_symlink=false");
        assert!(
            !caps.has_native_directories,
            "S3 must declare has_native_directories=false"
        );
    }

    #[test]
    fn s3_provider_absolute_path_prepends_base_prefix() {
        let mut cfg = sample_config();
        cfg.base_prefix = "users/me".into();
        let id = ConnectionId("conn-3".into());
        let provider = S3Provider::new(id, &cfg, &sample_credential()).expect("constructs");

        assert_eq!(provider.absolute_path(""), "users/me/");
        assert_eq!(provider.absolute_path("/"), "users/me/");
        assert_eq!(provider.absolute_path("docs"), "users/me/docs");
        assert_eq!(provider.absolute_path("/docs"), "users/me/docs");
    }

    #[test]
    fn s3_provider_absolute_path_when_base_empty() {
        let cfg = sample_config();
        let id = ConnectionId("conn-4".into());
        let provider = S3Provider::new(id, &cfg, &sample_credential()).expect("constructs");
        assert_eq!(provider.absolute_path(""), "");
        assert_eq!(provider.absolute_path("docs"), "docs");
    }

    #[test]
    fn s3_provider_relative_path_strips_base_prefix() {
        let mut cfg = sample_config();
        cfg.base_prefix = "users/me".into();
        let id = ConnectionId("conn-rel-1".into());
        let provider = S3Provider::new(id, &cfg, &sample_credential()).expect("constructs");

        assert_eq!(provider.relative_path("users/me/"), "");
        assert_eq!(provider.relative_path("users/me"), "");
        assert_eq!(provider.relative_path("users/me/docs"), "docs");
        assert_eq!(
            provider.relative_path("users/me/docs/leaf.txt"),
            "docs/leaf.txt"
        );
    }

    #[test]
    fn s3_provider_relative_path_is_noop_when_base_empty() {
        let cfg = sample_config();
        let id = ConnectionId("conn-rel-2".into());
        let provider = S3Provider::new(id, &cfg, &sample_credential()).expect("constructs");

        assert_eq!(provider.relative_path(""), "");
        assert_eq!(provider.relative_path("alpha/beta"), "alpha/beta");
    }

    #[test]
    fn s3_provider_absolute_then_relative_round_trips_without_double_prefix() {
        // Regression guard for the 1c base_prefix double-prepend bug
        // (PR1e self-review I3). list() returns paths via relative_path();
        // the client then passes them back into the next list/stat call,
        // which runs absolute_path() again. The round-trip must NOT
        // accumulate base_prefix.
        let mut cfg = sample_config();
        cfg.base_prefix = "users/me".into();
        let id = ConnectionId("conn-roundtrip".into());
        let provider = S3Provider::new(id, &cfg, &sample_credential()).expect("constructs");

        for client_visible in ["", "docs", "docs/leaf.txt", "docs/sub/leaf.txt"] {
            let server_key = provider.absolute_path(client_visible);
            let bounced = provider.relative_path(&server_key);
            assert_eq!(
                bounced, client_visible,
                "absolute_path then relative_path must round-trip for {client_visible:?}"
            );
            // And one more round of absolute_path must NOT double-prepend.
            let key_again = provider.absolute_path(&bounced);
            assert_eq!(
                key_again, server_key,
                "second absolute_path must NOT double-prepend base_prefix for {client_visible:?}"
            );
        }
    }

    #[test]
    fn map_opendal_error_classifies_not_found() {
        let err = opendal::Error::new(ErrorKind::NotFound, "missing");
        let mapped = map_opendal_error("s3.list", "conn".into(), err);
        assert_eq!(mapped.code(), "object_not_found");
    }

    #[test]
    fn map_opendal_error_classifies_permission_denied_as_auth() {
        let err = opendal::Error::new(ErrorKind::PermissionDenied, "denied");
        let mapped = map_opendal_error("s3.list", "conn".into(), err);
        assert_eq!(mapped.code(), "authentication_failed");
    }
}

#[cfg(all(test, feature = "integration-test"))]
mod integration_tests {
    use super::*;
    use crate::vfs::VfsProvider;

    fn minio_provider() -> Arc<S3Provider> {
        let cfg = S3ConnectionConfig {
            display_name: "minio-integration".into(),
            endpoint: "http://localhost:9000".into(),
            region: "us-east-1".into(),
            bucket: "test-bucket".into(),
            base_prefix: String::new(),
            path_style: true,
        };
        let cred = S3Credential {
            access_key_id: "minioadmin".into(),
            secret_access_key: "minioadmin".into(),
        };
        S3Provider::new(ConnectionId("integration".into()), &cfg, &cred)
            .expect("MinIO provider constructs")
    }

    #[tokio::test]
    async fn list_root_returns_fixtures() {
        let provider = minio_provider();

        let listing = provider.list("").await.expect("list root");

        let names: Vec<_> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert!(
            names.contains(&"alpha"),
            "alpha/ should be present: {names:?}"
        );
        assert!(
            names.contains(&"gamma.txt"),
            "gamma.txt should be present: {names:?}"
        );
    }

    #[tokio::test]
    async fn list_nested_prefix_returns_beta() {
        let provider = minio_provider();

        let listing = provider.list("alpha").await.expect("list alpha");

        let names: Vec<_> = listing.entries.iter().map(|e| e.name.as_str()).collect();
        assert!(
            names.contains(&"beta.txt"),
            "alpha/beta.txt should be present: {names:?}"
        );
    }

    #[tokio::test]
    async fn stat_existing_object_returns_metadata() {
        let provider = minio_provider();

        let entry = provider.stat("gamma.txt").await.expect("stat gamma.txt");

        assert!(!entry.is_directory);
        assert!(entry.size.unwrap_or(0) > 0);
    }

    #[tokio::test]
    async fn stat_missing_object_returns_not_found() {
        let provider = minio_provider();

        let err = provider
            .stat("missing.txt")
            .await
            .expect_err("missing should fail");

        assert_eq!(err.code(), "object_not_found");
    }

    #[tokio::test]
    async fn list_with_bad_credentials_returns_auth_error() {
        let cfg = S3ConnectionConfig {
            display_name: "bad-creds".into(),
            endpoint: "http://localhost:9000".into(),
            region: "us-east-1".into(),
            bucket: "test-bucket".into(),
            base_prefix: String::new(),
            path_style: true,
        };
        let cred = S3Credential {
            access_key_id: "wrong".into(),
            secret_access_key: "wrong".into(),
        };
        let provider =
            S3Provider::new(ConnectionId("bad".into()), &cfg, &cred).expect("constructs");

        let err = provider.list("").await.expect_err("auth should fail");

        assert!(matches!(
            err.code(),
            "authentication_failed" | "provider_error"
        ));
    }
}
