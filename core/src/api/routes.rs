use axum::{
    Router,
    routing::{get, post},
};

use crate::state::AppState;

use super::{controllers, rpc};

pub fn router(state: AppState) -> Router {
    Router::new()
        .route("/health", get(controllers::core::health))
        .route("/rpc", post(rpc::handle_rpc))
        .with_state(state)
}
