//! 终端会话的 FFI 桥接：回调接口 + 生命周期操作。
//!
//! 进程内字节直接以 `Vec<u8>`（Swift `Data`）跨边界，无 base64。每个 session
//! 一条事件通道、一个转发线程：从 `TerminalEvent`（tokio mpsc）转发到 Swift
//! 实现的 `TerminalEventListener`。语义与 `terminal::websocket` 路径保持一致：
//! `cwd` 缺省取 workspace 当前目录，`Exit` 时从 registry 移除 session。

use std::{path::PathBuf, sync::Arc, thread};

use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{
    state::AppState,
    terminal::{
        binding::{WorkspaceTerminalKind, WorkspaceTerminalLaunchSnapshot},
        registry::TerminalRegistry,
        session::{TerminalEvent, TerminalLaunch},
        shell_integration::ShellIntegration,
    },
};

use super::{
    dto::{
        TerminalDirectoryChangeDto, TerminalWorkingDirectoryUpdateDto, WorkspaceTerminalCreateDto,
    },
    error::CoreError,
};

/// 与 websocket 路径相同的每会话事件缓冲；listener 消费慢时对 PTY 读线程形成背压。
const TERMINAL_EVENT_BUFFER: usize = 256;

/// 终端事件监听器，由 Swift 侧实现（`with_foreign`）。
///
/// 回调在 Rust 的事件转发线程上调用：实现方应立即把工作派发到自己的队列
/// （如主线程），不要在回调里长时间阻塞，否则会背压 PTY 输出。
#[uniffi::export(with_foreign)]
pub trait TerminalEventListener: Send + Sync {
    /// 一段 PTY 原始输出字节（含转义序列，不保证 UTF-8 完整性）。
    fn on_output(&self, data: Vec<u8>);
    /// PTY 进程结束。`code` 为退出码；被信号终止时 `signal` 置位。
    fn on_exit(&self, code: Option<i32>, signal: Option<i32>);
    /// 会话内错误（`write_failed` / `resize_failed` / `read_failed` / `wait_failed`）。
    /// 不一定终止会话。
    fn on_error(&self, code: String, message: String);
}

pub(super) fn create_terminal(
    state: &AppState,
    cwd: Option<String>,
    cols: u16,
    rows: u16,
    listener: Arc<dyn TerminalEventListener>,
) -> Result<String, CoreError> {
    let cwd = cwd
        .map(PathBuf::from)
        .unwrap_or_else(|| state.workspace().state().current_directory);

    let (event_tx, event_rx) = mpsc::channel(TERMINAL_EVENT_BUFFER);
    let session_id = state
        .terminals()
        .create_session(cwd, cols, rows, event_tx)
        .map_err(|error| CoreError::Rpc {
            code: "create_failed".to_string(),
            message: error.to_string(),
        })?;

    spawn_event_forwarder(
        session_id,
        event_rx,
        listener,
        state.terminals().clone(),
        state.workspace_terminal_bindings().clone(),
    );

    Ok(session_id.to_string())
}

