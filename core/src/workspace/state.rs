use std::{
    env,
    path::PathBuf,
    sync::{Arc, RwLock},
};

/// Workspace 当前定位。`scheme == "local"` 时 `workspace_root` / `current_directory`
/// 是 OS 路径；`scheme == "s3"` 时是带斜线的 S3 前缀字符串（包到 PathBuf 里只是为了
/// 复用 `to_string_lossy`，不做 OS 路径语义解释）。
#[derive(Debug, Clone)]
pub struct WorkspaceState {
    pub workspace_root: PathBuf,
    pub current_directory: PathBuf,
    pub scheme: String,
    pub connection_id: Option<String>,
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
                scheme: "local".to_string(),
                connection_id: None,
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

    /// 一次原子更新 root/current/scheme/connection_id 四个字段。
    /// 由 `workspace::service::open_directory` 在 listing 成功后调用，避免读到
    /// "scheme 已变但路径没变" 之类的中间态。
    pub fn set_directory_state(
        &self,
        workspace_root: PathBuf,
        current_directory: PathBuf,
        scheme: String,
        connection_id: Option<String>,
    ) -> WorkspaceState {
        let mut workspace = self
            .workspace
            .write()
            .expect("workspace state lock is not poisoned");

        workspace.workspace_root = workspace_root;
        workspace.current_directory = current_directory;
        workspace.scheme = scheme;
        workspace.connection_id = connection_id;
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

        let workspace = store.set_directory_state(
            next_root.clone(),
            next_directory.clone(),
            "local".to_string(),
            None,
        );

        assert_eq!(workspace.workspace_root, next_root);
        assert_eq!(workspace.current_directory, next_directory);
        assert_eq!(workspace.scheme, "local");
        assert!(workspace.connection_id.is_none());
    }

    #[test]
    fn setting_directory_state_records_scheme_and_connection_id_atomically() {
        let store = WorkspaceStore::new(std::env::temp_dir());

        let workspace = store.set_directory_state(
            PathBuf::from("conn-prefix/"),
            PathBuf::from("conn-prefix/"),
            "s3".to_string(),
            Some("conn-id".to_string()),
        );

        assert_eq!(workspace.scheme, "s3");
        assert_eq!(workspace.connection_id.as_deref(), Some("conn-id"));
    }
}
