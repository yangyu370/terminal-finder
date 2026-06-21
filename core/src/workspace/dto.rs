use std::path::PathBuf;

use serde::{Deserialize, Serialize};

#[derive(Debug, Deserialize)]
pub struct ListDirectoryParams {
    pub path: PathBuf,
    #[serde(default)]
    pub connection_id: Option<String>,
}

#[derive(Debug, Deserialize)]
pub struct OpenDirectoryParams {
    pub path: PathBuf,
    #[serde(default)]
    pub connection_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct GetStateResponse {
    pub state: WorkspaceStateResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct OpenDirectoryResponse {
    pub state: WorkspaceStateResponse,
    pub listing: ListDirectoryResponse,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WorkspaceStateResponse {
    pub workspace_root: String,
    pub current_directory: String,
    /// `"local"` for Phase 0 LocalFsProvider, `"s3"` once Phase 1 routes through `S3Provider`.
    pub scheme: String,
    /// `None` for local workspace; set to the registered S3 connection id when browsing a bucket.
    pub connection_id: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ListDirectoryResponse {
    pub path: String,
    pub entries: Vec<DirectoryEntry>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct DirectoryEntry {
    pub name: String,
    pub path: String,
    pub kind: EntryKind,
    pub is_directory: bool,
    pub size: Option<u64>,
    pub modified_at: Option<String>,
}

#[derive(Debug, Serialize, PartialEq, Eq, PartialOrd, Ord)]
#[serde(rename_all = "lowercase")]
pub enum EntryKind {
    Directory,
    File,
    Symlink,
    Other,
}