pub(super) async fn create_workspace_terminal(
    state: &AppState,
    cols: u16,
    rows: u16,
    listener: Arc<dyn TerminalEventListener>,
) -> Result<WorkspaceTerminalCreateDto, CoreError> {
    let workspace = state.workspace().state();
    let (event_tx, event_rx) = mpsc::channel(TERMINAL_EVENT_BUFFER);

    let (session_id, kind) = if workspace.scheme == "local" {
        let integration = ShellIntegration::create().map_err(|error| CoreError::Rpc {
            code: "create_failed".to_string(),
            message: error.to_string(),
        })?;
        let integration_for_binding = integration.clone();
        let launch = TerminalLaunch::LocalShell {
            cwd: workspace.current_directory.clone(),
            integration: Some(integration),
        };
        let session_id = state
            .terminals()
            .create_session_with_launch(launch, cols, rows, event_tx)
            .map_err(|error| CoreError::Rpc {
                code: "create_failed".to_string(),
                message: error.to_string(),
            })?;
        state
            .workspace_terminal_bindings()
            .attach_shell_integration(session_id, integration_for_binding);
        (session_id, WorkspaceTerminalKind::Local)
    } else if let Some(connection_id) = workspace.connection_id.clone() {
        let session_id = crate::terminal::connection::create_connection_terminal(
            state,
            connection_id,
            cols,
            rows,
            event_tx,
        )
        .await?;
        (session_id, WorkspaceTerminalKind::Connection)
    } else {
        return Err(CoreError::Rpc {
            code: "unsupported_workspace_terminal".to_string(),
            message: format!(
                "workspace terminal creation for scheme {:?} is not implemented in this FFI helper",
                workspace.scheme
            ),
        });
    };

    let snapshot = WorkspaceTerminalLaunchSnapshot {
        workspace_root: workspace.workspace_root.to_string_lossy().into_owned(),
        current_directory: workspace.current_directory.to_string_lossy().into_owned(),
        scheme: workspace.scheme,
        connection_id: workspace.connection_id,
    };
    let binding = state
        .workspace_terminal_bindings()
        .create(session_id, kind, snapshot);

    spawn_event_forwarder(
        session_id,
        event_rx,
        listener,
        state.terminals().clone(),
        state.workspace_terminal_bindings().clone(),
    );

    Ok(WorkspaceTerminalCreateDto {
        binding: binding.into(),
    })
}

pub(super) async fn create_connection_terminal(
    state: &AppState,
    connection_id: String,
    cols: u16,
    rows: u16,
    listener: Arc<dyn TerminalEventListener>,
) -> Result<String, CoreError> {
    let (event_tx, event_rx) = mpsc::channel(TERMINAL_EVENT_BUFFER);
    let session_id = crate::terminal::connection::create_connection_terminal(
        state,
        connection_id,
        cols,
        rows,
        event_tx,
    )
    .await?;

    spawn_event_forwarder(
        session_id,
        event_rx,
        listener,
        state.terminals().clone(),
        state.workspace_terminal_bindings().clone(),
    );

    Ok(session_id.to_string())
}

pub(super) async fn update_terminal_working_directory(
    state: &AppState,
    session_id: String,
    directory_url: String,
) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError> {
    let session_id = parse_session_id(&session_id)?;
    let binding = state
        .workspace_terminal_bindings()
        .get(session_id)
        .ok_or_else(|| unknown_session(session_id))?;

    let decoded = match decode_file_url(&directory_url) {
        Ok(decoded) => decoded,
        Err(CwdDecodeError::UnsupportedHost) => {
            return Ok(TerminalWorkingDirectoryUpdateDto {
                binding: binding.into(),
                reported_directory: directory_url,
                openable: false,
                matches_current: false,
                reason: Some("unsupported_host".to_string()),
            });
        }
        Err(CwdDecodeError::Invalid(message)) => {
            return Err(CoreError::Rpc {
                code: "invalid_params".to_string(),
                message,
            });
        }
    };

    let binding = state
        .workspace_terminal_bindings()
        .record_terminal_working_directory(session_id, decoded.clone())
        .ok_or_else(|| unknown_session(session_id))?;

    compare_decoded_terminal_directory(state, binding, decoded).await
}

pub(super) async fn compare_terminal_working_directory(
    state: &AppState,
    session_id: String,
) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError> {
    let session_id = parse_session_id(&session_id)?;
    let binding = state
        .workspace_terminal_bindings()
        .get(session_id)
        .ok_or_else(|| unknown_session(session_id))?;
    let Some(directory) = binding.latest_terminal_working_directory.clone() else {
        return Ok(TerminalWorkingDirectoryUpdateDto {
            binding: binding.into(),
            reported_directory: String::new(),
            openable: false,
            matches_current: false,
            reason: Some("cwd_unknown".to_string()),
        });
    };

    compare_decoded_terminal_directory(state, binding, directory).await
}

