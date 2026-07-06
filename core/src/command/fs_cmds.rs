use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    command::{CommandDescriptor, CommandHandler},
    error::ApiError,
    state::AppState,
    workspace::service,
};

const DELETE_ID: &str = "fs.delete";
const RENAME_ID: &str = "fs.rename";
const UPLOAD_ID: &str = "fs.upload";
const DOWNLOAD_ID: &str = "fs.download";
const MKDIR_ID: &str = "fs.mkdir";
const CATEGORY: &str = "fs";

#[derive(Deserialize)]
struct PathParams {
    #[serde(default)]
    connection_id: Option<String>,
    path: String,
}

#[derive(Deserialize)]
struct RenameParams {
    #[serde(default)]
    connection_id: Option<String>,
    from: String,
    to: String,
}

#[derive(Deserialize)]
struct UploadParams {
    #[serde(default)]
    connection_id: Option<String>,
    remote_path: String,
    local_source: String,
}

#[derive(Deserialize)]
struct DownloadParams {
    #[serde(default)]
    connection_id: Option<String>,
    remote_path: String,
    local_destination: String,
}

pub struct DeleteEntryCommand;

#[async_trait]
impl CommandHandler for DeleteEntryCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: DELETE_ID.into(),
            title: "Delete Entry".into(),
            category: CATEGORY.into(),
            summary: "Recursively deletes the file, directory, or object at a path.".into(),
            params_schema: path_params_schema(),
            result_schema: null_result_schema(),
            destructive: true,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = deserialize::<PathParams>(DELETE_ID, params)?;
        service::delete_entry(state, params.connection_id.as_deref(), &params.path).await?;
        Ok(Value::Null)
    }
}

pub struct RenameEntryCommand;

#[async_trait]
impl CommandHandler for RenameEntryCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: RENAME_ID.into(),
            title: "Rename Entry".into(),
            category: CATEGORY.into(),
            summary: "Renames or moves an entry within a single connection.".into(),
            params_schema: json!({
                "type": "object",
                "required": ["from", "to"],
                "properties": {
                    "connection_id": { "type": ["string", "null"] },
                    "from": { "type": "string" },
                    "to": { "type": "string" }
                }
            }),
            result_schema: null_result_schema(),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = deserialize::<RenameParams>(RENAME_ID, params)?;
        service::rename_entry(
            state,
            params.connection_id.as_deref(),
            &params.from,
            &params.to,
        )
        .await?;
        Ok(Value::Null)
    }
}

pub struct UploadFileCommand;

#[async_trait]
impl CommandHandler for UploadFileCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: UPLOAD_ID.into(),
            title: "Upload File".into(),
            category: CATEGORY.into(),
            summary: "Uploads a local file to a remote path.".into(),
            params_schema: json!({
                "type": "object",
                "required": ["remote_path", "local_source"],
                "properties": {
                    "connection_id": { "type": ["string", "null"] },
                    "remote_path": { "type": "string" },
                    "local_source": { "type": "string" }
                }
            }),
            result_schema: null_result_schema(),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = deserialize::<UploadParams>(UPLOAD_ID, params)?;
        service::upload_file(
            state,
            params.connection_id.as_deref(),
            &params.remote_path,
            &params.local_source,
        )
        .await?;
        Ok(Value::Null)
    }
}

pub struct DownloadFileCommand;

#[async_trait]
impl CommandHandler for DownloadFileCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: DOWNLOAD_ID.into(),
            title: "Download File".into(),
            category: CATEGORY.into(),
            summary: "Downloads a remote path to a local destination.".into(),
            params_schema: json!({
                "type": "object",
                "required": ["remote_path", "local_destination"],
                "properties": {
                    "connection_id": { "type": ["string", "null"] },
                    "remote_path": { "type": "string" },
                    "local_destination": { "type": "string" }
                }
            }),
            result_schema: null_result_schema(),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = deserialize::<DownloadParams>(DOWNLOAD_ID, params)?;
        service::download_file(
            state,
            params.connection_id.as_deref(),
            &params.remote_path,
            &params.local_destination,
        )
        .await?;
        Ok(Value::Null)
    }
}

pub struct CreateDirectoryCommand;

#[async_trait]
impl CommandHandler for CreateDirectoryCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: MKDIR_ID.into(),
            title: "Create Directory".into(),
            category: CATEGORY.into(),
            summary: "Creates a directory (or zero-byte marker on object stores).".into(),
            params_schema: path_params_schema(),
            result_schema: null_result_schema(),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = deserialize::<PathParams>(MKDIR_ID, params)?;
        service::create_remote_directory(state, params.connection_id.as_deref(), &params.path)
            .await?;
        Ok(Value::Null)
    }
}

