pub mod registry;
pub mod session;

/// PTY 的 axum WebSocket 适配层，仅在 `server` feature 下编译。
#[cfg(feature = "server")]
pub mod websocket;
