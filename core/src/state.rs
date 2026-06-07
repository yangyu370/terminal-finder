use std::sync::{
    Arc,
    atomic::{AtomicU64, Ordering},
};

use crate::terminal::registry::TerminalRegistry;
use crate::workspace::state::WorkspaceStore;
use tokio::sync::broadcast;

#[derive(Clone)]
pub struct AppState {
    pub version: &'static str,
    workspace: WorkspaceStore,
    terminals: TerminalRegistry,
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
            events,
            next_event_connection_id: Arc::new(AtomicU64::new(1)),
        }
    }

    pub fn workspace(&self) -> &WorkspaceStore {
        &self.workspace
    }

    pub fn terminals(&self) -> &TerminalRegistry {
        &self.terminals
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
    use super::AppState;

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
}
