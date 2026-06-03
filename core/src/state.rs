use crate::workspace::state::WorkspaceStore;

#[derive(Clone)]
pub struct AppState {
    pub version: &'static str,
    workspace: WorkspaceStore,
}

impl AppState {
    pub fn new(version: &'static str) -> Self {
        Self {
            version,
            workspace: WorkspaceStore::with_default_directory(),
        }
    }

    pub fn workspace(&self) -> &WorkspaceStore {
        &self.workspace
    }
}
