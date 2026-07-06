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
    TerminalDirectoryChangeDto, TerminalWorkingDirectoryUpdateDto, WorkspaceStateDto,
    WorkspaceTerminalBindingDto, WorkspaceTerminalCreateDto, WorkspaceTerminalKindDto,
    WorkspaceTerminalSyncCapabilityDto,
};
pub use error::CoreError;
pub use terminal::TerminalEventListener;

/// 服务标识，与 `protocol/README.md` 及旧 `core::ping` 保持一致。
const SERVICE_NAME: &str = "terminal-finder-core";

/// 被 Swift 持有的核心句柄。`#[derive(uniffi::Object)]` 让它以引用（Arc）形式跨边界传递。
#[derive(uniffi::Object)]
pub struct CoreHandle {
    state: AppState,
    commands: crate::command::CommandRegistry,
}

#[uniffi::export]
impl CoreHandle {
    /// 构造一个核心句柄。Swift 侧 `CoreHandle()` 即可初始化。
    #[uniffi::constructor]
    pub fn new() -> Arc<Self> {
        Arc::new(Self {
            state: AppState::new(crate::CORE_VERSION),
            commands: crate::command::CommandRegistry::new(),
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

    /// List available backend commands as a JSON descriptor array.
    pub fn command_list(&self) -> String {
        serde_json::to_string(&self.commands.list()).unwrap_or_else(|_| "[]".into())
    }

    /// Describe one backend command as JSON.
    pub fn command_describe(&self, id: String) -> Result<String, CoreError> {
        use crate::error::ApiError;

        let descriptor = self
            .commands
            .describe(&id)
            .ok_or_else(|| ApiError::UnknownMethod(id.clone()))?;
        serde_json::to_string(&descriptor).map_err(|err| {
            ApiError::ProviderError {
                operation: "command.describe",
                message: err.to_string(),
            }
            .into()
        })
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

    /// Register an S3 connection. Credentials live in-memory only;
    /// the client (Swift) owns Keychain persistence and re-passes
    /// credentials on app restart.
    ///
    /// SECURITY: credentials are received by value across the FFI
    /// boundary but MUST NEVER be logged — not at info, not at debug.
    #[allow(clippy::too_many_arguments)]
    pub fn connection_create(
        &self,
        display_name: String,
        endpoint: String,
        region: String,
        bucket: String,
        base_prefix: String,
        path_style: bool,
        access_key_id: String,
        secret_access_key: String,
    ) -> String {
        use crate::connection::{ConnectionConfig, Credential, S3ConnectionConfig, S3Credential};

        let config = ConnectionConfig::S3(S3ConnectionConfig {
            display_name,
            endpoint,
            region,
            bucket,
            base_prefix,
            path_style,
        });
        let credential = Credential::S3(S3Credential {
            access_key_id,
            secret_access_key,
        });
        let id = self.state.connections().create(config, credential);
        tracing::info!(method = "connection.create", "connection registered");
        id.0
    }

    /// Re-register a connection using a caller-provided id. Intended for
    /// app startup: the client side persists `connection_id` alongside the
    /// non-sensitive config, then calls this on launch so the in-memory
    /// `ConnectionRegistry` rebinds the SAME id from the previous run.
    /// Without this the client would mint a new id on every restart and
    /// the persisted sidebar rows would all reference dead ids.
    ///
    /// SECURITY: same credential handling rules as `connection_create` —
    /// arguments are received by value across FFI but MUST NOT be logged.
    #[allow(clippy::too_many_arguments)]
    pub fn connection_restore(
        &self,
        connection_id: String,
        display_name: String,
        endpoint: String,
        region: String,
        bucket: String,
        base_prefix: String,
        path_style: bool,
        access_key_id: String,
        secret_access_key: String,
    ) -> Result<(), crate::ffi::error::CoreError> {
        use crate::connection::{
            ConnectionConfig, ConnectionId, Credential, S3ConnectionConfig, S3Credential,
        };

        let config = ConnectionConfig::S3(S3ConnectionConfig {
            display_name,
            endpoint,
            region,
            bucket,
            base_prefix,
            path_style,
        });
        let credential = Credential::S3(S3Credential {
            access_key_id,
            secret_access_key,
        });
        let id = ConnectionId(connection_id);
        self.state
            .connections()
            .insert_with_id(id, config, credential)?;
        tracing::info!(method = "connection.restore", "connection rehydrated");
        Ok(())
    }

    /// List all registered connections (no credentials returned).
    pub fn connection_list(&self) -> Vec<crate::ffi::dto::ConnectionInfoDto> {
        use crate::connection::ConnectionConfig;

        self.state
            .connections()
            .list()
            .into_iter()
            .map(|entry| {
                let ConnectionConfig::S3(cfg) = &entry.config;
                crate::ffi::dto::ConnectionInfoDto {
                    connection_id: entry.id.0.clone(),
                    display_name: cfg.display_name.clone(),
                    endpoint: cfg.endpoint.clone(),
                    bucket: cfg.bucket.clone(),
                    base_prefix: cfg.base_prefix.clone(),
                }
            })
            .collect()
    }

    /// Capability flags for the provider behind `connection_id`. Forces the
    /// provider into the cache via `resolve_provider` so the caller sees the
    /// real OpenDAL-backed caps (not the registry's pre-construction guess).
    pub fn connection_capabilities(
        &self,
        connection_id: String,
    ) -> Result<crate::ffi::dto::ProviderCapsDto, crate::ffi::error::CoreError> {
        let (_, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            Some(connection_id.as_str()),
            std::path::Path::new(""),
        )?;
        let caps = provider.capabilities();
        Ok(crate::ffi::dto::ProviderCapsDto {
            can_rename: caps.can_rename,
            can_symlink: caps.can_symlink,
            can_write: caps.can_write,
            has_native_directories: caps.has_native_directories,
        })
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreHandle {
    /// Remove a connection and its in-memory credentials. Also drops any
    /// cached `S3Provider` and runtime mount for that connection so a future
    /// call with the same `connection_id` cannot reuse stale resources.
    /// Returns `Err(ConnectionNotFound)` if unknown.
    pub async fn connection_remove(
        &self,
        connection_id: String,
    ) -> Result<(), crate::ffi::error::CoreError> {
        crate::workspace::service::remove_connection(&self.state, &connection_id).await?;
        Ok(())
    }

    /// 打开目录，对应 `workspace.openDirectory`。异步：local 走 spawn_blocking，
    /// S3 由 OpenDAL 原生 async 直发。`connection_id == None` 命中本地 workspace；
    /// 传入注册过的 S3 connection id 时落到对应 S3Provider。
    pub async fn open_directory(
        &self,
        path: String,
        connection_id: Option<String>,
    ) -> Result<OpenDirectoryDto, CoreError> {
        let params = OpenDirectoryParams {
            path: PathBuf::from(path),
            connection_id,
        };
        let response = workspace::open_directory(&self.state, params).await?;
        Ok(response.into())
    }

    /// 列目录，对应 `workspace.listDirectory`。语义与 `open_directory` 相同的
    /// connection 路由规则。
    pub async fn list_directory(
        &self,
        path: String,
        connection_id: Option<String>,
    ) -> Result<DirectoryListingDto, CoreError> {
        let params = ListDirectoryParams {
            path: PathBuf::from(path),
            connection_id,
        };
        let response = workspace::list_directory(&self.state, params).await?;
        Ok(response.into())
    }

    /// Invoke a backend command with JSON params and return JSON result.
    pub async fn command_invoke(
        &self,
        id: String,
        params_json: String,
    ) -> Result<String, CoreError> {
        use crate::error::ApiError;

        if self.commands.describe(&id).is_none() {
            return Err(ApiError::UnknownMethod(id).into());
        }

        let params = serde_json::from_str(&params_json).map_err(|err| ApiError::InvalidParams {
            method: id.clone(),
            message: err.to_string(),
        })?;
        let result = self.commands.invoke(&self.state, &id, params).await?;

        serde_json::to_string(&result).map_err(|err| {
            ApiError::ProviderError {
                operation: "command.invoke",
                message: err.to_string(),
            }
            .into()
        })
    }

    /// Open a terminal rooted at a mounted connection workspace.
    pub async fn create_connection_terminal(
        &self,
        connection_id: String,
        cols: u16,
        rows: u16,
        listener: Arc<dyn TerminalEventListener>,
    ) -> Result<String, CoreError> {
        terminal::create_connection_terminal(&self.state, connection_id, cols, rows, listener).await
    }

    /// Create a terminal bound to the current workspace context.
    pub async fn create_workspace_terminal(
        &self,
        cols: u16,
        rows: u16,
        listener: Arc<dyn TerminalEventListener>,
    ) -> Result<WorkspaceTerminalCreateDto, CoreError> {
        terminal::create_workspace_terminal(&self.state, cols, rows, listener).await
    }

    /// Record and validate a terminal cwd reported by SwiftTerm's OSC 7 callback.
    pub async fn update_terminal_working_directory(
        &self,
        session_id: String,
        directory_url: String,
    ) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError> {
        terminal::update_terminal_working_directory(&self.state, session_id, directory_url).await
    }

    /// Recompute terminal-vs-Finder cwd status from the latest recorded terminal cwd.
    pub async fn compare_terminal_working_directory(
        &self,
        session_id: String,
    ) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError> {
        terminal::compare_terminal_working_directory(&self.state, session_id).await
    }

    /// Queue a controlled directory change for a local workspace terminal.
    pub async fn change_terminal_directory(
        &self,
        session_id: String,
        target_directory: String,
    ) -> Result<TerminalDirectoryChangeDto, CoreError> {
        terminal::change_terminal_directory(&self.state, session_id, target_directory).await
    }

    /// Tear down the current workspace runtime instance.
    pub async fn shutdown_workspace(&self) -> Result<(), CoreError> {
        self.state.workspace_runtime().teardown().await?;
        self.state.mounts().clear();
        Ok(())
    }

    /// 读取 `local_source` 并写到 `remote_path`（local 或 S3）。
    /// 上传前后各发一次 `transfer_progress` 事件（0 / total），让 Swift
    /// 端可以驱动进度条。50 MiB 上限来自 `VfsProvider::read` 的对称约束:
    /// 这里复用同一个 inline 读取语义，避免临时落盘。
    pub async fn upload_file(
        &self,
        connection_id: Option<String>,
        remote_path: String,
        local_source: String,
    ) -> Result<(), CoreError> {
        crate::workspace::service::upload_file(
            &self.state,
            connection_id.as_deref(),
            &remote_path,
            &local_source,
        )
        .await?;
        Ok(())
    }

    /// 删除 `path` 指向的对象/文件/目录。Local 区分文件 / 目录，目录走
    /// `remove_dir_all`；S3 同样按 stat 探测 `<key>/` 是否为目录 marker，
    /// 是就走 `remove_all(<key>/)` 递归删除 marker + 子对象，否则按单 key
    /// 删。两边行为对齐：删一个非空目录会把里面所有内容一并清掉。
    pub async fn delete_entry(
        &self,
        connection_id: Option<String>,
        path: String,
    ) -> Result<(), CoreError> {
        crate::workspace::service::delete_entry(&self.state, connection_id.as_deref(), &path)
            .await?;
        Ok(())
    }

    /// 在 `path` 上创建目录（Local: `create_dir_all`；S3: 零字节 marker）。
    /// 客户端应通过 `connection_capabilities().has_native_directories`
    /// 判断是否需要在 UI 上提示"零字节占位"语义。
    pub async fn create_remote_directory(
        &self,
        connection_id: Option<String>,
        path: String,
    ) -> Result<(), CoreError> {
        crate::workspace::service::create_remote_directory(
            &self.state,
            connection_id.as_deref(),
            &path,
        )
        .await?;
        Ok(())
    }

    /// 重命名/移动 `from` → `to`。S3 是 copy + delete（**非原子**），客户端
    /// 应通过 `connection_capabilities().can_rename == false` 在 UI 上提示。
    /// `from` 和 `to` 必须落在同一个 connection 上；本方法不做跨 provider 搬运。
    pub async fn rename_entry(
        &self,
        connection_id: Option<String>,
        from: String,
        to: String,
    ) -> Result<(), CoreError> {
        crate::workspace::service::rename_entry(&self.state, connection_id.as_deref(), &from, &to)
            .await?;
        Ok(())
    }

    /// 读取 `remote_path`（local 或 S3）后写入 `local_destination`。
    /// 50 MiB 上限由 `VfsProvider::read` 强制；超限返回 `provider_error`。
    /// 二进制写盘走 `spawn_blocking`，避免阻塞 tokio runtime。
    pub async fn download_file(
        &self,
        connection_id: Option<String>,
        remote_path: String,
        local_destination: String,
    ) -> Result<(), CoreError> {
        crate::workspace::service::download_file(
            &self.state,
            connection_id.as_deref(),
            &remote_path,
            &local_destination,
        )
        .await?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::mpsc;
    use uuid::Uuid;

    use crate::connection::ConnectionId;
    use crate::error::ApiError;
    use crate::terminal::session::{SessionHandle, TerminalEvent};
    use crate::workspace::{
        MountHandle, MountSpec, RuntimeStatus, TerminalOpenContext, WorkspaceRuntime,
    };

    #[derive(Default)]
    struct TestRuntime {
        unmount_calls: AtomicUsize,
    }

    #[async_trait]
    impl WorkspaceRuntime for TestRuntime {
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus::Ready
        }

        async fn ensure_ready(&self) -> Result<(), ApiError> {
            Ok(())
        }

        fn propose_mountpoint(&self, display_name: &str, _taken: &[String]) -> String {
            format!("test://{display_name}")
        }

        async fn mount(&self, spec: MountSpec) -> Result<MountHandle, ApiError> {
            Ok(MountHandle {
                mountpoint: spec.mountpoint,
            })
        }

        async fn is_exposed(&self, _mountpoint: &str) -> Result<bool, ApiError> {
            Ok(true)
        }

        async fn unmount(&self, _mountpoint: &str) -> Result<(), ApiError> {
            self.unmount_calls.fetch_add(1, Ordering::SeqCst);
            Ok(())
        }

        async fn open_terminal(
            &self,
            _ctx: TerminalOpenContext,
            _cols: u16,
            _rows: u16,
            _events: mpsc::Sender<TerminalEvent>,
        ) -> Result<SessionHandle, ApiError> {
            Ok(SessionHandle::for_test(Uuid::new_v4()))
        }

        async fn teardown(&self) -> Result<(), ApiError> {
            Ok(())
        }
    }

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
    async fn shutdown_workspace_clears_mount_registry() {
        let handle = Arc::new(CoreHandle {
            state: AppState::new_with_workspace_runtime("test", Arc::new(TestRuntime::default())),
            commands: crate::command::CommandRegistry::new(),
        });
        let id = ConnectionId("c1".into());
        handle
            .state
            .mounts()
            .get_or_reserve(&id, |_taken| "test://mount".into());
        handle.state.mounts().mark_ready(&id);
        assert!(handle.state.mounts().is_mounted(&id));

        handle
            .shutdown_workspace()
            .await
            .expect("shutdown succeeds");

        assert!(!handle.state.mounts().is_mounted(&id));
    }

    #[tokio::test]
    async fn list_directory_returns_entries_for_a_known_directory() {
        let handle = CoreHandle::new();
        let dir = std::env::temp_dir().join("tf_core_ffi_list_directory_test");
        std::fs::create_dir_all(&dir).expect("temp dir creates");
        std::fs::write(dir.join("entry.txt"), b"x").expect("temp file writes");

        let listing = handle
            .list_directory(dir.to_string_lossy().into_owned(), None)
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
            .open_directory(file.to_string_lossy().into_owned(), None)
            .await
            .expect_err("opening a file must fail");

        let _ = std::fs::remove_file(&file);

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "not_directory");
    }

    #[test]
    fn command_list_contains_workspace_command_ids() {
        let handle = CoreHandle::new();

        let descriptors = handle.command_list();
        let descriptors: serde_json::Value =
            serde_json::from_str(&descriptors).expect("command list returns JSON");
        let ids: Vec<&str> = descriptors
            .as_array()
            .expect("command list is an array")
            .iter()
            .filter_map(|descriptor| descriptor["id"].as_str())
            .collect();

        assert!(ids.contains(&"workspace.listDirectory"));
        assert!(ids.contains(&"workspace.openDirectory"));
    }

    #[test]
    fn command_describe_returns_descriptor_json() {
        let handle = CoreHandle::new();

        let descriptor = handle
            .command_describe("workspace.listDirectory".into())
            .expect("known command describes");
        let descriptor: serde_json::Value =
            serde_json::from_str(&descriptor).expect("descriptor returns JSON");

        assert_eq!(descriptor["id"], "workspace.listDirectory");
        assert_eq!(descriptor["category"], "workspace");
        assert_eq!(descriptor["destructive"], false);
        assert_eq!(descriptor["context_requirements"], serde_json::json!([]));
        assert_eq!(
            descriptor["params_schema"]["required"],
            serde_json::json!(["path"])
        );
        assert_eq!(
            descriptor["result_schema"]["required"],
            serde_json::json!(["path", "entries"])
        );
    }

    #[test]
    fn command_describe_unknown_id_returns_unknown_method() {
        let handle = CoreHandle::new();

        let error = handle
            .command_describe("no.such".into())
            .expect_err("unknown command id must fail");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_method");
    }

    #[tokio::test]
    async fn command_invoke_list_directory_returns_entries_for_a_known_directory() {
        let handle = CoreHandle::new();
        let dir = std::env::temp_dir().join("tf_core_ffi_command_invoke_list_directory_test");
        std::fs::create_dir_all(&dir).expect("temp dir creates");
        std::fs::write(dir.join("entry.txt"), b"x").expect("temp file writes");

        let result = handle
            .command_invoke(
                "workspace.listDirectory".into(),
                serde_json::json!({ "path": dir }).to_string(),
            )
            .await
            .expect("known directory lists through command invoke");

        let _ = std::fs::remove_dir_all(&dir);
        let result: serde_json::Value =
            serde_json::from_str(&result).expect("command invoke returns JSON");
        let names: Vec<&str> = result["entries"]
            .as_array()
            .expect("entries is an array")
            .iter()
            .filter_map(|entry| entry["name"].as_str())
            .collect();

        assert!(names.contains(&"entry.txt"));
    }

    #[tokio::test]
    async fn command_invoke_open_directory_file_path_propagates_domain_error() {
        let handle = CoreHandle::new();
        let file = std::env::temp_dir().join("tf_core_ffi_command_invoke_open_directory_file_test");
        std::fs::write(&file, b"not a directory").expect("temp file writes");

        let error = handle
            .command_invoke(
                "workspace.openDirectory".into(),
                serde_json::json!({ "path": file }).to_string(),
            )
            .await
            .expect_err("opening a file through command invoke must fail");

        let _ = std::fs::remove_file(&file);

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "not_directory");
    }

    #[tokio::test]
    async fn command_invoke_unknown_id_returns_unknown_method() {
        let handle = CoreHandle::new();

        let error = handle
            .command_invoke("no.such".into(), "{}".into())
            .await
            .expect_err("unknown command id must fail");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_method");
    }

    #[tokio::test]
    async fn command_invoke_unknown_id_takes_precedence_over_invalid_json() {
        let handle = CoreHandle::new();

        let error = handle
            .command_invoke("no.such".into(), "{".into())
            .await
            .expect_err("unknown command id must fail before params parsing");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_method");
    }

    #[tokio::test]
    async fn command_invoke_invalid_json_returns_invalid_params() {
        let handle = CoreHandle::new();

        let error = handle
            .command_invoke("workspace.listDirectory".into(), "{".into())
            .await
            .expect_err("invalid params JSON must fail");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "invalid_params");
    }
}

#[cfg(test)]
mod connection_ffi_tests {
    use super::*;
    use async_trait::async_trait;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::sync::mpsc;
    use uuid::Uuid;

    use crate::connection::ConnectionId;
    use crate::error::ApiError;
    use crate::terminal::session::{SessionHandle, TerminalEvent};
    use crate::workspace::{
        MountHandle, MountSpec, RuntimeStatus, TerminalOpenContext, WorkspaceRuntime,
    };

    #[derive(Default)]
    struct RecordingRuntime {
        unmount_calls: AtomicUsize,
        fail_unmount: std::sync::atomic::AtomicBool,
    }

    impl RecordingRuntime {
        fn unmount_calls(&self) -> usize {
            self.unmount_calls.load(Ordering::SeqCst)
        }

        fn failing_unmount() -> Self {
            Self {
                unmount_calls: AtomicUsize::new(0),
                fail_unmount: std::sync::atomic::AtomicBool::new(true),
            }
        }
    }

    #[async_trait]
    impl WorkspaceRuntime for RecordingRuntime {
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus::Ready
        }

        async fn ensure_ready(&self) -> Result<(), ApiError> {
            Ok(())
        }

        fn propose_mountpoint(&self, display_name: &str, _taken: &[String]) -> String {
            format!("test://{display_name}")
        }

        async fn mount(&self, spec: MountSpec) -> Result<MountHandle, ApiError> {
            Ok(MountHandle {
                mountpoint: spec.mountpoint,
            })
        }

        async fn is_exposed(&self, _mountpoint: &str) -> Result<bool, ApiError> {
            Ok(true)
        }

        async fn unmount(&self, _mountpoint: &str) -> Result<(), ApiError> {
            self.unmount_calls.fetch_add(1, Ordering::SeqCst);
            if self.fail_unmount.load(Ordering::SeqCst) {
                return Err(ApiError::MountFailed {
                    message: "unmount failed".into(),
                });
            }
            Ok(())
        }

        async fn open_terminal(
            &self,
            _ctx: TerminalOpenContext,
            _cols: u16,
            _rows: u16,
            _events: mpsc::Sender<TerminalEvent>,
        ) -> Result<SessionHandle, ApiError> {
            Ok(SessionHandle::for_test(Uuid::new_v4()))
        }

        async fn teardown(&self) -> Result<(), ApiError> {
            Ok(())
        }
    }

    fn handle() -> Arc<CoreHandle> {
        CoreHandle::new()
    }

    #[test]
    fn connection_create_and_list_returns_entry() {
        let h = handle();
        let id = h.connection_create(
            "test".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        );
        let listed = h.state.connections().list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].id.0, id);
        let crate::connection::ConnectionConfig::S3(cfg) = &listed[0].config;
        assert_eq!(cfg.display_name, "test");
        assert_eq!(cfg.endpoint, "http://localhost:9000");
        assert_eq!(cfg.bucket, "test-bucket");
        assert_eq!(cfg.base_prefix, "");
    }

