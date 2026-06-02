use std::{io, path::PathBuf};

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use thiserror::Error;

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

    pub fn status_code(&self) -> StatusCode {
        match self {
            ApiError::UnknownMethod(_) => StatusCode::NOT_FOUND,
            ApiError::InvalidParams { .. } | ApiError::NotDirectory(_) => StatusCode::BAD_REQUEST,
            ApiError::FileSystemRead { source, .. } => match source.kind() {
                io::ErrorKind::NotFound => StatusCode::NOT_FOUND,
                io::ErrorKind::PermissionDenied => StatusCode::FORBIDDEN,
                _ => StatusCode::INTERNAL_SERVER_ERROR,
            },
            ApiError::BackgroundTask { .. } => StatusCode::INTERNAL_SERVER_ERROR,
        }
    }
}

#[derive(Debug, Serialize)]
struct ErrorResponse {
    ok: bool,
    error: ApiErrorBody,
}

#[derive(Debug, Serialize)]
struct ApiErrorBody {
    code: &'static str,
    message: String,
}

impl IntoResponse for ApiError {
    fn into_response(self) -> Response {
        let body = ErrorResponse {
            ok: false,
            error: ApiErrorBody {
                code: self.code(),
                message: self.message(),
            },
        };

        (self.status_code(), Json(body)).into_response()
    }
}