fn deserialize<T: for<'de> Deserialize<'de>>(
    method: &'static str,
    params: Value,
) -> Result<T, ApiError> {
    serde_json::from_value(params).map_err(|err| ApiError::InvalidParams {
        method: method.into(),
        message: err.to_string(),
    })
}

fn path_params_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path"],
        "properties": {
            "connection_id": { "type": ["string", "null"] },
            "path": { "type": "string" }
        }
    })
}

fn null_result_schema() -> Value {
    json!({ "type": "null" })
}

#[cfg(test)]
mod tests {
    use std::{fs, path::PathBuf};

    use serde_json::json;

    use super::*;
    use crate::command::CommandRegistry;

    fn temp_path(prefix: &str) -> PathBuf {
        std::env::temp_dir().join(format!(
            "{prefix}_{}_{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .expect("system time after unix epoch")
                .as_nanos()
        ))
    }

    #[test]
    fn descriptors_match_command_table() {
        assert!(DeleteEntryCommand.descriptor().destructive);
        assert_eq!(DeleteEntryCommand.descriptor().id, "fs.delete");
        assert_eq!(DeleteEntryCommand.descriptor().category, "fs");

        for (handler_id, expected) in [
            (RenameEntryCommand.descriptor(), "fs.rename"),
            (UploadFileCommand.descriptor(), "fs.upload"),
            (DownloadFileCommand.descriptor(), "fs.download"),
            (CreateDirectoryCommand.descriptor(), "fs.mkdir"),
        ] {
            assert_eq!(handler_id.id, expected);
            assert_eq!(handler_id.category, "fs");
            assert!(
                !handler_id.destructive,
                "only fs.delete is destructive, got {expected}"
            );
        }
    }

    #[test]
    fn registry_new_contains_all_fs_commands() {
        let ids: Vec<String> = CommandRegistry::new()
            .list()
            .into_iter()
            .map(|descriptor| descriptor.id)
            .collect();

        for id in [
            "fs.delete",
            "fs.rename",
            "fs.upload",
            "fs.download",
            "fs.mkdir",
        ] {
            assert!(ids.contains(&id.to_string()), "registry missing {id}");
        }
    }

    #[tokio::test]
    async fn delete_invoke_removes_real_file_and_returns_null() {
        let state = AppState::new(crate::CORE_VERSION);
        let file = temp_path("tf_cmd_delete");
        fs::write(&file, b"bye").expect("write temp file");

        let result = DeleteEntryCommand
            .invoke(&state, json!({ "path": file.to_string_lossy() }))
            .await
            .expect("delete command succeeds");

        assert_eq!(result, Value::Null);
        assert!(!file.exists(), "file must be gone after fs.delete");
    }

    #[tokio::test]
    async fn rename_invoke_moves_real_file() {
        let state = AppState::new(crate::CORE_VERSION);
        let from = temp_path("tf_cmd_rename_from");
        let to = temp_path("tf_cmd_rename_to");
        fs::write(&from, b"hi").expect("write temp file");

        RenameEntryCommand
            .invoke(
                &state,
                json!({ "from": from.to_string_lossy(), "to": to.to_string_lossy() }),
            )
            .await
            .expect("rename command succeeds");

        assert!(!from.exists());
        assert!(to.exists());
        let _ = fs::remove_file(&to);
    }

    #[tokio::test]
    async fn mkdir_invoke_creates_directory() {
        let state = AppState::new(crate::CORE_VERSION);
        let dir = temp_path("tf_cmd_mkdir");

        CreateDirectoryCommand
            .invoke(&state, json!({ "path": dir.to_string_lossy() }))
            .await
            .expect("mkdir command succeeds");

        assert!(dir.is_dir());
        let _ = fs::remove_dir_all(&dir);
    }

    #[tokio::test]
    async fn missing_required_field_returns_invalid_params() {
        let state = AppState::new(crate::CORE_VERSION);

        let err = DeleteEntryCommand
            .invoke(&state, json!({}))
            .await
            .expect_err("missing path must fail");
        assert_eq!(err.code(), "invalid_params");

        let err = RenameEntryCommand
            .invoke(&state, json!({ "from": "/a" }))
            .await
            .expect_err("missing `to` must fail");
        assert_eq!(err.code(), "invalid_params");
    }
}
