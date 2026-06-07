use axum::{
    Router,
    routing::{get, post},
};

use crate::state::AppState;

use super::{controllers, events, rpc, terminal};

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(controllers::core::health))
        .route("/rpc", post(rpc::handle_rpc))
        .route("/events", get(events::handle_events))
        .route("/terminal", get(terminal::handle_terminal))
        .with_state(state)
}
