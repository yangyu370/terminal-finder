use std::{
    collections::HashMap,
    sync::{Arc, Mutex},
};

use uuid::Uuid;

use crate::terminal::shell_integration::ShellIntegration;

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceTerminalBinding {
    pub session_id: Uuid,
    pub kind: WorkspaceTerminalKind,
    pub launch_workspace_root: String,
    pub launch_workspace_current_directory: String,
    pub scheme: String,
    pub connection_id: Option<String>,
    pub latest_terminal_working_directory: Option<String>,
    pub pending_target_directory: Option<String>,
    pub sync_capability: WorkspaceTerminalSyncCapability,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceTerminalKind {
    Local,
    Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum WorkspaceTerminalSyncCapability {
    BidirectionalLocal,
    LaunchOnly,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct WorkspaceTerminalLaunchSnapshot {
    pub workspace_root: String,
    pub current_directory: String,
    pub scheme: String,
    pub connection_id: Option<String>,
}

#[derive(Debug, Clone, Default)]
pub struct WorkspaceTerminalBindings {
    bindings: Arc<Mutex<HashMap<Uuid, WorkspaceTerminalBinding>>>,
    shell_integrations: Arc<Mutex<HashMap<Uuid, ShellIntegration>>>,
}

impl WorkspaceTerminalBindings {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn create(
        &self,
        session_id: Uuid,
        kind: WorkspaceTerminalKind,
        snapshot: WorkspaceTerminalLaunchSnapshot,
    ) -> WorkspaceTerminalBinding {
        let binding = WorkspaceTerminalBinding {
            session_id,
            kind,
            launch_workspace_root: snapshot.workspace_root,
            launch_workspace_current_directory: snapshot.current_directory,
            scheme: snapshot.scheme,
            connection_id: snapshot.connection_id,
            latest_terminal_working_directory: None,
            pending_target_directory: None,
            sync_capability: sync_capability_for_kind(kind),
        };

        self.bindings
            .lock()
            .expect("workspace terminal binding lock is not poisoned")
            .insert(session_id, binding.clone());

        binding
    }

    pub fn get(&self, session_id: Uuid) -> Option<WorkspaceTerminalBinding> {
        self.bindings
            .lock()
            .expect("workspace terminal binding lock is not poisoned")
            .get(&session_id)
            .cloned()
    }

    pub fn remove(&self, session_id: Uuid) -> Option<WorkspaceTerminalBinding> {
        self.shell_integrations
            .lock()
            .expect("workspace terminal shell integration lock is not poisoned")
            .remove(&session_id);
        self.bindings
            .lock()
            .expect("workspace terminal binding lock is not poisoned")
            .remove(&session_id)
    }

    pub fn attach_shell_integration(&self, session_id: Uuid, integration: ShellIntegration) {
        self.shell_integrations
            .lock()
            .expect("workspace terminal shell integration lock is not poisoned")
            .insert(session_id, integration);
    }

    pub fn shell_integration(&self, session_id: Uuid) -> Option<ShellIntegration> {
        self.shell_integrations
            .lock()
            .expect("workspace terminal shell integration lock is not poisoned")
            .get(&session_id)
            .cloned()
    }

    pub fn record_terminal_working_directory(
        &self,
        session_id: Uuid,
        directory: String,
    ) -> Option<WorkspaceTerminalBinding> {
        self.update(session_id, |binding| {
            binding.latest_terminal_working_directory = Some(directory);
        })
    }

    pub fn record_pending_target(
        &self,
        session_id: Uuid,
        directory: String,
    ) -> Option<WorkspaceTerminalBinding> {
        self.update(session_id, |binding| {
            binding.pending_target_directory = Some(directory);
        })
    }

    #[cfg(test)]
    pub fn is_shared_with(&self, other: &Self) -> bool {
        Arc::ptr_eq(&self.bindings, &other.bindings)
            && Arc::ptr_eq(&self.shell_integrations, &other.shell_integrations)
    }

    fn update(
        &self,
        session_id: Uuid,
        update: impl FnOnce(&mut WorkspaceTerminalBinding),
    ) -> Option<WorkspaceTerminalBinding> {
        let mut bindings = self
            .bindings
            .lock()
            .expect("workspace terminal binding lock is not poisoned");
        let binding = bindings.get_mut(&session_id)?;
        update(binding);
        Some(binding.clone())
    }
}

fn sync_capability_for_kind(kind: WorkspaceTerminalKind) -> WorkspaceTerminalSyncCapability {
    match kind {
        WorkspaceTerminalKind::Local => WorkspaceTerminalSyncCapability::BidirectionalLocal,
        WorkspaceTerminalKind::Connection => WorkspaceTerminalSyncCapability::LaunchOnly,
    }
}

#[cfg(test)]
mod tests {
    use uuid::Uuid;

    use super::*;

    fn local_snapshot(path: &str) -> WorkspaceTerminalLaunchSnapshot {
        WorkspaceTerminalLaunchSnapshot {
            workspace_root: path.to_string(),
            current_directory: path.to_string(),
            scheme: "local".to_string(),
            connection_id: None,
        }
    }

    #[test]
    fn local_binding_derives_bidirectional_capability_from_launch_kind() {
        let bindings = WorkspaceTerminalBindings::new();
        let session_id = Uuid::new_v4();

        let binding = bindings.create(
            session_id,
            WorkspaceTerminalKind::Local,
            WorkspaceTerminalLaunchSnapshot {
                workspace_root: "/workspace".to_string(),
                current_directory: "/workspace/app".to_string(),
                scheme: "local".to_string(),
                connection_id: None,
            },
        );

        assert_eq!(binding.session_id, session_id);
        assert_eq!(binding.kind, WorkspaceTerminalKind::Local);
        assert_eq!(
            binding.sync_capability,
            WorkspaceTerminalSyncCapability::BidirectionalLocal
        );
        assert_eq!(binding.latest_terminal_working_directory, None);
    }

    #[test]
    fn connection_binding_derives_launch_only_capability_from_launch_kind() {
        let bindings = WorkspaceTerminalBindings::new();

        let binding = bindings.create(
            Uuid::new_v4(),
            WorkspaceTerminalKind::Connection,
            WorkspaceTerminalLaunchSnapshot {
                workspace_root: "prefix/".to_string(),
                current_directory: "prefix/".to_string(),
                scheme: "s3".to_string(),
                connection_id: Some("conn-1".to_string()),
            },
        );

        assert_eq!(
            binding.sync_capability,
            WorkspaceTerminalSyncCapability::LaunchOnly
        );
    }

    #[test]
    fn latest_terminal_working_directory_is_advisory_and_mutable() {
        let bindings = WorkspaceTerminalBindings::new();
        let session_id = Uuid::new_v4();
        bindings.create(
            session_id,
            WorkspaceTerminalKind::Local,
            local_snapshot("/workspace"),
        );

        let updated = bindings
            .record_terminal_working_directory(session_id, "/tmp".to_string())
            .expect("known session updates");

        assert_eq!(
            updated.latest_terminal_working_directory.as_deref(),
            Some("/tmp")
        );
        assert_eq!(
            bindings
                .get(session_id)
                .unwrap()
                .launch_workspace_current_directory,
            "/workspace"
        );
    }

    #[test]
    fn removing_binding_clears_pending_target_and_latest_cwd() {
        let bindings = WorkspaceTerminalBindings::new();
        let session_id = Uuid::new_v4();
        bindings.create(
            session_id,
            WorkspaceTerminalKind::Local,
            local_snapshot("/workspace"),
        );
        bindings
            .record_terminal_working_directory(session_id, "/tmp".to_string())
            .unwrap();
        bindings
            .record_pending_target(session_id, "/var".to_string())
            .unwrap();

        assert!(bindings.remove(session_id).is_some());
        assert!(bindings.get(session_id).is_none());
    }
}
