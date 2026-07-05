//! Terminal Finder core library.
//!
//! 业务逻辑（workspace / terminal / state）以库形式提供：既能被 Swift 经 FFI 调用，
//! 也能被可选的 `server` feature（axum HTTP/WebSocket 适配层）复用。

pub mod command;
pub mod connection;
pub mod error;
pub mod ffi;
pub mod state;
pub mod terminal;
pub mod vfs;
pub mod workspace;

// 生成 UniFFI 跨语言脚手架（proc-macro 模式，命名空间默认取 crate 名）。
uniffi::setup_scaffolding!();

/// 日志时间格式化器，仅服务 server bin 的 tracing 订阅器，故只在 `server` feature 下编译。
#[cfg(feature = "server")]
pub mod clock;

/// axum HTTP/WebSocket 适配层，仅在 `server` feature 下编译。
#[cfg(feature = "server")]
pub mod api;

/// 核心版本号，来自 Cargo 包版本，供连通性检查与协议响应使用。
pub const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");
