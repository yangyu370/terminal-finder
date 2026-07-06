//! 跨 FFI 边界的数据类型（uniffi Record/Enum）。
//!
//! 刻意独立于 `workspace::dto`（那套带 serde、服务于 server JSON）：业务 DTO 不该被叠加
//! FFI 派生。这里用 `From` 把协议响应转成 Swift 友好的结构，字段命名由 UniFFI 自动转 camelCase。

use crate::terminal::binding::{
    WorkspaceTerminalBinding, WorkspaceTerminalKind, WorkspaceTerminalSyncCapability,
};
use crate::workspace::dto::WorkspaceStateResponse;

/// 连通性信息，对应 `core.ping`。
#[derive(Debug, uniffi::Record)]
pub struct PingInfo {
    pub service: String,
    pub version: String,
}

/// 工作区状态，对应 `workspace.getState`。
///
/// `scheme` 为 `"local"` 表示 LocalFsProvider；`"s3"` 表示当前 workspace 落在某个
/// S3 连接的前缀上，`connection_id` 同时被设。Phase 0 始终是 local / None。
#[derive(Debug, uniffi::Record)]
pub struct WorkspaceStateDto {
    pub workspace_root: String,
    pub current_directory: String,
    pub scheme: String,
    pub connection_id: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceTerminalKindDto {
    Local,
    Connection,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, uniffi::Enum)]
pub enum WorkspaceTerminalSyncCapabilityDto {
    BidirectionalLocal,
    LaunchOnly,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceTerminalBindingDto {
    pub session_id: String,
    pub kind: WorkspaceTerminalKindDto,
    pub launch_workspace_root: String,
    pub launch_workspace_current_directory: String,
    pub scheme: String,
    pub connection_id: Option<String>,
    pub latest_terminal_working_directory: Option<String>,
    pub sync_capability: WorkspaceTerminalSyncCapabilityDto,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct WorkspaceTerminalCreateDto {
    pub binding: WorkspaceTerminalBindingDto,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalWorkingDirectoryUpdateDto {
    pub binding: WorkspaceTerminalBindingDto,
    pub reported_directory: String,
    pub openable: bool,
    pub matches_current: bool,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, uniffi::Record)]
pub struct TerminalDirectoryChangeDto {
    pub binding: WorkspaceTerminalBindingDto,
    pub queued: bool,
    pub target_directory: String,
    pub reason: Option<String>,
}

impl From<WorkspaceStateResponse> for WorkspaceStateDto {
    fn from(value: WorkspaceStateResponse) -> Self {
        Self {
            workspace_root: value.workspace_root,
            current_directory: value.current_directory,
            scheme: value.scheme,
            connection_id: value.connection_id,
        }
    }
}

impl From<WorkspaceTerminalKind> for WorkspaceTerminalKindDto {
    fn from(value: WorkspaceTerminalKind) -> Self {
        match value {
            WorkspaceTerminalKind::Local => WorkspaceTerminalKindDto::Local,
            WorkspaceTerminalKind::Connection => WorkspaceTerminalKindDto::Connection,
        }
    }
}

impl From<WorkspaceTerminalSyncCapability> for WorkspaceTerminalSyncCapabilityDto {
    fn from(value: WorkspaceTerminalSyncCapability) -> Self {
        match value {
            WorkspaceTerminalSyncCapability::BidirectionalLocal => {
                WorkspaceTerminalSyncCapabilityDto::BidirectionalLocal
            }
            WorkspaceTerminalSyncCapability::LaunchOnly => {
                WorkspaceTerminalSyncCapabilityDto::LaunchOnly
            }
        }
    }
}

impl From<WorkspaceTerminalBinding> for WorkspaceTerminalBindingDto {
    fn from(value: WorkspaceTerminalBinding) -> Self {
        Self {
            session_id: value.session_id.to_string(),
            kind: value.kind.into(),
            launch_workspace_root: value.launch_workspace_root,
            launch_workspace_current_directory: value.launch_workspace_current_directory,
            scheme: value.scheme,
            connection_id: value.connection_id,
            latest_terminal_working_directory: value.latest_terminal_working_directory,
            sync_capability: value.sync_capability.into(),
        }
    }
}

/// Provider capability flags exposed to the client UI so it can gate or
/// warn on operations the underlying store can't honour (e.g. S3 has no
/// atomic rename and no native directories).
#[derive(Debug, Clone, uniffi::Record)]
pub struct ProviderCapsDto {
    pub can_rename: bool,
    pub can_symlink: bool,
    pub can_write: bool,
    pub has_native_directories: bool,
}
