use std::net::SocketAddr;

use tokio::net::TcpListener;
use tracing::info;

mod api;
mod error;
mod state;

use state::AppState;

const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "terminal_finder_core=info,core=info,tower_http=info".into()),
        )
        .init();

    let state = AppState::new(CORE_VERSION);
    let app = api::routes::router(state);
    let addr = SocketAddr::from(([127, 0, 0, 1], 3587));
    let listener = TcpListener::bind(addr).await?;
    info!("terminal finder core listening on http://{addr}");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn shutdown_signal() {
    let _ = tokio::signal::ctrl_c().await;
}
