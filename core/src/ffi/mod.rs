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

    /// Remove a connection and its in-memory credentials. Also drops any
    /// cached `S3Provider` for that connection so a future call with the same
    /// `connection_id` cannot reuse the old OpenDAL `Operator` (and its
    /// embedded credentials). Returns `Err(ConnectionNotFound)` if unknown.
    pub fn connection_remove(
        &self,
        connection_id: String,
    ) -> Result<(), crate::ffi::error::CoreError> {
        use crate::connection::ConnectionId;
        use crate::error::ApiError;

        let id = ConnectionId(connection_id);
        if self.state.connections().remove(&id) {
            self.state.providers().remove_connection(&id);
            tracing::info!(method = "connection.remove", "connection removed");
            Ok(())
        } else {
            Err(ApiError::ConnectionNotFound {
                connection_id: id.0,
            }
            .into())
        }
    }
}

#[uniffi::export(async_runtime = "tokio")]
impl CoreHandle {
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
        use crate::error::ApiError;

        let path_buf = std::path::PathBuf::from(&local_source);
        let read_path = path_buf.clone();
        let data = tokio::task::spawn_blocking(move || std::fs::read(&read_path))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "ffi.upload_file",
                message: e.to_string(),
            })?
            .map_err(|source| ApiError::FileSystemRead {
                path: path_buf,
                source,
            })?;

        let (location, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&remote_path),
        )?;
        let total = data.len() as u64;
        let conn_label = connection_id.as_deref().unwrap_or("");
        self.send_progress_event(conn_label, &remote_path, 0, total);
        provider.write(&location.path, data).await?;
        self.send_progress_event(conn_label, &remote_path, total, total);
        tracing::info!(
            method = "workspace.uploadFile",
            connection_id = conn_label,
            bytes = total,
            "upload complete"
        );
        Ok(())
    }

    /// 删除 `path` 指向的对象/文件。S3 走 `delete object`，Local 区分
    /// 文件/目录递归删；删除目录的语义由各 provider 自定（S3 仅删 key 不
    /// 递归——本期 UI 只暴露单文件删除，目录删除留给后续 PR）。
    pub async fn delete_entry(
        &self,
        connection_id: Option<String>,
        path: String,
    ) -> Result<(), CoreError> {
        let (location, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&path),
        )?;
        provider.delete(&location.path).await?;
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
        let (location, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&path),
        )?;
        provider.create_directory(&location.path).await?;
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
        let (location, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&from),
        )?;
        // `from` 经 resolve 拿到 location.path；`to` 也要经过同一个 provider 的
        // path 规范（base_prefix 等），所以这里再次调 resolve_provider 取
        // location 即可。两次 resolve 共享同一个 provider 缓存条目，没有额外开销。
        let (target_location, _) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&to),
        )?;
        provider
            .rename(&location.path, &target_location.path)
            .await?;
        Ok(())
    }

    /// Send a `transfer_progress` envelope through the shared broadcast
    /// channel so Swift `EventClient` subscribers can drive progress bars.
    /// Best-effort: a closed channel just drops the event (no subscribers).
    fn send_progress_event(
        &self,
        connection_id: &str,
        path: &str,
        bytes_transferred: u64,
        total_bytes: u64,
    ) {
        let payload = serde_json::json!({
            "type": "transfer_progress",
            "connection_id": connection_id,
            "path": path,
            "bytes_transferred": bytes_transferred,
            "total_bytes": total_bytes,
        });
        let _ = self.state.events().send(payload.to_string());
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
        use crate::error::ApiError;

        let (location, provider) = crate::workspace::service::resolve_provider(
            &self.state,
            connection_id.as_deref(),
            std::path::Path::new(&remote_path),
        )?;
        let bytes = provider.read(&location.path).await?;
        let dst = std::path::PathBuf::from(local_destination);
        let dst_for_write = dst.clone();
        tokio::task::spawn_blocking(move || std::fs::write(&dst_for_write, &bytes))
            .await
            .map_err(|e| ApiError::BackgroundTask {
                operation: "ffi.download_file",
                message: e.to_string(),
            })?
            .map_err(|source| ApiError::FileSystemRead { path: dst, source })?;
        tracing::info!(
            method = "workspace.downloadFile",
            connection_id = connection_id.as_deref().unwrap_or(""),
            "download complete"
        );
        Ok(())
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
}

#[cfg(test)]
mod connection_ffi_tests {
    use super::*;

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
        let listed = h.connection_list();
        assert_eq!(listed.len(), 1);
        assert_eq!(listed[0].connection_id, id);
        assert_eq!(listed[0].display_name, "test");
        assert_eq!(listed[0].endpoint, "http://localhost:9000");
        assert_eq!(listed[0].bucket, "test-bucket");
        assert_eq!(listed[0].base_prefix, "");
    }

    #[test]
    fn connection_remove_makes_get_fail() {
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
        h.connection_remove(id.clone()).expect("remove succeeds");
        assert_eq!(h.connection_list().len(), 0);
        assert!(
            h.connection_remove(id).is_err(),
            "removing missing id is an error"
        );
    }

    #[test]
    fn connection_list_returns_empty_initially() {
        let h = handle();
        assert!(h.connection_list().is_empty());
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
        handle
            .download_file(
                None,
                src.to_string_lossy().into_owned(),
                dst.to_string_lossy().into_owned(),
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
        handle
            .upload_file(
                None,
                dst.to_string_lossy().into_owned(),
                src.to_string_lossy().into_owned(),
            )
            .await
            .expect("upload succeeds");
        let written = std::fs::read(&dst).expect("dst exists");
        assert_eq!(written, b"payload");

        handle
            .delete_entry(None, dst.to_string_lossy().into_owned())
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
        handle
            .create_remote_directory(None, base.to_string_lossy().into_owned())
            .await
            .expect("mkdir");
        std::fs::write(&from, b"x").expect("seed from");
        handle
            .rename_entry(
                None,
                from.to_string_lossy().into_owned(),
                to.to_string_lossy().into_owned(),
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
        let err = handle
            .download_file(
                Some("ghost".into()),
                "ignored".into(),
                std::env::temp_dir()
                    .join("tf-never-written")
                    .to_string_lossy()
                    .into_owned(),
            )
            .await
            .expect_err("ghost connection id must error");

        let CoreError::Rpc { code, .. } = err;
        assert_eq!(code, "connection_not_found");
    }

    #[test]
    fn connection_remove_drops_cached_provider() {
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

        h.connection_remove(id_string).expect("remove succeeds");

        assert!(
            h.state.providers().get_by_connection(&id).is_none(),
            "connection_remove must drop the cached provider entry"
        );
    }
}