pub(super) async fn change_terminal_directory(
    state: &AppState,
    session_id: String,
    target_directory: String,
) -> Result<TerminalDirectoryChangeDto, CoreError> {
    let session_id = parse_session_id(&session_id)?;
    if target_directory.chars().any(|ch| ch.is_control()) {
        return Err(CoreError::Rpc {
            code: "invalid_params".to_string(),
            message: "terminal target directory contains unsafe control characters".to_string(),
        });
    }

    let binding = state
        .workspace_terminal_bindings()
        .get(session_id)
        .ok_or_else(|| unknown_session(session_id))?;
    if !matches!(binding.kind, WorkspaceTerminalKind::Local) {
        return Err(CoreError::Rpc {
            code: "unsupported_terminal".to_string(),
            message: "connection-backed terminals do not support directory changes".to_string(),
        });
    }
    let integration = state
        .workspace_terminal_bindings()
        .shell_integration(session_id)
        .ok_or_else(|| CoreError::Rpc {
            code: "terminal_control_unavailable".to_string(),
            message: "terminal shell integration is not available for this session".to_string(),
        })?;

    let target_for_task = target_directory.clone();
    let canonical_target = tokio::task::spawn_blocking(move || {
        let path = PathBuf::from(target_for_task);
        let metadata = std::fs::metadata(&path).map_err(|_| "not_openable".to_string())?;
        if !metadata.is_dir() {
            return Err("not_directory".to_string());
        }
        path.canonicalize().map_err(|_| "not_openable".to_string())
    })
    .await
    .map_err(|error| CoreError::Rpc {
        code: "background_task_failed".to_string(),
        message: format!("terminal directory change validation task failed: {error}"),
    })?
    .map_err(|reason| CoreError::Rpc {
        code: reason,
        message: format!("terminal target directory is not openable: {target_directory}"),
    })?;

    let canonical_target = canonical_target.to_string_lossy().into_owned();
    integration
        .write_cd_request(&canonical_target)
        .map_err(|error| CoreError::Rpc {
            code: "terminal_control_failed".to_string(),
            message: error.to_string(),
        })?;
    let binding = state
        .workspace_terminal_bindings()
        .record_pending_target(session_id, canonical_target.clone())
        .ok_or_else(|| unknown_session(session_id))?;

    Ok(TerminalDirectoryChangeDto {
        binding: binding.into(),
        queued: true,
        target_directory: canonical_target,
        reason: None,
    })
}

pub(super) fn send_terminal_input(
    state: &AppState,
    session_id: String,
    data: Vec<u8>,
) -> Result<(), CoreError> {
    let session_id = parse_session_id(&session_id)?;
    let session = state
        .terminals()
        .session(session_id)
        .ok_or_else(|| unknown_session(session_id))?;

    if session.input(data) {
        Ok(())
    } else {
        Err(unknown_session(session_id))
    }
}

pub(super) fn resize_terminal(
    state: &AppState,
    session_id: String,
    cols: u16,
    rows: u16,
) -> Result<(), CoreError> {
    let session_id = parse_session_id(&session_id)?;
    let session = state
        .terminals()
        .session(session_id)
        .ok_or_else(|| unknown_session(session_id))?;

    if session.resize(cols, rows) {
        Ok(())
    } else {
        Err(unknown_session(session_id))
    }
}

pub(super) fn close_terminal(state: &AppState, session_id: String) -> Result<(), CoreError> {
    let session_id = parse_session_id(&session_id)?;

    if state.terminals().close(session_id) {
        state.workspace_terminal_bindings().remove(session_id);
        Ok(())
    } else {
        Err(unknown_session(session_id))
    }
}

/// 每 session 一个转发线程：通道关闭（所有 sender 释放）或收到 `Exit` 后退出，
/// 不残留线程。`Exit` 时同步从 registry 移除，镜像 websocket 路径的清理语义。
fn spawn_event_forwarder(
    session_id: Uuid,
    mut events: mpsc::Receiver<TerminalEvent>,
    listener: Arc<dyn TerminalEventListener>,
    registry: TerminalRegistry,
    bindings: crate::terminal::binding::WorkspaceTerminalBindings,
) {
    thread::Builder::new()
        .name(format!("terminal-ffi-events-{session_id}"))
        .spawn(move || {
            while let Some(event) = events.blocking_recv() {
                match event {
                    TerminalEvent::Output { bytes, .. } => listener.on_output(bytes),
                    TerminalEvent::Exit { code, signal, .. } => {
                        registry.remove(session_id);
                        bindings.remove(session_id);
                        listener.on_exit(code, signal);
                        return;
                    }
                    TerminalEvent::Error { code, message, .. } => {
                        listener.on_error(code.to_string(), message);
                    }
                }
            }
        })
        .expect("terminal ffi event forwarder thread starts");
}

