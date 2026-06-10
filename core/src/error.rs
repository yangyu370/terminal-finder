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
}

impl ApiError {
    pub fn code(&self) -> &'static str {
        match self {
            ApiError::UnknownMethod(_) => "unknown_method",
            ApiError::InvalidParams { .. } => "invalid_params",
            ApiError::NotDirectory(_) => "not_directory",
            ApiError::FileSystemRead { .. } => "filesystem_read_failed",
            ApiError::BackgroundTask { .. } => "background_task_failed",
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
        }
    }
}
