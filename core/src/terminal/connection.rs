use tokio::sync::mpsc;
use uuid::Uuid;

use crate::{
    connection::{ConnectionConfig, ConnectionId},
    error::ApiError,
    state::AppState,
    terminal::session::TerminalEvent,
    workspace::{MountSpec, TerminalOpenContext, mount_table::Reservation},
};

// 上限保护：正常路径 1～2 轮即收敛（命中暴露的 mount，或 release 后落到 New 直接挂载）。
// 但并发下，别的 task 可能在本 task `release` 后立刻把同一连接重新占成 Existing/Pending，
// 加上 runtime 持续探测为未暴露（mount 进程刚起就死），就会无限自旋。给整个 reserve 循环
// 设总轮次上限，超过即放弃，避免永久占用 executor。
const MAX_MOUNT_ATTEMPTS: usize = 5;

pub async fn create_connection_terminal(
    state: &AppState,
    connection_id: String,
    cols: u16,
    rows: u16,
    events: mpsc::Sender<TerminalEvent>,
) -> Result<Uuid, ApiError> {
    let id = ConnectionId(connection_id);
    let entry = state
        .connections()
        .get(&id)
        .ok_or_else(|| ApiError::ConnectionNotFound {
            connection_id: id.0.clone(),
        })?;

    let runtime = state.workspace_runtime();
    runtime.ensure_ready().await?;

    let display_name = entry.config.display_name().to_string();
    let ConnectionConfig::S3(config) = entry.config;
    let credential = entry.credential;
    let runtime_for_propose = runtime.clone();

    let mut attempts = 0usize;
    let (mountpoint, created_mount) = loop {
        attempts += 1;
        if attempts > MAX_MOUNT_ATTEMPTS {
            return Err(ApiError::MountFailed {
                message: "workspace mount did not stabilize after repeated attempts".into(),
            });
        }

        let reservation = state.mounts().get_or_reserve(&id, |taken| {
            runtime_for_propose.propose_mountpoint(&display_name, taken)
        });

        match reservation {
            Reservation::New(mountpoint) => {
                let spec = MountSpec {
                    connection_id: id.clone(),
                    config: config.clone(),
                    credential: credential.clone(),
                    mountpoint: mountpoint.clone(),
                };

                if let Err(error) = runtime.mount(spec).await {
                    state.mounts().release(&id);
                    return Err(error);
                }

                if state.mounts().mark_ready(&id).is_none() {
                    let _ = runtime.unmount(&mountpoint).await;
                    return Err(ApiError::ConnectionNotFound {
                        connection_id: id.0.clone(),
                    });
                }
                break (mountpoint, true);
            }
            Reservation::Existing(mountpoint) => {
                if runtime.is_exposed(&mountpoint).await? {
                    break (mountpoint, false);
                }
                state.mounts().release(&id);
            }
            Reservation::Pending(pending) => {
                let Some(mountpoint) = pending.wait().await else {
                    return Err(ApiError::MountFailed {
                        message: "mount did not complete".into(),
                    });
                };
                if runtime.is_exposed(&mountpoint).await? {
                    break (mountpoint, false);
                }
                state.mounts().release(&id);
            }
        }
    };

    let handle = match runtime
        .open_terminal(
            TerminalOpenContext {
                workdir: mountpoint.clone(),
            },
            cols,
            rows,
            events,
        )
        .await
    {
        Ok(handle) => handle,
        Err(error) => {
            if created_mount {
                runtime.unmount(&mountpoint).await?;
                state.mounts().release(&id);
            }
            return Err(error);
        }
    };
    let session_id = handle.id();
    state.terminals().insert(handle);

    Ok(session_id)
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc, Mutex,
        atomic::{AtomicBool, AtomicUsize, Ordering},
    };
    use std::time::Duration;

    use async_trait::async_trait;
    use tokio::sync::{Notify, mpsc};
    use uuid::Uuid;

    use super::create_connection_terminal;
    use crate::{
        connection::{ConnectionConfig, Credential, S3ConnectionConfig, S3Credential},
        error::ApiError,
        state::AppState,
        terminal::session::{SessionHandle, TerminalEvent},
        workspace::{MountHandle, MountSpec, RuntimeStatus, TerminalOpenContext, WorkspaceRuntime},
    };

    struct MockRuntime {
        mount_calls: AtomicUsize,
        open_calls: AtomicUsize,
        unmount_calls: AtomicUsize,
        exposed: AtomicBool,
        opened_workdirs: Mutex<Vec<String>>,
        mount_result: Mutex<Option<Result<(), ApiError>>>,
        open_result: Mutex<Option<Result<(), ApiError>>>,
        unmount_result: Mutex<Option<Result<(), ApiError>>>,
        block_mount: AtomicBool,
        mount_started: Notify,
        allow_mount: Notify,
    }

    impl Default for MockRuntime {
        fn default() -> Self {
            Self {
                mount_calls: AtomicUsize::new(0),
                open_calls: AtomicUsize::new(0),
                unmount_calls: AtomicUsize::new(0),
                exposed: AtomicBool::new(true),
                opened_workdirs: Mutex::new(Vec::new()),
                mount_result: Mutex::new(None),
                open_result: Mutex::new(None),
                unmount_result: Mutex::new(None),
                block_mount: AtomicBool::new(false),
                mount_started: Notify::new(),
                allow_mount: Notify::new(),
            }
        }
    }

    impl MockRuntime {
        fn fail_mount(error: ApiError) -> Self {
            Self {
                mount_result: Mutex::new(Some(Err(error))),
                ..Self::default()
            }
        }

        fn fail_open(error: ApiError) -> Self {
            Self {
                open_result: Mutex::new(Some(Err(error))),
                ..Self::default()
            }
        }

        fn fail_open_and_unmount(open_error: ApiError, unmount_error: ApiError) -> Self {
            Self {
                open_result: Mutex::new(Some(Err(open_error))),
                unmount_result: Mutex::new(Some(Err(unmount_error))),
                ..Self::default()
            }
        }

        fn block_mount() -> Self {
            Self {
                block_mount: AtomicBool::new(true),
                ..Self::default()
            }
        }

        fn mount_calls(&self) -> usize {
            self.mount_calls.load(Ordering::SeqCst)
        }

        fn open_calls(&self) -> usize {
            self.open_calls.load(Ordering::SeqCst)
        }

        fn unmount_calls(&self) -> usize {
            self.unmount_calls.load(Ordering::SeqCst)
        }

        fn set_exposed(&self, value: bool) {
            self.exposed.store(value, Ordering::SeqCst);
        }

        fn opened_workdirs(&self) -> Vec<String> {
            self.opened_workdirs
                .lock()
                .expect("opened workdirs lock is not poisoned")
                .clone()
        }
    }

    #[async_trait]
    impl WorkspaceRuntime for MockRuntime {
        async fn status(&self) -> RuntimeStatus {
            RuntimeStatus::Ready
        }

        async fn ensure_ready(&self) -> Result<(), ApiError> {
            Ok(())
        }

        fn propose_mountpoint(&self, display_name: &str, taken: &[String]) -> String {
            let suffix = if taken.is_empty() {
                String::new()
            } else {
                format!("-{}", taken.len() + 1)
            };
            format!("mock://{display_name}{suffix}")
        }

        async fn mount(&self, spec: MountSpec) -> Result<MountHandle, ApiError> {
            self.mount_calls.fetch_add(1, Ordering::SeqCst);
            if self.block_mount.load(Ordering::SeqCst) {
                self.mount_started.notify_waiters();
                self.allow_mount.notified().await;
            }
            if let Some(result) = self
                .mount_result
                .lock()
                .expect("mount result lock is not poisoned")
                .take()
            {
                result?;
            }
            self.exposed.store(true, Ordering::SeqCst);
            Ok(MountHandle {
                mountpoint: spec.mountpoint,
            })
        }

        async fn is_exposed(&self, _mountpoint: &str) -> Result<bool, ApiError> {
            Ok(self.exposed.load(Ordering::SeqCst))
        }

        async fn unmount(&self, _mountpoint: &str) -> Result<(), ApiError> {
            self.unmount_calls.fetch_add(1, Ordering::SeqCst);
            if let Some(result) = self
                .unmount_result
                .lock()
                .expect("unmount result lock is not poisoned")
                .take()
            {
                result?;
            }
            Ok(())
        }

        async fn open_terminal(
            &self,
            ctx: TerminalOpenContext,
            _cols: u16,
            _rows: u16,
            _events: mpsc::Sender<TerminalEvent>,
        ) -> Result<SessionHandle, ApiError> {
            self.open_calls.fetch_add(1, Ordering::SeqCst);
            if let Some(result) = self
                .open_result
                .lock()
                .expect("open result lock is not poisoned")
                .take()
            {
                result?;
            }
            self.opened_workdirs
                .lock()
                .expect("opened workdirs lock is not poisoned")
                .push(ctx.workdir);
            Ok(SessionHandle::for_test(Uuid::new_v4()))
        }

        async fn teardown(&self) -> Result<(), ApiError> {
            Ok(())
        }
    }

    fn sample_connection() -> (ConnectionConfig, Credential) {
        (
            ConnectionConfig::S3(S3ConnectionConfig {
                display_name: "Team Bucket".into(),
                endpoint: "http://localhost:9000".into(),
                region: "us-east-1".into(),
                bucket: "bucket".into(),
                base_prefix: String::new(),
                path_style: true,
            }),
            Credential::S3(S3Credential {
                access_key_id: "access".into(),
                secret_access_key: "secret".into(),
            }),
        )
    }

    #[tokio::test]
    async fn unknown_connection_returns_connection_not_found() {
        let runtime = Arc::new(MockRuntime::default());
        let state = AppState::new_with_workspace_runtime("test", runtime);
        let (events, _rx) = mpsc::channel(1);

        let error = create_connection_terminal(&state, "missing".into(), 80, 24, events)
            .await
            .expect_err("unknown connection must fail");

        assert_eq!(error.code(), "connection_not_found");
    }

    #[tokio::test]
    async fn second_terminal_for_same_connection_reuses_mount() {
        let runtime = Arc::new(MockRuntime::default());
        let state = AppState::new_with_workspace_runtime("test", runtime.clone());
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let (events_a, _rx_a) = mpsc::channel(1);
        let (events_b, _rx_b) = mpsc::channel(1);

        let first = create_connection_terminal(&state, connection_id.0.clone(), 80, 24, events_a)
            .await
            .expect("first terminal opens");
        let second = create_connection_terminal(&state, connection_id.0.clone(), 100, 32, events_b)
            .await
            .expect("second terminal opens");

        assert_ne!(first, second);
        assert_eq!(runtime.mount_calls(), 1);
        assert_eq!(runtime.open_calls(), 2);
        assert_eq!(
            runtime.opened_workdirs(),
            vec![
                "mock://Team Bucket".to_string(),
                "mock://Team Bucket".to_string()
            ]
        );
        assert_eq!(state.terminals().len(), 2);
    }

    #[tokio::test]
    async fn stale_existing_mount_is_released_and_mounted_again() {
        let runtime = Arc::new(MockRuntime::default());
        let state = AppState::new_with_workspace_runtime("test", runtime.clone());
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let (events_a, _rx_a) = mpsc::channel(1);
        let (events_b, _rx_b) = mpsc::channel(1);

        create_connection_terminal(&state, connection_id.0.clone(), 80, 24, events_a)
            .await
            .expect("first terminal opens");
        runtime.set_exposed(false);

        create_connection_terminal(&state, connection_id.0.clone(), 100, 32, events_b)
            .await
            .expect("second terminal remounts stale reservation");

        assert_eq!(runtime.mount_calls(), 2);
        assert_eq!(runtime.open_calls(), 2);
        assert!(state.mounts().is_mounted(&connection_id));
    }

    #[tokio::test]
    async fn mount_failure_releases_reservation() {
        let runtime = Arc::new(MockRuntime::fail_mount(ApiError::MountFailed {
            message: "boom".into(),
        }));
        let state = AppState::new_with_workspace_runtime("test", runtime);
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let (events, _rx) = mpsc::channel(1);

        let error = create_connection_terminal(&state, connection_id.0.clone(), 80, 24, events)
            .await
            .expect_err("mount failure must fail");

        assert_eq!(error.code(), "mount_failed");
        assert!(!state.mounts().is_mounted(&connection_id));
    }

    #[tokio::test]
    async fn concurrent_terminal_waits_for_in_flight_mount_before_opening() {
        let runtime = Arc::new(MockRuntime::block_mount());
        let state = AppState::new_with_workspace_runtime("test", runtime.clone());
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let mount_started = runtime.mount_started.notified();

        let first_state = state.clone();
        let first_id = connection_id.0.clone();
        let (events_a, _rx_a) = mpsc::channel(1);
        let first = tokio::spawn(async move {
            create_connection_terminal(&first_state, first_id, 80, 24, events_a).await
        });

        mount_started.await;

        let second_state = state.clone();
        let second_id = connection_id.0.clone();
        let (events_b, _rx_b) = mpsc::channel(1);
        let second = tokio::spawn(async move {
            create_connection_terminal(&second_state, second_id, 100, 32, events_b).await
        });

        tokio::time::sleep(Duration::from_millis(25)).await;
        assert_eq!(
            runtime.open_calls(),
            0,
            "no terminal should open before the in-flight mount is ready"
        );

        runtime.allow_mount.notify_waiters();

        first
            .await
            .expect("first task joins")
            .expect("first terminal opens");
        second
            .await
            .expect("second task joins")
            .expect("second terminal opens");
        assert_eq!(runtime.mount_calls(), 1);
        assert_eq!(runtime.open_calls(), 2);
    }

    #[tokio::test]
    async fn open_terminal_failure_releases_new_mount_and_unmounts() {
        let runtime = Arc::new(MockRuntime::fail_open(ApiError::WorkspaceStartFailed {
            runtime: "mock".into(),
            message: "boom".into(),
        }));
        let state = AppState::new_with_workspace_runtime("test", runtime.clone());
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let (events, _rx) = mpsc::channel(1);

        let error = create_connection_terminal(&state, connection_id.0.clone(), 80, 24, events)
            .await
            .expect_err("open failure must fail");

        assert_eq!(error.code(), "workspace_start_failed");
        assert!(!state.mounts().is_mounted(&connection_id));
        assert_eq!(runtime.unmount_calls(), 1);
        assert_eq!(state.terminals().len(), 0);
    }

    #[tokio::test]
    async fn open_terminal_failure_keeps_mount_reserved_when_unmount_fails() {
        let runtime = Arc::new(MockRuntime::fail_open_and_unmount(
            ApiError::WorkspaceStartFailed {
                runtime: "mock".into(),
                message: "boom".into(),
            },
            ApiError::MountFailed {
                message: "unmount failed".into(),
            },
        ));
        let state = AppState::new_with_workspace_runtime("test", runtime.clone());
        let (config, credential) = sample_connection();
        let connection_id = state.connections().create(config, credential);
        let (events, _rx) = mpsc::channel(1);

        let error = create_connection_terminal(&state, connection_id.0.clone(), 80, 24, events)
            .await
            .expect_err("unmount failure must surface");

        assert_eq!(error.code(), "mount_failed");
        assert!(
            state.mounts().is_mounted(&connection_id),
            "failed cleanup must not forget a still-exposed mount"
        );
        assert_eq!(runtime.unmount_calls(), 1);
        assert_eq!(state.terminals().len(), 0);
    }
}
