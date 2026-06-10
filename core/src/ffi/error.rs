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
