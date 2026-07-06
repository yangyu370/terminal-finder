use async_trait::async_trait;
use serde_json::{Value, json};

use crate::{
    command::{CommandDescriptor, CommandHandler},
    error::ApiError,
    state::AppState,
    workspace::{ListDirectoryParams, OpenDirectoryParams, list_directory, open_directory},
};

const LIST_DIRECTORY_ID: &str = "workspace.listDirectory";
const OPEN_DIRECTORY_ID: &str = "workspace.openDirectory";
const CATEGORY: &str = "workspace";

pub struct ListDirectoryCommand;

#[async_trait]
impl CommandHandler for ListDirectoryCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: LIST_DIRECTORY_ID.into(),
            title: "List Directory".into(),
            category: CATEGORY.into(),
            summary: "Returns the non-recursive directory listing for a workspace path.".into(),
            params_schema: workspace_path_params_schema(),
            result_schema: list_directory_result_schema(),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = serde_json::from_value::<ListDirectoryParams>(params).map_err(|err| {
            ApiError::InvalidParams {
                method: LIST_DIRECTORY_ID.into(),
                message: err.to_string(),
            }
        })?;

        let response = list_directory(state, params).await?;
        serialize_response(LIST_DIRECTORY_ID, response)
    }
}

pub struct OpenDirectoryCommand;

#[async_trait]
impl CommandHandler for OpenDirectoryCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: OPEN_DIRECTORY_ID.into(),
            title: "Open Directory".into(),
            category: CATEGORY.into(),
            summary: "Opens a workspace directory and returns updated state with its listing."
                .into(),
            params_schema: workspace_path_params_schema(),
            result_schema: json!({
                "type": "object",
                "required": ["state", "listing"],
                "properties": {
                    "state": workspace_state_schema(),
                    "listing": list_directory_result_schema()
                }
            }),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = serde_json::from_value::<OpenDirectoryParams>(params).map_err(|err| {
            ApiError::InvalidParams {
                method: OPEN_DIRECTORY_ID.into(),
                message: err.to_string(),
            }
        })?;

        let response = open_directory(state, params).await?;
        serialize_response(OPEN_DIRECTORY_ID, response)
    }
}

fn workspace_path_params_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path"],
        "properties": {
            "path": { "type": "string" },
            "connection_id": { "type": ["string", "null"] }
        }
    })
}

fn list_directory_result_schema() -> Value {
    json!({
        "type": "object",
        "required": ["path", "entries"],
        "properties": {
            "path": { "type": "string" },
            "entries": {
                "type": "array",
                "items": directory_entry_schema()
            }
        }
    })
}

fn workspace_state_schema() -> Value {
    json!({
        "type": "object",
        "required": ["workspaceRoot", "currentDirectory", "scheme"],
        "properties": {
            "workspaceRoot": { "type": "string" },
            "currentDirectory": { "type": "string" },
            "scheme": { "type": "string" },
            "connectionId": { "type": ["string", "null"] }
        }
    })
}

fn directory_entry_schema() -> Value {
    json!({
        "type": "object",
        "required": ["name", "path", "kind", "isDirectory"],
        "properties": {
            "name": { "type": "string" },
            "path": { "type": "string" },
            "kind": {
                "type": "string",
                "enum": ["directory", "file", "symlink", "other"]
            },
            "isDirectory": { "type": "boolean" },
            "size": { "type": ["integer", "null"], "minimum": 0 },
            "modifiedAt": { "type": ["string", "null"] }
        }
    })
}

fn serialize_response<T: serde::Serialize>(
    operation: &'static str,
    response: T,
) -> Result<Value, ApiError> {
    serde_json::to_value(response).map_err(|err| ApiError::ProviderError {
        operation,
        message: err.to_string(),
    })
}

#[cfg(test)]
mod tests {
    use std::{
        fs,
        path::{Path, PathBuf},
    };

    use serde_json::json;

    use super::{ListDirectoryCommand, OpenDirectoryCommand};
    use crate::{
        command::{CommandHandler, CommandRegistry},
        state::AppState,
    };

    #[test]
    fn list_directory_descriptor_matches_phase_zero_contract() {
        let descriptor = ListDirectoryCommand.descriptor();

        assert_eq!(descriptor.id, "workspace.listDirectory");
        assert_eq!(descriptor.category, "workspace");
        assert!(!descriptor.destructive);
    }

    #[test]
    fn params_schema_matches_serde_validation_contract() {
        let schema = ListDirectoryCommand.descriptor().params_schema;

        assert_eq!(schema["required"], json!(["path"]));
        assert_eq!(schema["properties"]["path"]["type"], "string");
        assert_eq!(
            schema["properties"]["connection_id"]["type"],
            json!(["string", "null"])
        );
        assert!(
            schema.get("additionalProperties").is_none(),
            "workspace DTOs accept unknown fields, so the descriptor must not reject them"
        );
    }

    #[test]
    fn open_directory_descriptor_matches_phase_zero_contract() {
        let descriptor = OpenDirectoryCommand.descriptor();

        assert_eq!(descriptor.id, "workspace.openDirectory");
        assert_eq!(descriptor.category, "workspace");
        assert!(!descriptor.destructive);
    }

    #[test]
    fn new_registry_contains_workspace_commands() {
        let registry = CommandRegistry::new();

        let ids: Vec<String> = registry
            .list()
            .into_iter()
            .map(|descriptor| descriptor.id)
            .collect();

        for id in ["workspace.listDirectory", "workspace.openDirectory"] {
            assert!(
                ids.contains(&id.to_string()),
                "registry must seed {id}, got {ids:?}"
            );
        }
    }

    #[tokio::test]
    async fn list_directory_invoke_returns_entries_from_real_directory() {
        let temp = TempDir::new("tf_command_list");
        let entry_path = temp.path().join("entry.txt");
        fs::write(&entry_path, b"hello").expect("write test entry");
        let state = AppState::new(crate::CORE_VERSION);

        let result = ListDirectoryCommand
            .invoke(&state, json!({ "path": temp.path() }))
            .await
            .expect("list directory command succeeds");

        let names: Vec<&str> = result["entries"]
            .as_array()
            .expect("entries is an array")
            .iter()
            .filter_map(|entry| entry["name"].as_str())
            .collect();
        assert!(names.contains(&"entry.txt"));
    }

    #[tokio::test]
    async fn open_directory_invoke_file_path_returns_not_directory() {
        let temp = TempDir::new("tf_command_open_file");
        let file_path = temp.path().join("file.txt");
        fs::write(&file_path, b"hello").expect("write test file");
        let state = AppState::new(crate::CORE_VERSION);

        let err = OpenDirectoryCommand
            .invoke(&state, json!({ "path": file_path }))
            .await
            .expect_err("opening a file as a directory fails");

        assert_eq!(err.code(), "not_directory");
    }

    #[tokio::test]
    async fn missing_path_returns_invalid_params() {
        let state = AppState::new(crate::CORE_VERSION);

        let err = ListDirectoryCommand
            .invoke(&state, json!({}))
            .await
            .expect_err("missing path fails");

        assert_eq!(err.code(), "invalid_params");
    }

    struct TempDir {
        path: PathBuf,
    }

    impl TempDir {
        fn new(prefix: &str) -> Self {
            let path = std::env::temp_dir().join(format!(
                "{prefix}_{}_{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .expect("system time after unix epoch")
                    .as_nanos()
            ));
            fs::create_dir(&path).expect("create test temp dir");
            Self { path }
        }

        fn path(&self) -> &Path {
            &self.path
        }
    }

    impl Drop for TempDir {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}
