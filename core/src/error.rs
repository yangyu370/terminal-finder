use std::{io, path::PathBuf};

use thiserror::Error;

/// 领域错误类型，传输无关。
///
/// `code()` / `message()` 是稳定的领域语义；HTTP 状态码映射与 JSON 响应体
/// 属于传输关注点，放在 `server` feature 下的 `crate::api::error` 适配层。
#[derive(Debug, Error)]
pub enum ApiError {
    #[error("unknown method: {0}")]
    UnknownMethod(String),
    #[error("invalid params for {method}: {message}")]
    InvalidParams { method: String, message: String },
    #[error("path is not a directory: {}", .0.display())]
    NotDirectory(PathBuf),
    #[error("failed to read filesystem path {}: {source}", path.display())]
    FileSystemRead { path: PathBuf, source: io::Error },
    #[error("background task failed during {operation}: {message}")]
    BackgroundTask {
        operation: &'static str,
        message: String,
    },

    // Phase 1c additions — cloud / connection-aware errors.
    #[error("network error during {operation}: {message}")]
    NetworkError {
        operation: &'static str,
        message: String,
    },
    #[error("authentication failed for connection {connection_id}: {message}")]
    AuthenticationFailed {
        connection_id: String,
        message: String,
    },
    #[error("object not found: {path}")]
    ObjectNotFound { path: String },
    #[error("connection not found: {connection_id}")]
    ConnectionNotFound { connection_id: String },
    #[error("provider error during {operation}: {message}")]
    ProviderError {
        operation: &'static str,
        message: String,
    },
    #[error("workspace runtime {runtime} unavailable: {message}")]
    WorkspaceRuntimeUnavailable { runtime: String, message: String },
    #[error("workspace provision failed for runtime {runtime}: {message}")]
    WorkspaceProvisionFailed { runtime: String, message: String },
    #[error("workspace start failed for runtime {runtime}: {message}")]
    WorkspaceStartFailed { runtime: String, message: String },
    #[error("mount failed: {message}")]
    MountFailed { message: String },
    #[error("mount timed out waiting for {mountpoint}")]
    MountTimeout { mountpoint: String },
}

impl ApiError {
    pub fn code(&self) -> &'static str {
        match self {
            ApiError::UnknownMethod(_) => "unknown_method",
            ApiError::InvalidParams { .. } => "invalid_params",
            ApiError::NotDirectory(_) => "not_directory",
            ApiError::FileSystemRead { .. } => "filesystem_read_failed",
            ApiError::BackgroundTask { .. } => "background_task_failed",
            ApiError::NetworkError { .. } => "network_error",
            ApiError::AuthenticationFailed { .. } => "authentication_failed",
            ApiError::ObjectNotFound { .. } => "object_not_found",
            ApiError::ConnectionNotFound { .. } => "connection_not_found",
            ApiError::ProviderError { .. } => "provider_error",
            ApiError::WorkspaceRuntimeUnavailable { .. } => "workspace_runtime_unavailable",
            ApiError::WorkspaceProvisionFailed { .. } => "workspace_provision_failed",
            ApiError::WorkspaceStartFailed { .. } => "workspace_start_failed",
            ApiError::MountFailed { .. } => "mount_failed",
            ApiError::MountTimeout { .. } => "mount_timeout",
        }
    }

    pub fn message(&self) -> String {
        match self {
            ApiError::UnknownMethod(method) => format!("unknown method: {method}"),
            ApiError::InvalidParams { method, message } => {
                format!("invalid params for {method}: {message}")
            }
            ApiError::NotDirectory(path) => {
                format!("path is not a directory: {}", path.display())
            }
            ApiError::FileSystemRead { path, source } => {
                format!(
                    "failed to read filesystem path {}: {source}",
                    path.display()
                )
            }
            ApiError::BackgroundTask { operation, message } => {
                format!("background task failed during {operation}: {message}")
            }
            ApiError::NetworkError { operation, message } => {
                format!("network error during {operation}: {message}")
            }
            ApiError::AuthenticationFailed {
                connection_id,
                message,
            } => {
                format!("authentication failed for connection {connection_id}: {message}")
            }
            ApiError::ObjectNotFound { path } => format!("object not found: {path}"),
            ApiError::ConnectionNotFound { connection_id } => {
                format!("connection not found: {connection_id}")
            }
            ApiError::ProviderError { operation, message } => {
                format!("provider error during {operation}: {message}")
            }
            ApiError::WorkspaceRuntimeUnavailable { runtime, message } => {
                format!("workspace runtime {runtime} unavailable: {message}")
            }
            ApiError::WorkspaceProvisionFailed { runtime, message } => {
                format!("workspace provision failed for runtime {runtime}: {message}")
            }
            ApiError::WorkspaceStartFailed { runtime, message } => {
                format!("workspace start failed for runtime {runtime}: {message}")
            }
            ApiError::MountFailed { message } => format!("mount failed: {message}"),
            ApiError::MountTimeout { mountpoint } => {
                format!("mount timed out waiting for {mountpoint}")
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::ApiError;

    #[test]
    fn error_codes_cover_new_variants() {
        let cases: Vec<(ApiError, &str)> = vec![
            (
                ApiError::NetworkError {
                    operation: "s3.list",
                    message: "boom".into(),
                },
                "network_error",
            ),
            (
                ApiError::AuthenticationFailed {
                    connection_id: "c1".into(),
                    message: "boom".into(),
                },
                "authentication_failed",
            ),
            (
                ApiError::ObjectNotFound { path: "k/v".into() },
                "object_not_found",
            ),
            (
                ApiError::ConnectionNotFound {
                    connection_id: "c1".into(),
                },
                "connection_not_found",
            ),
            (
                ApiError::ProviderError {
                    operation: "s3.stat",
                    message: "boom".into(),
                },
                "provider_error",
            ),
            (
                ApiError::WorkspaceRuntimeUnavailable {
                    runtime: "runtime".into(),
                    message: "boom".into(),
                },
                "workspace_runtime_unavailable",
            ),
            (
                ApiError::WorkspaceProvisionFailed {
                    runtime: "runtime".into(),
                    message: "boom".into(),
                },
                "workspace_provision_failed",
            ),
            (
                ApiError::WorkspaceStartFailed {
                    runtime: "runtime".into(),
                    message: "boom".into(),
                },
                "workspace_start_failed",
            ),
            (
                ApiError::MountFailed {
                    message: "boom".into(),
                },
                "mount_failed",
            ),
            (
                ApiError::MountTimeout {
                    mountpoint: "/mnt/minio".into(),
                },
                "mount_timeout",
            ),
        ];

        for (err, expected_code) in cases {
            assert_eq!(err.code(), expected_code, "code mismatch for {err:?}");
            assert!(!err.message().is_empty(), "message empty for {err:?}");
        }
    }
}
