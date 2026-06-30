pub mod binding;
pub mod connection;
pub mod registry;
pub mod session;
pub mod shell_integration;

/// PTY 的 axum WebSocket 适配层，仅在 `server` feature 下编译。
#[cfg(feature = "server")]
pub mod websocket;
