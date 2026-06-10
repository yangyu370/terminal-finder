//! `ApiError` 的 axum HTTP 适配层。
//!
//! 把领域错误（`crate::error::ApiError`）映射到 HTTP 状态码与 RPC JSON 响应体，
//! 仅在 `server` feature 下编译。`status_code()` 作为 inherent 方法挂在 `ApiError`
//! 上，调用点（如 `api::rpc`）无需改动。

use axum::{
    Json,
    http::StatusCode,
    response::{IntoResponse, Response},
};
use serde::Serialize;
use std::io;

use crate::error::ApiError;

impl ApiError {
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