async fn compare_decoded_terminal_directory(
    state: &AppState,
    binding: crate::terminal::binding::WorkspaceTerminalBinding,
    reported_directory: String,
) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError> {
    if matches!(
        binding.sync_capability,
        crate::terminal::binding::WorkspaceTerminalSyncCapability::LaunchOnly
    ) {
        return Ok(TerminalWorkingDirectoryUpdateDto {
            binding: binding.into(),
            reported_directory,
            openable: false,
            matches_current: false,
            reason: Some("unsupported".to_string()),
        });
    }

    let current_directory = state.workspace().state().current_directory;
    let reported_for_task = reported_directory.clone();
    let comparison = tokio::task::spawn_blocking(move || {
        let reported = PathBuf::from(&reported_for_task);
        let reported_metadata =
            std::fs::metadata(&reported).map_err(|_| "not_openable".to_string())?;
        if !reported_metadata.is_dir() {
            return Err("not_directory".to_string());
        }
        let reported_canonical = reported
            .canonicalize()
            .map_err(|_| "not_openable".to_string())?;
        let current_canonical = current_directory
            .canonicalize()
            .map_err(|_| "current_directory_unavailable".to_string())?;
        Ok::<_, String>(reported_canonical == current_canonical)
    })
    .await
    .map_err(|error| CoreError::Rpc {
        code: "background_task_failed".to_string(),
        message: format!("terminal cwd comparison task failed: {error}"),
    })?;

    match comparison {
        Ok(matches_current) => Ok(TerminalWorkingDirectoryUpdateDto {
            binding: binding.into(),
            reported_directory,
            openable: true,
            matches_current,
            reason: None,
        }),
        Err(reason) => Ok(TerminalWorkingDirectoryUpdateDto {
            binding: binding.into(),
            reported_directory,
            openable: false,
            matches_current: false,
            reason: Some(reason),
        }),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum CwdDecodeError {
    UnsupportedHost,
    Invalid(String),
}

fn decode_file_url(raw: &str) -> Result<String, CwdDecodeError> {
    let rest = raw.strip_prefix("file://").ok_or_else(|| {
        CwdDecodeError::Invalid("terminal cwd update must be a file:// URL".to_string())
    })?;
    let (host, path) = if rest.starts_with('/') {
        ("", rest)
    } else {
        let Some((host, _path_without_host)) = rest.split_once('/') else {
            return Err(CwdDecodeError::Invalid(
                "terminal cwd file URL is missing a path".to_string(),
            ));
        };
        (host, &rest[host.len()..])
    };

    if !host_is_local(host) {
        return Err(CwdDecodeError::UnsupportedHost);
    }

    percent_decode(path)
}

fn host_is_local(host: &str) -> bool {
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
        return true;
    }

    // OSC 7 emits file://<hostname>/path with the real hostname (gethostname),
    // which a GUI process does not expose via $HOST/$HOSTNAME. Match the actual
    // system hostname so local shells are recognized while remote (ssh) hosts
    // are still rejected.
    local_hostname()
        .map(|local| host.eq_ignore_ascii_case(&local))
        .unwrap_or(false)
}

/// 本机 hostname，取自 `gethostname(2)`——与 zsh `$HOST` / OSC 7 `file://<host>` 的来源一致。
/// GUI 进程环境不会导出 `HOST`/`HOSTNAME`，所以不能用环境变量判断本机。
fn local_hostname() -> Option<String> {
    let mut buffer = vec![0_u8; 256];
    // SAFETY: buffer 可写且容量为 buffer.len()；gethostname 最多写入该长度并以 NUL 结尾。
    let result =
        unsafe { libc::gethostname(buffer.as_mut_ptr() as *mut libc::c_char, buffer.len()) };
    if result != 0 {
        return None;
    }
    let nul = buffer
        .iter()
        .position(|&byte| byte == 0)
        .unwrap_or(buffer.len());
    buffer.truncate(nul);
    String::from_utf8(buffer)
        .ok()
        .filter(|name| !name.is_empty())
}

fn percent_decode(raw: &str) -> Result<String, CwdDecodeError> {
    let bytes = raw.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(CwdDecodeError::Invalid(
                    "terminal cwd file URL contains an incomplete percent escape".to_string(),
                ));
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).map_err(|_| {
                CwdDecodeError::Invalid(
                    "terminal cwd file URL contains invalid percent escape bytes".to_string(),
                )
            })?;
            let value = u8::from_str_radix(hex, 16).map_err(|_| {
                CwdDecodeError::Invalid(
                    "terminal cwd file URL contains invalid percent escape".to_string(),
                )
            })?;
            decoded.push(value);
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }

    String::from_utf8(decoded).map_err(|_| {
        CwdDecodeError::Invalid("terminal cwd file URL is not valid UTF-8".to_string())
    })
}

