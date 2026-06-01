use axum::{Json, extract::State};
use serde::Serialize;

use crate::state::AppState;

#[derive(Debug, Serialize)]
pub struct PingResponse {
    pub service: &'static str,
    pub version: &'static str,
}

pub async fn health(State(state): State<AppState>) -> Json<PingResponse> {
    Json(ping(&state))
}

pub fn ping(state: &AppState) -> PingResponse {
    PingResponse {
        service: "terminal-finder-core",
        version: state.version,
    }
}
