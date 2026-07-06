use async_trait::async_trait;
use serde::Deserialize;
use serde_json::{Value, json};

use crate::{
    command::{CommandDescriptor, CommandHandler},
    connection::ConnectionConfig,
    error::ApiError,
    state::AppState,
    workspace::service,
};

const LIST_ID: &str = "connection.list";
const REMOVE_ID: &str = "connection.remove";
const CATEGORY: &str = "connection";

#[derive(Deserialize)]
struct RemoveParams {
    connection_id: String,
}

pub struct ListConnectionsCommand;

#[async_trait]
impl CommandHandler for ListConnectionsCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: LIST_ID.into(),
            title: "List Connections".into(),
            category: CATEGORY.into(),
            summary: "Lists registered connections (no credentials).".into(),
            params_schema: json!({ "type": "object", "properties": {} }),
            result_schema: json!({
                "type": "array",
                "items": {
                    "type": "object",
                    "required": ["connectionId", "displayName", "endpoint", "bucket", "basePrefix"],
                    "properties": {
                        "connectionId": { "type": "string" },
                        "displayName": { "type": "string" },
                        "endpoint": { "type": "string" },
                        "bucket": { "type": "string" },
                        "basePrefix": { "type": "string" }
                    }
                }
            }),
            destructive: false,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, _params: Value) -> Result<Value, ApiError> {
        let connections: Vec<Value> = state
            .connections()
            .list()
            .into_iter()
            .map(|entry| {
                let ConnectionConfig::S3(cfg) = &entry.config;
                json!({
                    "connectionId": entry.id.0,
                    "displayName": cfg.display_name,
                    "endpoint": cfg.endpoint,
                    "bucket": cfg.bucket,
                    "basePrefix": cfg.base_prefix,
                })
            })
            .collect();

        Ok(Value::Array(connections))
    }
}

pub struct RemoveConnectionCommand;

#[async_trait]
impl CommandHandler for RemoveConnectionCommand {
    fn descriptor(&self) -> CommandDescriptor {
        CommandDescriptor {
            id: REMOVE_ID.into(),
            title: "Remove Connection".into(),
            category: CATEGORY.into(),
            summary: "Removes a connection and drops its cached provider and mount.".into(),
            params_schema: json!({
                "type": "object",
                "required": ["connection_id"],
                "properties": {
                    "connection_id": { "type": "string" }
                }
            }),
            result_schema: json!({ "type": "null" }),
            destructive: true,
            context_requirements: vec![],
        }
    }

    async fn invoke(&self, state: &AppState, params: Value) -> Result<Value, ApiError> {
        let params = serde_json::from_value::<RemoveParams>(params).map_err(|err| {
            ApiError::InvalidParams {
                method: REMOVE_ID.into(),
                message: err.to_string(),
            }
        })?;
        service::remove_connection(state, &params.connection_id).await?;
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use serde_json::json;

    use super::*;
    use crate::{
        command::CommandRegistry,
        connection::{ConnectionConfig, Credential, S3ConnectionConfig, S3Credential},
    };

    fn seed_connection(state: &AppState, display_name: &str) -> String {
        state
            .connections()
            .create(
                ConnectionConfig::S3(S3ConnectionConfig {
                    display_name: display_name.into(),
                    endpoint: "http://127.0.0.1:1".into(),
                    region: "us-east-1".into(),
                    bucket: "bucket".into(),
                    base_prefix: "prefix/".into(),
                    path_style: true,
                }),
                Credential::S3(S3Credential {
                    access_key_id: "x".into(),
                    secret_access_key: "x".into(),
                }),
            )
            .0
    }

    #[test]
    fn descriptors_match_command_table() {
        assert_eq!(ListConnectionsCommand.descriptor().id, "connection.list");
        assert!(!ListConnectionsCommand.descriptor().destructive);
        assert_eq!(RemoveConnectionCommand.descriptor().id, "connection.remove");
        assert!(RemoveConnectionCommand.descriptor().destructive);
    }

    #[test]
    fn registry_new_contains_connection_commands() {
        let ids: Vec<String> = CommandRegistry::new()
            .list()
            .into_iter()
            .map(|descriptor| descriptor.id)
            .collect();
        assert!(ids.contains(&"connection.list".to_string()));
        assert!(ids.contains(&"connection.remove".to_string()));
    }

    #[tokio::test]
    async fn list_invoke_empty_state_returns_empty_array() {
        let state = AppState::new(crate::CORE_VERSION);

        let result = ListConnectionsCommand
            .invoke(&state, json!({}))
            .await
            .expect("list succeeds");

        assert_eq!(result, json!([]));
    }

    #[tokio::test]
    async fn list_invoke_returns_camel_case_entry() {
        let state = AppState::new(crate::CORE_VERSION);
        let id = seed_connection(&state, "prod");

        let result = ListConnectionsCommand
            .invoke(&state, json!({}))
            .await
            .expect("list succeeds");

        let array = result.as_array().expect("array result");
        assert_eq!(array.len(), 1);
        assert_eq!(array[0]["connectionId"], json!(id));
        assert_eq!(array[0]["displayName"], json!("prod"));
        assert_eq!(array[0]["basePrefix"], json!("prefix/"));
    }

    #[tokio::test]
    async fn remove_invoke_unknown_id_returns_connection_not_found() {
        let state = AppState::new(crate::CORE_VERSION);

        let err = RemoveConnectionCommand
            .invoke(&state, json!({ "connection_id": "nope" }))
            .await
            .expect_err("unknown id fails");

        assert_eq!(err.code(), "connection_not_found");
    }

    #[tokio::test]
    async fn remove_invoke_missing_field_returns_invalid_params() {
        let state = AppState::new(crate::CORE_VERSION);

        let err = RemoveConnectionCommand
            .invoke(&state, json!({}))
            .await
            .expect_err("missing connection_id fails");

        assert_eq!(err.code(), "invalid_params");
    }

    #[tokio::test]
    async fn remove_invoke_existing_id_returns_null_and_delists() {
        let state = AppState::new(crate::CORE_VERSION);
        let id = seed_connection(&state, "temp");

        let result = RemoveConnectionCommand
            .invoke(&state, json!({ "connection_id": id }))
            .await
            .expect("remove succeeds");

        assert_eq!(result, Value::Null);
        let remaining = ListConnectionsCommand
            .invoke(&state, json!({}))
            .await
            .expect("list after remove");
        assert_eq!(remaining, json!([]));
    }
}
