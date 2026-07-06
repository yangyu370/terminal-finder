use std::{collections::HashMap, sync::Arc};

use async_trait::async_trait;
use serde::Serialize;
use serde_json::Value;

use crate::{error::ApiError, state::AppState};

pub mod fs_cmds;
pub mod workspace_cmds;

#[derive(Debug, Clone, Serialize, PartialEq)]
pub struct CommandDescriptor {
    pub id: String,
    pub title: String,
    pub category: String,
    pub summary: String,
    pub params_schema: Value,
    pub result_schema: Value,
    pub destructive: bool,
    pub context_requirements: Vec<String>,
}

#[async_trait]
pub trait CommandHandler: Send + Sync {
    fn descriptor(&self) -> CommandDescriptor;

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError>;
}

pub struct CommandRegistry {
    handlers: HashMap<String, Arc<dyn CommandHandler>>,
}

impl CommandRegistry {
    pub fn new() -> Self {
        use fs_cmds::{
            CreateDirectoryCommand, DeleteEntryCommand, DownloadFileCommand, RenameEntryCommand,
            UploadFileCommand,
        };
        use workspace_cmds::{ListDirectoryCommand, OpenDirectoryCommand};

        Self::from_handlers(vec![
            Arc::new(OpenDirectoryCommand),
            Arc::new(ListDirectoryCommand),
            Arc::new(DeleteEntryCommand),
            Arc::new(RenameEntryCommand),
            Arc::new(UploadFileCommand),
            Arc::new(DownloadFileCommand),
            Arc::new(CreateDirectoryCommand),
        ])
    }

    pub fn from_handlers(handlers: Vec<Arc<dyn CommandHandler>>) -> Self {
        let handlers = handlers
            .into_iter()
            .map(|handler| (handler.descriptor().id, handler))
            .collect();

        Self { handlers }
    }

    pub fn list(&self) -> Vec<CommandDescriptor> {
        let mut descriptors: Vec<CommandDescriptor> = self
            .handlers
            .values()
            .map(|handler| handler.descriptor())
            .collect();
        descriptors.sort_by(|left, right| left.id.cmp(&right.id));
        descriptors
    }

    pub fn describe(&self, id: &str) -> Option<CommandDescriptor> {
        self.handlers.get(id).map(|handler| handler.descriptor())
    }

    pub async fn invoke(
        &self,
        state: &AppState,
        id: &str,
        params: Value,
    ) -> Result<Value, ApiError> {
        let handler = self
            .handlers
            .get(id)
            .ok_or_else(|| ApiError::UnknownMethod(id.into()))?;

        handler.invoke(state, params).await
    }
}

impl Default for CommandRegistry {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use async_trait::async_trait;
    use serde_json::{Value, json};

    use super::{CommandDescriptor, CommandHandler, CommandRegistry};
    use crate::{error::ApiError, state::AppState};

    struct StubEcho {
        id: String,
    }

    impl StubEcho {
        fn new(id: &str) -> Self {
            Self { id: id.into() }
        }
    }

    #[async_trait]
    impl CommandHandler for StubEcho {
        fn descriptor(&self) -> CommandDescriptor {
            CommandDescriptor {
                id: self.id.clone(),
                title: format!("Echo {}", self.id),
                category: "test".into(),
                summary: "Echoes the message parameter".into(),
                params_schema: json!({
                    "type": "object",
                    "required": ["message"],
                    "properties": {
                        "message": { "type": "string" }
                    }
                }),
                result_schema: json!({
                    "type": "object",
                    "properties": {
                        "message": { "type": "string" }
                    }
                }),
                destructive: false,
                context_requirements: vec![],
            }
        }

        async fn invoke(&self, _state: &AppState, params: Value) -> Result<Value, ApiError> {
            let message = params
                .get("message")
                .and_then(Value::as_str)
                .ok_or_else(|| ApiError::InvalidParams {
                    method: self.id.clone(),
                    message: "missing string parameter: message".into(),
                })?;

            Ok(json!({ "message": message }))
        }
    }

    fn registry_with(ids: &[&str]) -> CommandRegistry {
        let handlers = ids
            .iter()
            .map(|id| Arc::new(StubEcho::new(id)) as Arc<dyn CommandHandler>)
            .collect();

        CommandRegistry::from_handlers(handlers)
    }

    #[test]
    fn list_returns_descriptors_sorted_by_id() {
        let registry = registry_with(&["workspace.zeta", "workspace.alpha", "workspace.beta"]);

        let ids: Vec<String> = registry
            .list()
            .into_iter()
            .map(|descriptor| descriptor.id)
            .collect();

        assert_eq!(ids, ["workspace.alpha", "workspace.beta", "workspace.zeta"]);
    }

    #[test]
    fn describe_unknown_id_returns_none() {
        let registry = registry_with(&["workspace.echo"]);

        assert_eq!(registry.describe("workspace.missing"), None);
    }

    #[tokio::test]
    async fn invoke_unknown_id_returns_unknown_method() {
        let registry = registry_with(&["workspace.echo"]);
        let state = AppState::new(crate::CORE_VERSION);

        let err = registry
            .invoke(&state, "workspace.missing", json!({}))
            .await
            .expect_err("unknown command should fail");

        assert_eq!(err.code(), "unknown_method");
    }

    #[tokio::test]
    async fn invoke_happy_path_echoes_message() {
        let registry = registry_with(&["workspace.echo"]);
        let state = AppState::new(crate::CORE_VERSION);

        let result = registry
            .invoke(&state, "workspace.echo", json!({ "message": "hello" }))
            .await
            .expect("echo command should succeed");

        assert_eq!(result, json!({ "message": "hello" }));
    }

    #[tokio::test]
    async fn invoke_missing_parameter_returns_invalid_params() {
        let registry = registry_with(&["workspace.echo"]);
        let state = AppState::new(crate::CORE_VERSION);

        let err = registry
            .invoke(&state, "workspace.echo", json!({}))
            .await
            .expect_err("missing parameter should fail");

        assert_eq!(err.code(), "invalid_params");
    }
}
