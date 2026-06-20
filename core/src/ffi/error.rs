//! 跨 FFI 边界的错误类型。
//!
//! 把领域错误 `crate::error::ApiError` 映射成 Swift 可见的 `CoreError`，
//! 保留 `protocol/README.md` 约定的稳定错误 `code` 与 `message`。

use crate::error::ApiError;

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CoreError {
    /// 一次 RPC 调用失败。`code` 是稳定的领域错误码（如 `not_directory`），
    /// `message` 是面向人类的描述。
    #[error("{message}")]
    Rpc { code: String, message: String },
}

impl From<ApiError> for CoreError {
    fn from(error: ApiError) -> Self {
        CoreError::Rpc {
            code: error.code().to_string(),
            message: error.message(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_core_error_maps_all_api_errors() {
        let cases = vec![
            ApiError::UnknownMethod("foo".into()),
            ApiError::InvalidParams {
                method: "m".into(),
                message: "x".into(),
            },
            ApiError::NotDirectory(std::path::PathBuf::from("/")),
            ApiError::BackgroundTask {
                operation: "op",
                message: "x".into(),
            },
            ApiError::NetworkError {
                operation: "op",
                message: "x".into(),
            },
            ApiError::AuthenticationFailed {
                connection_id: "c".into(),
                message: "x".into(),
            },
            ApiError::ObjectNotFound { path: "k".into() },
            ApiError::ConnectionNotFound {
                connection_id: "c".into(),
            },
            ApiError::ProviderError {
                operation: "op",
                message: "x".into(),
            },
        ];

        for err in cases {
            let expected_code = err.code().to_string();
            let expected_message = err.message();
            let core_err: CoreError = err.into();
            let CoreError::Rpc { code, message } = core_err;
            assert_eq!(code, expected_code, "code mismatch");
            assert_eq!(message, expected_message, "message mismatch");
        }
    }
}
