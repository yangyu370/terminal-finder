//! UniFFI facade：进程内暴露给 Swift 的接口层。
//!
//! `CoreHandle` 是被 Swift 持有的入口对象，内部封装 `AppState`（业务事实来源）。
//! 这里只做「协议响应 ↔ 跨边界 DTO」的转接，不写业务逻辑——逻辑仍在 `workspace` 等模块。

pub mod dto;
pub mod error;
pub mod terminal;

use std::{path::PathBuf, sync::Arc};

use crate::{
    state::AppState,
    workspace::{self, dto::ListDirectoryParams, dto::OpenDirectoryParams},
};

pub use dto::{
    DirectoryEntryDto, DirectoryListingDto, EntryKindDto, OpenDirectoryDto, PingInfo,
    WorkspaceStateDto,
};
pub use error::CoreError;
pub use terminal::TerminalEventListener;

/// 服务标识，与 `protocol/README.md` 及旧 `core::ping` 保持一致。
const SERVICE_NAME: &str = "terminal-finder-core";

/// 被 Swift 持有的核心句柄。`#[derive(uniffi::Object)]` 让它以引用（Arc）形式跨边界传递。
#[derive(uniffi::Object)]
pub struct CoreHandle {
    state: AppState,
}

#[uniffi::export]
impl CoreHandle {
    /// 构造一个核心句柄。Swift 侧 `CoreHandle()` 即可初始化。
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: AppState::new(crate::CORE_VERSION),
        })
    }

    /// 连通性检查，对应 `core.ping`。同步、无 I/O。
    pub fn ping(&self) -> PingInfo {
        PingInfo {
            service: SERVICE_NAME.to_string(),
            version: self.state.version.to_string(),
        }
    }

    /// 当前工作区状态，对应 `workspace.getState`。同步、只读内存状态。
    pub fn workspace_state(&self) -> WorkspaceStateDto {
        workspace::get_state(&self.state).state.into()
    }

    /// 创建 PTY 会话，对应 `terminal.create`。返回 sessionId；
    /// 输出 / 退出 / 错误经 `listener` 回调送达（替代 `/terminal` WebSocket 下行流）。
    pub fn create_terminal(
        &self,
        cwd: Option<String>,
        cols: u16,
        rows: u16,
        listener: Arc<dyn TerminalEventListener>,
    ) -> Result<String, CoreError> {
        terminal::create_terminal(&self.state, cwd, cols, rows, listener)
    }

    /// 写入终端输入，对应 `terminal.input`。高频路径：同步、快返回、无 base64。
    pub fn send_terminal_input(&self, session_id: String, data: Vec<u8>) -> Result<(), CoreError> {
        terminal::send_terminal_input(&self.state, session_id, data)
    }

    /// 调整 PTY 尺寸，对应 `terminal.resize`。
    pub fn resize_terminal(
        &self,
        session_id: String,
        cols: u16,
        rows: u16,
    ) -> Result<(), CoreError> {
        terminal::resize_terminal(&self.state, session_id, cols, rows)
    }

    /// 关闭会话并终止 PTY 进程，对应 `terminal.close`。
    /// 进程的实际结束仍由 `listener` 的 `on_exit` 报告。
    pub fn close_terminal(&self, session_id: String) -> Result<(), CoreError> {
        terminal::close_terminal(&self.state, session_id)
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreHandle {
    /// 打开目录，对应 `workspace.openDirectory`。异步：内部走 spawn_blocking 读文件系统。
    pub async fn open_directory(&self, path: String) -> Result<OpenDirectoryDto, CoreError> {
        let params = OpenDirectoryParams {
            path: PathBuf::from(path),
        };
        let response = workspace::open_directory(&self.state, params).await?;
        Ok(response.into())
    }

    /// 列目录，对应 `workspace.listDirectory`。异步：内部走 spawn_blocking 读文件系统。
    pub async fn list_directory(&self, path: String) -> Result<DirectoryListingDto, CoreError> {
        let params = ListDirectoryParams {
            path: PathBuf::from(path),
        };
        let response = workspace::list_directory(params).await?;
        Ok(response.into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ping_reports_service_and_version() {
        let handle = CoreHandle::new();
        let info = handle.ping();

        assert_eq!(info.service, SERVICE_NAME);
        assert_eq!(info.version, crate::CORE_VERSION);
    }

    #[test]
    fn workspace_state_exposes_root_and_current_directory() {
        let handle = CoreHandle::new();
        let state = handle.workspace_state();

        assert!(!state.workspace_root.is_empty());
        assert!(!state.current_directory.is_empty());
    }

    #[tokio::test]
    async fn list_directory_returns_entries_for_a_known_directory() {
        let handle = CoreHandle::new();
        let dir = std::env::temp_dir().join("tf_core_ffi_list_directory_test");
        std::fs::create_dir_all(&dir).expect("temp dir creates");
        std::fs::write(dir.join("entry.txt"), b"x").expect("temp file writes");

        let listing = handle
            .list_directory(dir.to_string_lossy().into_owned())
            .await
            .expect("known directory lists");

        let _ = std::fs::remove_dir_all(&dir);

        assert!(!listing.path.is_empty());
        let entry = listing
            .entries
            .iter()
            .find(|entry| entry.name == "entry.txt")
            .expect("created file appears in listing");
        assert!(matches!(entry.kind, EntryKindDto::File));
        assert!(!entry.is_directory);
    }

    #[tokio::test]
    async fn open_directory_rejects_a_file() {
        let handle = CoreHandle::new();
        let file = std::env::temp_dir().join("tf_core_ffi_open_directory_test");
        std::fs::write(&file, b"not a directory").expect("temp file writes");

        let error = handle
            .open_directory(file.to_string_lossy().into_owned())
            .await
            .expect_err("opening a file must fail");

        let _ = std::fs::remove_file(&file);

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "not_directory");
    }
}
