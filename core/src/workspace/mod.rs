pub mod docker;
pub mod dto;
pub mod mount_table;
pub mod naming;
pub mod rclone;
pub mod service;
pub mod state;

use async_trait::async_trait;
use tokio::sync::mpsc;

use crate::connection::{ConnectionId, Credential, S3ConnectionConfig};
use crate::error::ApiError;
use crate::terminal::session::{SessionHandle, TerminalEvent};

pub use dto::{
    DirectoryEntry, EntryKind, GetStateResponse, ListDirectoryParams, ListDirectoryResponse,
    OpenDirectoryParams, OpenDirectoryResponse, WorkspaceStateResponse,
};
pub use service::{get_state, list_directory, open_directory};

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum RuntimeStatus {
    Ready,
    Unavailable,
}

pub struct MountSpec {
    pub connection_id: ConnectionId,
    pub config: S3ConnectionConfig,
    pub credential: Credential,
    pub mountpoint: String,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct MountHandle {
    pub mountpoint: String,
}

pub struct TerminalOpenContext {
    pub workdir: String,
}

#[async_trait]
pub trait WorkspaceRuntime: Send + Sync {
    async fn status(&self) -> RuntimeStatus;

    async fn ensure_ready(&self) -> Result<(), ApiError>;

    fn propose_mountpoint(&self, display_name: &str, taken: &[String]) -> String;

    async fn mount(&self, spec: MountSpec) -> Result<MountHandle, ApiError>;

    async fn unmount(&self, mountpoint: &str) -> Result<(), ApiError>;

    async fn open_terminal(
        &self,
        ctx: TerminalOpenContext,
        cols: u16,
        rows: u16,
        events: mpsc::Sender<TerminalEvent>,
    ) -> Result<SessionHandle, ApiError>;

    async fn teardown(&self) -> Result<(), ApiError>;
}
