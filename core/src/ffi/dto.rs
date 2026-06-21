//! 跨 FFI 边界的数据类型（uniffi Record/Enum）。
//!
//! 刻意独立于 `workspace::dto`（那套带 serde、服务于 server JSON）：业务 DTO 不该被叠加
//! FFI 派生。这里用 `From` 把协议响应转成 Swift 友好的结构，字段命名由 UniFFI 自动转 camelCase。

use crate::workspace::dto::{
    DirectoryEntry, EntryKind, ListDirectoryResponse, OpenDirectoryResponse, WorkspaceStateResponse,
};

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

/// 目录条目类型。
#[derive(Debug, uniffi::Enum)]
pub enum EntryKindDto {
    Directory,
    File,
    Symlink,
    Other,
}

/// 单个目录条目。
#[derive(Debug, uniffi::Record)]
pub struct DirectoryEntryDto {
    pub name: String,
    pub path: String,
    pub kind: EntryKindDto,
    pub is_directory: bool,
    pub size: Option<u64>,
    pub modified_at: Option<String>,
}

/// 目录清单，对应 `workspace.listDirectory`。
#[derive(Debug, uniffi::Record)]
pub struct DirectoryListingDto {
    pub path: String,
    pub entries: Vec<DirectoryEntryDto>,
}

/// 打开目录的结果，对应 `workspace.openDirectory`。
#[derive(Debug, uniffi::Record)]
pub struct OpenDirectoryDto {
    pub state: WorkspaceStateDto,
    pub listing: DirectoryListingDto,
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

impl From<EntryKind> for EntryKindDto {
    fn from(value: EntryKind) -> Self {
        match value {
            EntryKind::Directory => EntryKindDto::Directory,
            EntryKind::File => EntryKindDto::File,
            EntryKind::Symlink => EntryKindDto::Symlink,
            EntryKind::Other => EntryKindDto::Other,
        }
    }
}

impl From<DirectoryEntry> for DirectoryEntryDto {
    fn from(value: DirectoryEntry) -> Self {
        Self {
            name: value.name,
            path: value.path,
            kind: value.kind.into(),
            is_directory: value.is_directory,
            size: value.size,
            modified_at: value.modified_at,
        }
    }
}

impl From<ListDirectoryResponse> for DirectoryListingDto {
    fn from(value: ListDirectoryResponse) -> Self {
        Self {
            path: value.path,
            entries: value.entries.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<OpenDirectoryResponse> for OpenDirectoryDto {
    fn from(value: OpenDirectoryResponse) -> Self {
        Self {
            state: value.state.into(),
            listing: value.listing.into(),
        }
    }
}

/// Connection summary DTO (does NOT carry credentials — see `phase1.md` §6.3).
#[derive(Debug, uniffi::Record)]
pub struct ConnectionInfoDto {
    pub connection_id: String,
    pub display_name: String,
    pub endpoint: String,
    pub bucket: String,
    pub base_prefix: String,
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
