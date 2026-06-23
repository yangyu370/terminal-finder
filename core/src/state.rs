use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

use crate::connection::ConnectionRegistry;
use crate::terminal::registry::TerminalRegistry;
use crate::vfs::registry::ProviderRegistry;
use crate::workspace::{
    WorkspaceRuntime, docker::LocalDockerRuntime, mount_table::MountRegistry, state::WorkspaceStore,
};
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct AppState {
    pub version: &'static str,
    workspace: WorkspaceStore,
    terminals: TerminalRegistry,
    providers: ProviderRegistry,
    connections: ConnectionRegistry,
    mounts: MountRegistry,
    workspace_runtime: Arc<dyn WorkspaceRuntime>,
    events: broadcast::Sender<String>,
    next_event_connection_id: Arc<AtomicU64>,
}

impl AppState {
    pub fn new(version: &'static str) -> Self {
        let (events, _) = broadcast::channel(256);

        Self {
            version,
            workspace: WorkspaceStore::with_default_directory(),
            terminals: TerminalRegistry::new(),
            providers: ProviderRegistry::new(),
            connections: ConnectionRegistry::new(),
            mounts: MountRegistry::new(),
            workspace_runtime: Arc::new(LocalDockerRuntime::with_defaults()),
            events,
            next_event_connection_id: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn new_with_workspace_runtime(
        version: &'static str,
        workspace_runtime: Arc<dyn WorkspaceRuntime>,
    ) -> Self {
        let mut state = Self::new(version);
        state.workspace_runtime = workspace_runtime;
        state
    }

    pub fn workspace(&self) -> &WorkspaceStore {
        &self.workspace
    }

    pub fn terminals(&self) -> &TerminalRegistry {
        &self.terminals
    }

    pub fn providers(&self) -> &ProviderRegistry {
        &self.providers
    }

    pub fn connections(&self) -> &ConnectionRegistry {
        &self.connections
    }

    pub fn mounts(&self) -> &MountRegistry {
        &self.mounts
    }

    pub fn workspace_runtime(&self) -> Arc<dyn WorkspaceRuntime> {
        self.workspace_runtime.clone()
    }

    pub fn events(&self) -> &broadcast::Sender<String> {
        &self.events
    }

    pub fn next_event_connection_id(&self) -> u64 {
        self.next_event_connection_id
            .fetch_add(1, Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;
    use tokio::sync::mpsc;
    use uuid::Uuid;

    use super::AppState;
    use crate::connection::ConnectionId;
    use crate::error::ApiError;
    use crate::terminal::session::{SessionHandle, TerminalEvent};
    use crate::workspace::{
        MountHandle, MountSpec, RuntimeStatus, TerminalOpenContext, WorkspaceRuntime,
    };

    struct TestRuntime;

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

        async fn unmount(&self, _mountpoint: &str) -> Result<(), ApiError> {
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
    fn event_connection_ids_are_shared_across_state_clones() {
        let state = AppState::new("test");
        let cloned = state.clone();

        assert_eq!(state.next_event_connection_id(), 1);
        assert_eq!(cloned.next_event_connection_id(), 2);
        assert_eq!(state.next_event_connection_id(), 3);
    }

    #[test]
    fn terminal_registry_is_shared_across_state_clones() {
        let state = AppState::new("test");
        let cloned = state.clone();

        assert!(state.terminals().is_shared_with(cloned.terminals()));
    }

    #[test]
    fn connection_registry_is_shared_across_state_clones() {
        let state = AppState::new("test");
        let cloned = state.clone();

        assert!(state.connections().is_shared_with(cloned.connections()));
    }

    #[test]
    fn mount_registry_is_shared_across_state_clones() {
        let state = AppState::new("test");
        let cloned = state.clone();
        let id = ConnectionId("connection-1".into());

        state
            .mounts()
            .get_or_reserve(&id, |_taken| "runtime://mount".into());
        state.mounts().mark_ready(&id);

        assert!(cloned.mounts().is_mounted(&id));
    }

    #[tokio::test]
    async fn workspace_runtime_is_present_and_retrievable() {
        let state = AppState::new_with_workspace_runtime("test", Arc::new(TestRuntime));

        let status = state.workspace_runtime().status().await;

        assert_eq!(status, RuntimeStatus::Ready);
    }
}