fn parse_session_id(raw: &str) -> Result<Uuid, CoreError> {
    Uuid::parse_str(raw).map_err(|error| CoreError::Rpc {
        code: "invalid_params".to_string(),
        message: format!("invalid session id {raw:?}: {error}"),
    })
}

fn unknown_session(session_id: Uuid) -> CoreError {
    CoreError::Rpc {
        code: "unknown_session".to_string(),
        message: format!("sessionId does not match a live session: {session_id}"),
    }
}

#[cfg(test)]
mod tests {
    use std::{
        sync::{Mutex, mpsc as std_mpsc},
        time::{Duration, Instant},
    };

    use super::*;
    use crate::ffi::WorkspaceTerminalSyncCapabilityDto;
    use crate::terminal::{
        binding::{
            WorkspaceTerminalKind, WorkspaceTerminalLaunchSnapshot, WorkspaceTerminalSyncCapability,
        },
        shell_integration::percent_encode_path,
    };

    const EVENT_TIMEOUT: Duration = Duration::from_secs(10);

    #[derive(Debug)]
    #[allow(dead_code)] // Exit/Error 载荷仅用于失败时的 Debug 输出
    enum ListenerEvent {
        Output(Vec<u8>),
        Exit(Option<i32>, Option<i32>),
        Error(String, String),
    }

    struct CollectingListener {
        events: Mutex<std_mpsc::Sender<ListenerEvent>>,
    }

    impl CollectingListener {
        fn channel() -> (Arc<Self>, std_mpsc::Receiver<ListenerEvent>) {
            let (tx, rx) = std_mpsc::channel();
            (
                Arc::new(Self {
                    events: Mutex::new(tx),
                }),
                rx,
            )
        }
    }

    impl TerminalEventListener for CollectingListener {
        fn on_output(&self, data: Vec<u8>) {
            let _ = self
                .events
                .lock()
                .expect("listener lock is not poisoned")
                .send(ListenerEvent::Output(data));
        }

        fn on_exit(&self, code: Option<i32>, signal: Option<i32>) {
            let _ = self
                .events
                .lock()
                .expect("listener lock is not poisoned")
                .send(ListenerEvent::Exit(code, signal));
        }

        fn on_error(&self, code: String, message: String) {
            let _ = self
                .events
                .lock()
                .expect("listener lock is not poisoned")
                .send(ListenerEvent::Error(code, message));
        }
    }

    fn test_state() -> AppState {
        AppState::new("test")
    }

    fn parse_uuid(raw: &str) -> Uuid {
        Uuid::parse_str(raw).expect("session id is uuid")
    }

    fn set_local_workspace(state: &AppState, path: &std::path::Path) {
        state.workspace().set_directory_state(
            path.to_path_buf(),
            path.to_path_buf(),
            "local".to_string(),
            None,
        );
    }

    fn insert_test_local_binding(state: &AppState, path: &std::path::Path) -> Uuid {
        let session_id = Uuid::new_v4();
        let display = path.to_string_lossy().into_owned();
        state.workspace_terminal_bindings().create(
            session_id,
            WorkspaceTerminalKind::Local,
            WorkspaceTerminalLaunchSnapshot {
                workspace_root: display.clone(),
                current_directory: display,
                scheme: "local".to_string(),
                connection_id: None,
            },
        );
        session_id
    }

