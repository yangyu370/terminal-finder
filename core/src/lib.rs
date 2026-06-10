//! Terminal Finder core library.
//!
//! 业务逻辑（workspace / terminal / state）以库形式提供：既能被 Swift 经 FFI 调用，
//! 也能被可选的 `server` feature（axum HTTP/WebSocket 适配层）复用。

pub mod clock;
pub mod error;
pub mod state;
pub mod terminal;
pub mod workspace;

/// axum HTTP/WebSocket 适配层，仅在 `server` feature 下编译。
#[cfg(feature = "server")]
pub mod api;

/// 核心版本号，来自 Cargo 包版本，供连通性检查与协议响应使用。
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