    #[tokio::test]
    async fn connection_remove_makes_get_fail() {
        let h = handle();
        let id = h.connection_create(
            "test".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        );
        h.connection_remove(id.clone())
            .await
            .expect("remove succeeds");
        assert_eq!(h.connection_list().len(), 0);
        assert!(
            h.connection_remove(id).await.is_err(),
            "removing missing id is an error"
        );
    }

    #[test]
    fn connection_list_returns_empty_initially() {
        let h = handle();
        assert!(h.connection_list().is_empty());
    }

    #[test]
    fn connection_restore_uses_caller_supplied_id() {
        // The whole point of restore: the id round-trips between client-side
        // persistence and core's in-memory registry, so the sidebar rows the
        // client renders match what core will route on click.
        let h = handle();
        let preset = "26e3b59e-c346-4480-a25d-07c7f8e5b467";
        h.connection_restore(
            preset.into(),
            "Minio".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        )
        .expect("restore succeeds");
        let listed = h.connection_list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].connection_id, preset);
    }

    #[test]
    fn connection_restore_with_duplicate_id_returns_invalid_params() {
        let h = handle();
        let preset = "dup-id";
        h.connection_restore(
            preset.into(),
            "a".into(),
            "e".into(),
            "r".into(),
            "b".into(),
            "".into(),
            true,
            "k".into(),
            "s".into(),
        )
        .expect("first restore");
        let err = h
            .connection_restore(
                preset.into(),
                "a".into(),
                "e".into(),
                "r".into(),
                "b".into(),
                "".into(),
                true,
                "k".into(),
                "s".into(),
            )
            .expect_err("duplicate restore");
        let CoreError::Rpc { code, .. } = err;
        assert_eq!(code, "invalid_params");
    }

    #[tokio::test]
    async fn download_file_with_nil_connection_writes_to_local_path() {
        // Regression guard: download_file must route a Local read all the
        // way to a writable destination, with no S3 dependencies.
        use std::time::{SystemTime, UNIX_EPOCH};

        let label = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let src = std::env::temp_dir().join(format!("tf-ffi-download-src-{label}"));
        let dst = std::env::temp_dir().join(format!("tf-ffi-download-dst-{label}"));
        std::fs::write(&src, b"payload").expect("write source");

        let handle = CoreHandle::new();
        crate::workspace::service::download_file(
            &handle.state,
            None,
            &src.to_string_lossy(),
            &dst.to_string_lossy(),
        )
        .await
        .expect("download succeeds");

        let written = std::fs::read(&dst).expect("read dst");
        let _ = std::fs::remove_file(&src);
        let _ = std::fs::remove_file(&dst);

        assert_eq!(written, b"payload");
    }

    #[tokio::test]
    async fn upload_then_delete_roundtrip_on_local() {
        use std::time::{SystemTime, UNIX_EPOCH};

        let label = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let src = std::env::temp_dir().join(format!("tf-upload-src-{label}"));
        let dst = std::env::temp_dir().join(format!("tf-upload-dst-{label}"));
        std::fs::write(&src, b"payload").expect("write src");

        let handle = CoreHandle::new();
        crate::workspace::service::upload_file(
            &handle.state,
            None,
            &dst.to_string_lossy(),
            &src.to_string_lossy(),
        )
        .await
        .expect("upload succeeds");
        let written = std::fs::read(&dst).expect("dst exists");
        assert_eq!(written, b"payload");

        crate::workspace::service::delete_entry(&handle.state, None, &dst.to_string_lossy())
            .await
            .expect("delete succeeds");
        assert!(!dst.exists());

        let _ = std::fs::remove_file(&src);
    }

    #[tokio::test]
    async fn create_remote_directory_and_rename_on_local() {
        use std::time::{SystemTime, UNIX_EPOCH};

        let label = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let base = std::env::temp_dir().join(format!("tf-rename-{label}"));
        let from = base.join("from.txt");
        let to = base.join("to.txt");

        let handle = CoreHandle::new();
        crate::workspace::service::create_remote_directory(
            &handle.state,
            None,
            &base.to_string_lossy(),
        )
        .await
        .expect("mkdir");
        std::fs::write(&from, b"x").expect("seed from");
        crate::workspace::service::rename_entry(
            &handle.state,
            None,
            &from.to_string_lossy(),
            &to.to_string_lossy(),
        )
        .await
        .expect("rename");

        assert!(!from.exists());
        assert!(to.exists());
        let _ = std::fs::remove_dir_all(&base);
    }

    #[test]
    fn connection_capabilities_reports_local_caps_for_an_offline_s3_connection() {
        // capabilities() should still report the OpenDAL-backed flags even
        // before the first network call. We verify by registering an S3
        // connection with an unreachable endpoint; `connection_capabilities`
        // must succeed and report S3 caps (can_rename=false, etc).
        let h = handle();
        let id = h.connection_create(
            "test".into(),
            "http://127.0.0.1:1".into(),
            "us-east-1".into(),
            "x".into(),
            String::new(),
            true,
            "x".into(),
            "x".into(),
        );
        let caps = h.connection_capabilities(id).expect("caps lookup");
        assert!(!caps.can_rename);
        assert!(!caps.can_symlink);
        assert!(caps.can_write);
        assert!(!caps.has_native_directories);
    }

    #[tokio::test]
    async fn download_file_with_unknown_connection_returns_error() {
        let handle = CoreHandle::new();
        let err = crate::workspace::service::download_file(
            &handle.state,
            Some("ghost"),
            "ignored",
            &std::env::temp_dir()
                .join("tf-never-written")
                .to_string_lossy(),
        )
        .await
        .expect_err("ghost connection id must error");

        assert_eq!(err.code(), "connection_not_found");
    }

    #[tokio::test]
    async fn connection_remove_drops_cached_provider() {
        // Regression guard for C1: connection_remove must also drop any
        // S3Provider cached in ProviderRegistry::by_connection. Without
        // this, the removed connection's OpenDAL Operator (and its
        // credentials) would live on until the AppState is dropped.
        use crate::connection::ConnectionId;
        use crate::vfs::{LocalFsProvider, VfsProvider};

        let h = handle();
        let id_string = h.connection_create(
            "test".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        );
        let id = ConnectionId(id_string.clone());
        // Simulate the cache as if open_directory had run (LocalFsProvider
        // stands in for any VfsProvider — the test only cares that the slot
        // is occupied and then dropped).
        let dummy: Arc<dyn VfsProvider> = Arc::new(LocalFsProvider);
        h.state.providers().register_connection(&id, dummy);
        assert!(h.state.providers().get_by_connection(&id).is_some());

        crate::workspace::service::remove_connection(&h.state, &id_string)
            .await
            .expect("remove succeeds");

        assert!(
            h.state.providers().get_by_connection(&id).is_none(),
            "connection_remove must drop the cached provider entry"
        );
    }

    #[tokio::test]
    async fn connection_remove_releases_workspace_mount() {
        let runtime = Arc::new(RecordingRuntime::default());
        let h = Arc::new(CoreHandle {
            state: AppState::new_with_workspace_runtime("test", runtime.clone()),
            commands: crate::command::CommandRegistry::new(),
        });
        let id_string = h.connection_create(
            "test".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        );
        let id = ConnectionId(id_string.clone());
        h.state
            .mounts()
            .get_or_reserve(&id, |_taken| "test://mount".into());
        h.state.mounts().mark_ready(&id);
        assert!(h.state.mounts().is_mounted(&id));

        crate::workspace::service::remove_connection(&h.state, &id_string)
            .await
            .expect("remove succeeds");

        assert!(!h.state.mounts().is_mounted(&id));
        assert_eq!(runtime.unmount_calls(), 1);
    }

    #[tokio::test]
    async fn connection_remove_keeps_mount_reservation_when_unmount_fails() {
        let runtime = Arc::new(RecordingRuntime::failing_unmount());
        let h = Arc::new(CoreHandle {
            state: AppState::new_with_workspace_runtime("test", runtime.clone()),
            commands: crate::command::CommandRegistry::new(),
        });
        let id_string = h.connection_create(
            "test".into(),
            "http://localhost:9000".into(),
            "us-east-1".into(),
            "test-bucket".into(),
            String::new(),
            true,
            "minioadmin".into(),
            "minioadmin".into(),
        );
        let id = ConnectionId(id_string.clone());
        h.state
            .mounts()
            .get_or_reserve(&id, |_taken| "test://mount".into());
        h.state.mounts().mark_ready(&id);

        let error = crate::workspace::service::remove_connection(&h.state, &id_string)
            .await
            .expect_err("failed unmount must fail removal");

        assert_eq!(error.code(), "mount_failed");
        assert!(
            h.state.mounts().is_mounted(&id),
            "failed cleanup must leave reservation tracked"
        );
        assert_eq!(
            h.state.connections().list().len(),
            1,
            "failed cleanup must leave connection registered so removal can be retried"
        );
        assert_eq!(runtime.unmount_calls(), 1);
        assert!(
            crate::workspace::service::remove_connection(&h.state, &id_string)
                .await
                .is_err()
        );
    }
}