    fn wait_for_output_containing(
        rx: &std_mpsc::Receiver<ListenerEvent>,
        needle: &[u8],
    ) -> Vec<u8> {
        let mut collected = Vec::new();
        let deadline = Instant::now() + EVENT_TIMEOUT;
        while Instant::now() < deadline {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(ListenerEvent::Output(bytes)) => {
                    collected.extend_from_slice(&bytes);
                    if collected
                        .windows(needle.len())
                        .any(|window| window == needle)
                    {
                        return collected;
                    }
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        panic!(
            "expected output containing {:?}, got {:?}",
            String::from_utf8_lossy(needle),
            String::from_utf8_lossy(&collected)
        );
    }

    fn saw_output_containing_within(
        rx: &std_mpsc::Receiver<ListenerEvent>,
        needle: &[u8],
        timeout: Duration,
    ) -> bool {
        let mut collected = Vec::new();
        let deadline = Instant::now() + timeout;
        while Instant::now() < deadline {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(ListenerEvent::Output(bytes)) => {
                    collected.extend_from_slice(&bytes);
                    if collected
                        .windows(needle.len())
                        .any(|window| window == needle)
                    {
                        return true;
                    }
                }
                Ok(_) => {}
                Err(_) => break,
            }
        }
        false
    }

    fn wait_for_exit(rx: &std_mpsc::Receiver<ListenerEvent>) {
        let deadline = Instant::now() + EVENT_TIMEOUT;
        while Instant::now() < deadline {
            match rx.recv_timeout(deadline.saturating_duration_since(Instant::now())) {
                Ok(ListenerEvent::Exit(..)) => return,
                Ok(_) => {}
                Err(_) => break,
            }
        }
        panic!("expected exit event before timeout");
    }

    #[test]
    fn terminal_full_lifecycle_via_ffi() {
        let state = test_state();
        let (listener, rx) = CollectingListener::channel();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();

        let session_id =
            create_terminal(&state, Some(cwd), 80, 24, listener).expect("terminal session creates");
        assert_eq!(state.terminals().len(), 1);

        send_terminal_input(
            &state,
            session_id.clone(),
            b"printf 'ffi_%s_marker\\n' roundtrip\n".to_vec(),
        )
        .expect("input sends");
        wait_for_output_containing(&rx, b"ffi_roundtrip_marker");

        resize_terminal(&state, session_id.clone(), 120, 40).expect("resize sends");

        close_terminal(&state, session_id.clone()).expect("close accepted");
        wait_for_exit(&rx);
        assert_eq!(state.terminals().len(), 0, "exit removes session");

        let error = send_terminal_input(&state, session_id, b"x".to_vec())
            .expect_err("input after close fails");
        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_session");
    }

    #[tokio::test]
    async fn create_workspace_terminal_records_local_binding_with_bidirectional_capability() {
        let state = test_state();
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &cwd);
        let (listener, rx) = CollectingListener::channel();

        let result = create_workspace_terminal(&state, 80, 24, listener)
            .await
            .expect("workspace terminal creates");

        assert_eq!(
            result.binding.sync_capability,
            WorkspaceTerminalSyncCapabilityDto::BidirectionalLocal
        );
        let session_id = parse_uuid(&result.binding.session_id);
        let binding = state
            .workspace_terminal_bindings()
            .get(session_id)
            .expect("binding is recorded");
        assert_eq!(binding.kind, WorkspaceTerminalKind::Local);
        assert_eq!(
            binding.sync_capability,
            WorkspaceTerminalSyncCapability::BidirectionalLocal
        );

        close_terminal(&state, result.binding.session_id).expect("close accepted");
        wait_for_exit(&rx);
    }

    #[tokio::test]
    async fn update_terminal_working_directory_accepts_canonical_matching_local_dir() {
        let state = test_state();
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &temp);
        let session_id = insert_test_local_binding(&state, &temp);

        let result = update_terminal_working_directory(
            &state,
            session_id.to_string(),
            format!("file://localhost{}", temp.display()),
        )
        .await
        .expect("update cwd");

