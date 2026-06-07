use std::net::SocketAddr;

use tokio::io::{AsyncReadExt, stdin};
use tokio::net::TcpListener;
use tokio::task::JoinHandle;
use tracing::info;

mod api;
mod clock;
mod error;
mod state;
mod terminal;
mod workspace;

use state::AppState;

const CORE_VERSION: &str = env!("CARGO_PKG_VERSION");

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    tracing_subscriber::fmt()
        .with_timer(clock::KualaLumpurTimer)
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| {
                "terminal_finder_core=info,core=info,rpc=info,workspace=info,events=info,terminal=info,tower_http=info".into()
            }),
        )
        .init();

    let state = AppState::new(CORE_VERSION);
    let app = api::routes::router(state);
    let addr = SocketAddr::from(([127, 0, 0, 1], 3587));
    let listener = TcpListener::bind(addr).await?;
    info!(target: "core", %addr, "Terminal Finder core listening");
    let stdin_eof_task = tokio::spawn(wait_for_stdin_eof());

    axum::serve(
        listener,
        app.into_make_service_with_connect_info::<SocketAddr>(),
    )
    .with_graceful_shutdown(shutdown_signal(stdin_eof_task))
    .await?;

    Ok(())
}

async fn shutdown_signal(stdin_eof_task: JoinHandle<()>) {
    let reason = tokio::select! {
        _ = tokio::signal::ctrl_c() => "ctrl_c",
        _ = stdin_eof_task => "stdin_eof",
    };

    info!(target: "core", reason, "shutdown signal received");
}

async fn wait_for_stdin_eof() {
    let mut input = stdin();
    let mut buffer = [0_u8; 1];
    loop {
        match input.read(&mut buffer).await {
            Ok(0) | Err(_) => return,
            Ok(_) => {}
        }
    }
}
