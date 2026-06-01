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
        let (status, code, message) = match self {
            ApiError::UnknownMethod(method) => (
                StatusCode::NOT_FOUND,
                "unknown_method",
                format!("unknown method: {method}"),
            ),
        };

        let body = ErrorResponse {
            ok: false,
            error: ApiErrorBody { code, message },
        };

        (status, Json(body)).into_response()
    }
}
