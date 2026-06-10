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
    terminal::{registry::TerminalRegistry, session::TerminalEvent},
};

use super::error::CoreError;

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

    spawn_event_forwarder(session_id, event_rx, listener, state.terminals().clone());

    Ok(session_id.to_string())
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
) {
    thread::Builder::new()
        .name(format!("terminal-ffi-events-{session_id}"))
        .spawn(move || {
            while let Some(event) = events.blocking_recv() {
                match event {
                    TerminalEvent::Output { bytes, .. } => listener.on_output(bytes),
                    TerminalEvent::Exit { code, signal, .. } => {
                        registry.remove(session_id);
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
