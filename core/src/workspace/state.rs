use std::{
    env,
    path::PathBuf,
    sync::{Arc, RwLock},
};

#[derive(Debug, Clone)]
pub struct WorkspaceState {
    pub workspace_root: PathBuf,
    pub current_directory: PathBuf,
}

#[derive(Clone)]
pub struct WorkspaceStore {
    workspace: Arc<RwLock<WorkspaceState>>,
}

impl WorkspaceStore {
    pub fn new(initial_directory: PathBuf) -> Self {
        Self {
            workspace: Arc::new(RwLock::new(WorkspaceState {
                workspace_root: initial_directory.clone(),
                current_directory: initial_directory,
            })),
        }
    }

    pub fn with_default_directory() -> Self {
        Self::new(default_workspace_directory())
    }

    pub fn state(&self) -> WorkspaceState {
        self.workspace
            .read()
            .expect("workspace state lock is not poisoned")
            .clone()
    }

    pub fn set_directory_state(
        &self,
        workspace_root: PathBuf,
        current_directory: PathBuf,
    ) -> WorkspaceState {
        let mut workspace = self
            .workspace
            .write()
            .expect("workspace state lock is not poisoned");

        workspace.workspace_root = workspace_root;
        workspace.current_directory = current_directory;
        workspace.clone()
    }
}

fn default_workspace_directory() -> PathBuf {
    env::var_os("HOME")
        .or_else(|| env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .filter(|path| path.is_dir())
        .or_else(|| env::current_dir().ok())
        .unwrap_or_else(env::temp_dir)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn setting_directory_state_updates_root_and_current_directory_atomically() {
        let initial_directory = std::env::temp_dir();
        let store = WorkspaceStore::new(initial_directory.clone());
        let next_root = initial_directory.join("next");
        let next_directory = next_root.join("child");

        let workspace = store.set_directory_state(next_root.clone(), next_directory.clone());

        assert_eq!(workspace.workspace_root, next_root);
        assert_eq!(workspace.current_directory, next_directory);
    }
}
