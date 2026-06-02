use std::time::Instant;

use axum::{
    Json,
    extract::{ConnectInfo, State},
};
use serde::{Deserialize, Serialize};
use serde_json::{Value, to_value};

use crate::{
    api::controllers::{core, workspace},
    error::ApiError,
    state::AppState,
};

const LOG_TARGET: &str = "rpc";

#[derive(Debug, Deserialize)]
pub struct RpcRequest {
    pub method: String,
    #[serde(default)]
    pub params: Value,
}

#[derive(Debug, Serialize)]
pub struct RpcResponse<T>
where
    T: Serialize,
{
    pub ok: bool,
    pub result: T,
}

pub async fn handle_rpc(
    ConnectInfo(remote_addr): ConnectInfo<std::net::SocketAddr>,
    State(state): State<AppState>,
    Json(request): Json<RpcRequest>,
) -> Result<Json<RpcResponse<Value>>, ApiError> {
    let method = request.method;
    let params = request.params;
    let started_at = Instant::now();
    tracing::info!(
        target: LOG_TARGET,
        method = %method,
        ip = %remote_addr.ip(),
        identity = "unauthenticated",
        params = %params,
        "<- POST /rpc"
    );

    let response = dispatch_rpc(&state, &method, params).await;

    match &response {
        Ok(body) => {
            tracing::info!(
                target: LOG_TARGET,
                method = %method,
                status = 200_u16,
                elapsed_ms = started_at.elapsed().as_millis(),
                summary = %response_summary(&method, body),
                "-> POST /rpc"
            );
        }
        Err(error) => {
            tracing::warn!(
                target: LOG_TARGET,
                method = %method,
                status = error.status_code().as_u16(),
                elapsed_ms = started_at.elapsed().as_millis(),
                error = error.code(),
                message = %error.message(),
                "-> POST /rpc"
            );
        }
    }

    response.map(|result| Json(RpcResponse { ok: true, result }))
}

async fn dispatch_rpc(state: &AppState, method: &str, params: Value) -> Result<Value, ApiError> {
    match method {
        "core.ping" => {
            let _params = params;
            Ok(to_value(core::ping(state)).expect("core.ping response serializes"))
        }
        "workspace.listDirectory" => serde_json::from_value(params)
            .map_err(|error| ApiError::InvalidParams {
                method: method.to_string(),
                message: error.to_string(),
            })
            .map(workspace::list_directory)?
            .await
            .map(|result| to_value(result).expect("workspace.listDirectory response serializes")),
        _ => Err(ApiError::UnknownMethod(method.to_string())),
    }
}

fn response_summary(method: &str, result: &Value) -> String {
    match method {
        "core.ping" => service_summary(result),
        "workspace.listDirectory" => directory_listing_summary(result),
        _ => "ok=true".to_string(),
    }
}

fn service_summary(result: &Value) -> String {
    let service = result
        .get("service")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let version = result
        .get("version")
        .and_then(Value::as_str)
        .unwrap_or("unknown");

    format!("service={service:?} version={version:?}")
}

fn directory_listing_summary(result: &Value) -> String {
    let path = result
        .get("path")
        .and_then(Value::as_str)
        .unwrap_or("unknown");
    let entries = result
        .get("entries")
        .and_then(Value::as_array)
        .map(Vec::as_slice)
        .unwrap_or(&[]);
    let directory_count = entries
        .iter()
        .filter(|entry| {
            entry
                .get("isDirectory")
                .and_then(Value::as_bool)
                .unwrap_or(false)
        })
        .count();
    let file_count = entries.len().saturating_sub(directory_count);

    format!(
        "path={path:?} entries={} dirs={} files={}",
        entries.len(),
        directory_count,
        file_count
    )
}
