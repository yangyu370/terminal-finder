use axum::{
    Router,
    routing::{get, post},
};

use crate::state::AppState;

use super::{controllers, events, rpc};

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(controllers::core::health))
        .route("/rpc", post(rpc::handle_rpc))
        .route("/events", get(events::handle_events))
        .with_state(state)
}