        assert!(result.openable);
        assert!(result.matches_current);
        assert_eq!(result.reason, None);
        assert_eq!(
            state
                .workspace_terminal_bindings()
                .get(session_id)
                .unwrap()
                .latest_terminal_working_directory
                .as_deref(),
            Some(temp.to_string_lossy().as_ref())
        );
    }

    #[tokio::test]
    async fn update_terminal_working_directory_rejects_remote_host() {
        let state = test_state();
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &temp);
        let session_id = insert_test_local_binding(&state, &temp);

        let result = update_terminal_working_directory(
            &state,
            session_id.to_string(),
            "file://other-host/tmp".to_string(),
        )
        .await
        .expect("remote host produces structured result");

        assert!(!result.openable);
        assert!(!result.matches_current);
        assert_eq!(result.reason.as_deref(), Some("unsupported_host"));
    }

    // 复现真实运行时 bug：shell 集成发 file://<真实 hostname>/path（zsh $HOST），
    // 而旧 host_is_local 依赖进程环境变量 HOST/HOSTNAME——GUI 进程里没有，导致任意
    // 真实主机名被判为非 local，cwd 上报被拒、follow-terminal 永不触发。
    #[tokio::test]
    async fn update_terminal_working_directory_accepts_real_local_hostname() {
        let state = test_state();
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &temp);
        let session_id = insert_test_local_binding(&state, &temp);

        let hostname = super::local_hostname().expect("system hostname is available");

        let result = update_terminal_working_directory(
            &state,
            session_id.to_string(),
            format!("file://{hostname}{}", temp.display()),
        )
        .await
        .expect("update cwd");

        assert!(
            result.openable,
            "real local hostname must be treated as local (reason={:?})",
            result.reason
        );
        assert!(result.matches_current);
    }

    #[tokio::test]
    async fn compare_terminal_working_directory_uses_live_workspace_state() {
        let state = test_state();
        let temp = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        let parent = temp.parent().unwrap_or(&temp).to_path_buf();
        set_local_workspace(&state, &temp);
        let session_id = insert_test_local_binding(&state, &temp);

        update_terminal_working_directory(
            &state,
            session_id.to_string(),
            format!("file://localhost{}", temp.display()),
        )
        .await
        .expect("initial update");

        state.workspace().set_directory_state(
            parent.clone(),
            parent.clone(),
            "local".to_string(),
            None,
        );

        let result = compare_terminal_working_directory(&state, session_id.to_string())
            .await
            .expect("comparison succeeds");

        assert!(result.openable);
        assert_eq!(result.matches_current, temp == parent);
    }

    #[tokio::test]
    async fn update_terminal_working_directory_rejects_unknown_session() {
        let state = test_state();

        let error = update_terminal_working_directory(
            &state,
            Uuid::new_v4().to_string(),
            "file://localhost/tmp".to_string(),
        )
        .await
        .expect_err("unknown session rejected");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_session");
    }

    #[tokio::test]
    async fn change_terminal_directory_queues_valid_local_target() {
        let state = test_state();
        let target = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &target);
        let (listener, rx) = CollectingListener::channel();
        let created = create_workspace_terminal(&state, 80, 24, listener)
            .await
            .expect("workspace terminal creates");

        let result = change_terminal_directory(
            &state,
            created.binding.session_id.clone(),
            target.to_string_lossy().into_owned(),
        )
        .await
        .expect("change queued");

        assert!(result.queued);
        assert_eq!(result.reason, None);
        assert_eq!(result.target_directory, target.to_string_lossy());
        let session_id = parse_uuid(&created.binding.session_id);
        assert_eq!(
            state
                .workspace_terminal_bindings()
                .get(session_id)
                .unwrap()
                .pending_target_directory
                .as_deref(),
            Some(target.to_string_lossy().as_ref())
        );

        close_terminal(&state, created.binding.session_id).expect("close accepted");
        wait_for_exit(&rx);
    }

    #[tokio::test]
    async fn change_terminal_directory_applies_to_idle_shell_without_user_input() {
        let state = test_state();
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        let target =
            std::env::temp_dir().join(format!("terminal-finder-idle-cd-{}", Uuid::new_v4()));
        std::fs::create_dir(&target).expect("creates target dir");
        let target = target.canonicalize().expect("target canonicalizes");
        set_local_workspace(&state, &cwd);
        let (listener, rx) = CollectingListener::channel();
        let created = create_workspace_terminal(&state, 80, 24, listener)
            .await
            .expect("workspace terminal creates");

        wait_for_output_containing(&rx, cwd.to_string_lossy().as_bytes());

        let result = change_terminal_directory(
            &state,
            created.binding.session_id.clone(),
            target.to_string_lossy().into_owned(),
        )
        .await
        .expect("change queued");
        assert!(result.queued);

        let encoded_target = percent_encode_path(&target.to_string_lossy());
        let saw_target =
            saw_output_containing_within(&rx, encoded_target.as_bytes(), Duration::from_secs(2));

        close_terminal(&state, created.binding.session_id).expect("close accepted");
        wait_for_exit(&rx);
        std::fs::remove_dir(&target).expect("removes target dir");

        assert!(
            saw_target,
            "idle shell should apply queued cd and emit OSC 7 without terminal input"
        );
    }

    #[tokio::test]
    async fn change_terminal_directory_rejects_unknown_session_and_unsafe_target() {
        let state = test_state();
        let target = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        set_local_workspace(&state, &target);
        let (listener, rx) = CollectingListener::channel();
        let created = create_workspace_terminal(&state, 80, 24, listener)
            .await
            .expect("workspace terminal creates");

        let error = change_terminal_directory(
            &state,
            Uuid::new_v4().to_string(),
            target.display().to_string(),
        )
        .await
        .expect_err("unknown session rejected");
        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_session");

        let error = change_terminal_directory(
            &state,
            created.binding.session_id.clone(),
            "/tmp/bad\npath".to_string(),
        )
        .await
        .expect_err("unsafe target rejected");
        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "invalid_params");

        close_terminal(&state, created.binding.session_id).expect("close accepted");
        wait_for_exit(&rx);
    }

    // cwd 不在创建时校验：chdir 失败被 PTY 层静默忽略，shell 在继承目录启动。
    // 契约是会话照常创建、可正常关闭清理（与 websocket 路径一致）。
    #[test]
    fn create_terminal_with_bad_cwd_still_creates_session() {
        let state = test_state();
        let (listener, rx) = CollectingListener::channel();

        let session_id = create_terminal(
            &state,
            Some("/no/such/dir/for/tf/ffi".to_string()),
            80,
            24,
            listener,
        )
        .expect("session creates even with bad cwd");

        close_terminal(&state, session_id).expect("close accepted");
        wait_for_exit(&rx);
        assert!(state.terminals().is_empty(), "close removes session");
    }

    #[tokio::test]
    async fn create_connection_terminal_unknown_id_errors() {
        let state = test_state();
        let (listener, _rx) = CollectingListener::channel();

        let error = super::create_connection_terminal(&state, "missing".into(), 80, 24, listener)
            .await
            .expect_err("unknown connection should fail");

        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "connection_not_found");
    }

    #[test]
    fn unknown_and_invalid_session_ids_are_rejected() {
        let state = test_state();

        let error = send_terminal_input(&state, Uuid::new_v4().to_string(), b"x".to_vec())
            .expect_err("unknown session rejected");
        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "unknown_session");

        let error = close_terminal(&state, "not-a-uuid".to_string())
            .expect_err("invalid session id rejected");
        let CoreError::Rpc { code, .. } = error;
        assert_eq!(code, "invalid_params");
    }

    #[test]
    fn repeated_create_close_does_not_leak_sessions() {
        let state = test_state();
        let cwd = std::env::temp_dir().to_string_lossy().into_owned();

        for _ in 0..3 {
            let (listener, rx) = CollectingListener::channel();
            let session_id = create_terminal(&state, Some(cwd.clone()), 80, 24, listener)
                .expect("terminal session creates");
            close_terminal(&state, session_id).expect("close accepted");
            wait_for_exit(&rx);
        }

        assert!(state.terminals().is_empty());
    }
}
