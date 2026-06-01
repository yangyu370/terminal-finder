use axum::{Json, extract::State};
use serde::{Deserialize, Serialize};
use serde_json::Value;

use crate::{
    api::controllers::core::{self, PingResponse},
    error::ApiError,
    state::AppState,
};

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
    State(state): State<AppState>,
    Json(request): Json<RpcRequest>,
) -> Result<Json<RpcResponse<PingResponse>>, ApiError> {
    match request.method.as_str() {
        "core.ping" => {
            let _params = request.params;
            Ok(Json(RpcResponse {
                ok: true,
                result: core::ping(&state),
            }))
        }
        _ => Err(ApiError::UnknownMethod(request.method)),
    }
}
