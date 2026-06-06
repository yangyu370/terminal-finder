use std::{
    net::SocketAddr,
    time::{Duration, Instant},
};

use axum::{
    extract::{
        ConnectInfo, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
};
use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use serde::Serialize;
use serde_json::json;
use tokio::{
    sync::broadcast,
    time::{MissedTickBehavior, interval},
};

use crate::state::AppState;

const LOG_TARGET: &str = "events";
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(10);

#[derive(Debug, Serialize)]
struct EventEnvelope<T>
where
    T: Serialize,
{
    #[serde(rename = "type")]
    event_type: &'static str,
    data: T,
}

pub async fn handle_events(
    ConnectInfo(remote_addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    let connection_id = state.next_event_connection_id();
    tracing::info!(
        target: LOG_TARGET,
        connection_id,
        ip = %remote_addr.ip(),
        "websocket upgrade requested"
    );

    upgrade.on_upgrade(move |socket| handle_socket(socket, state, connection_id, remote_addr))
}

async fn handle_socket(
    socket: WebSocket,
    state: AppState,
    connection_id: u64,
    remote_addr: SocketAddr,
) {
    let started_at = Instant::now();
    let mut heartbeat_count: u64 = 0;
    let mut broadcast_count: u64 = 0;

    tracing::info!(
        target: LOG_TARGET,
        connection_id,
        ip = %remote_addr.ip(),
        "websocket connected"
    );
    let (mut sender, mut receiver_socket) = socket.split();

    if send_event(
        &mut sender,
        connection_id,
        "backend.ready",
        ready_message(state.version),
    )
    .await
    .is_err()
    {
        tracing::warn!(
            target: LOG_TARGET,
            connection_id,
            event_type = "backend.ready",
            "websocket closed before backend.ready"
        );
        return;
    }

    let mut receiver = state.events().subscribe();
    let mut heartbeat = interval(HEARTBEAT_INTERVAL);
    heartbeat.set_missed_tick_behavior(MissedTickBehavior::Delay);
    heartbeat.tick().await;
    let disconnect_reason = loop {
        tokio::select! {
            received = receiver_socket.next() => match received {
                Some(Ok(Message::Close(close_frame))) => {
                    if let Err(error) = sender.send(Message::Close(close_frame)).await {
                        tracing::debug!(
                            target: LOG_TARGET,
                            connection_id,
                            message = %error,
                            "websocket close acknowledgement failed"
                        );
                    }
                    if let Err(error) = sender.close().await {
                        tracing::debug!(
                            target: LOG_TARGET,
                            connection_id,
                            message = %error,
                            "websocket sender close failed"
                        );
                    }
                    break "client_close";
                }
                Some(Ok(Message::Text(_))) => {
                    tracing::debug!(
                        target: LOG_TARGET,
                        connection_id,
                        frame_type = "text",
                        "websocket inbound frame ignored"
                    );
                }
                Some(Ok(Message::Binary(_))) => {
                    tracing::debug!(
                        target: LOG_TARGET,
                        connection_id,
                        frame_type = "binary",
                        "websocket inbound frame ignored"
                    );
                }
                Some(Ok(Message::Ping(_))) => {
                    tracing::debug!(
                        target: LOG_TARGET,
                        connection_id,
                        frame_type = "ping",
                        "websocket inbound control frame received"
                    );
                }
                Some(Ok(Message::Pong(_))) => {
                    tracing::debug!(
                        target: LOG_TARGET,
                        connection_id,
                        frame_type = "pong",
                        "websocket inbound control frame received"
                    );
                }
                Some(Err(error)) => {
                    tracing::warn!(
                        target: LOG_TARGET,
                        connection_id,
                        error = "read_failed",
                        "websocket read failed"
                    );
                    tracing::debug!(
                        target: LOG_TARGET,
                        connection_id,
                        message = %error,
                        "websocket read failed detail"
                    );
                    break "read_failed";
                }
                None => {
                    break "client_eof";
                }
            },
            _ = heartbeat.tick() => {
                heartbeat_count += 1;
                let message = heartbeat_message();
                let event_type = event_type_from_message(&message);
                if send_event(
                    &mut sender,
                    connection_id,
                    event_type.as_deref().unwrap_or("unknown"),
                    message,
                )
                .await
                .is_err()
                {
                    break "send_failed";
                }
            },
            received = receiver.recv() => match received {
                Ok(message) => {
                    broadcast_count += 1;
                    let event_type = event_type_from_message(&message);
                    if send_event(
                        &mut sender,
                        connection_id,
                        event_type.as_deref().unwrap_or("unknown"),
                        message,
                    )
                    .await
                    .is_err()
                    {
                        break "send_failed";
                    }
                },
                Err(broadcast::error::RecvError::Lagged(skipped)) => {
                    tracing::warn!(
                        target: LOG_TARGET,
                        connection_id,
                        skipped,
                        "websocket event receiver lagged"
                    );
                    continue;
                }
                Err(broadcast::error::RecvError::Closed) => {
                    break "server_event_channel_closed";
                }
            },
        };
    };

    tracing::info!(
        target: LOG_TARGET,
        connection_id,
        reason = disconnect_reason,
        elapsed_ms = started_at.elapsed().as_millis(),
        heartbeat_count,
        broadcast_count,
        "websocket disconnected"
    );
}

async fn send_text(
    sender: &mut SplitSink<WebSocket, Message>,
    message: String,
) -> Result<(), axum::Error> {
    sender.send(Message::Text(message)).await
}

async fn send_event(
    sender: &mut SplitSink<WebSocket, Message>,
    connection_id: u64,
    event_type: &str,
    message: String,
) -> Result<(), axum::Error> {
    let result = send_text(sender, message).await;

    match &result {
        Ok(()) if event_type != "heartbeat" => {
            tracing::info!(
                target: LOG_TARGET,
                connection_id,
                event_type,
                "websocket event sent"
            );
        }
        Ok(()) => {}
        Err(error) => {
            tracing::warn!(
                target: LOG_TARGET,
                connection_id,
                event_type,
                error = "send_failed",
                "websocket event send failed"
            );
            tracing::debug!(
                target: LOG_TARGET,
                connection_id,
                event_type,
                message = %error,
                "websocket event send failed detail"
            );
        }
    }

    result
}

fn ready_message(version: &'static str) -> String {
    envelope(
        "backend.ready",
        json!({
            "service": "terminal-finder-core",
            "version": version,
        }),
    )
}

fn heartbeat_message() -> String {
    envelope("heartbeat", json!({}))
}

fn envelope<T>(event_type: &'static str, data: T) -> String
where
    T: Serialize,
{
    serde_json::to_string(&EventEnvelope { event_type, data })
        .expect("websocket event envelope serializes")
}

fn event_type_from_message(message: &str) -> Option<String> {
    serde_json::from_str::<serde_json::Value>(message)
        .ok()
        .and_then(|value| {
            value
                .get("type")
                .and_then(|event_type| event_type.as_str())
                .map(str::to_string)
        })
}

#[cfg(test)]
mod tests {
    use std::{net::SocketAddr, time::Duration};

    use futures_util::StreamExt;
    use serde_json::Value;
    use tokio::net::TcpListener;
    use tokio_tungstenite::{connect_async, tungstenite::Message as TungsteniteMessage};

    use super::{heartbeat_message, ready_message};
    use crate::{api::routes, state::AppState};

    #[test]
    fn ready_message_uses_protocol_envelope() {
        let message: Value =
            serde_json::from_str(&ready_message("0.1.0")).expect("ready message decodes");

        assert_eq!(message["type"], "backend.ready");
        assert_eq!(message["data"]["service"], "terminal-finder-core");
        assert_eq!(message["data"]["version"], "0.1.0");
        assert!(message.get("ok").is_none());
    }

    #[test]
    fn heartbeat_message_uses_empty_data() {
        let message: Value =
            serde_json::from_str(&heartbeat_message()).expect("heartbeat message decodes");

        assert_eq!(message["type"], "heartbeat");
        assert_eq!(message["data"], serde_json::json!({}));
    }

    #[tokio::test]
    async fn events_route_sends_ready_after_upgrade() {
        let state = AppState::new("test-version");
        let app = routes::router(state);
        let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
            .await
            .expect("binds test listener");
        let addr = listener.local_addr().expect("listener has local addr");

        let server = tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .expect("serves test app");
        });

        let (mut socket, _) = connect_async(format!("ws://{addr}/events"))
            .await
            .expect("connects to events websocket");
        let frame = socket
            .next()
            .await
            .expect("receives first websocket frame")
            .expect("first websocket frame is ok");
        let message: Value =
            serde_json::from_str(frame.to_text().expect("first websocket frame is text"))
                .expect("first websocket frame decodes");

        assert_eq!(message["type"], "backend.ready");
        assert_eq!(message["data"]["service"], "terminal-finder-core");
        assert_eq!(message["data"]["version"], "test-version");

        server.abort();
    }

    #[tokio::test]
    async fn events_route_replies_to_client_close_without_waiting_for_heartbeat() {
        let state = AppState::new("test-version");
        let app = routes::router(state);
        let listener = TcpListener::bind(SocketAddr::from(([127, 0, 0, 1], 0)))
            .await
            .expect("binds test listener");
        let addr = listener.local_addr().expect("listener has local addr");

        let server = tokio::spawn(async move {
            axum::serve(
                listener,
                app.into_make_service_with_connect_info::<SocketAddr>(),
            )
            .await
            .expect("serves test app");
        });

        let (mut socket, _) = connect_async(format!("ws://{addr}/events"))
            .await
            .expect("connects to events websocket");
        socket
            .next()
            .await
            .expect("receives first websocket frame")
            .expect("first websocket frame is ok");
        socket
            .close(None)
            .await
            .expect("client close frame is sent");

        let close_handshake = tokio::time::timeout(Duration::from_secs(1), async {
            while let Some(frame) = socket.next().await {
                match frame.expect("close handshake frame is ok") {
                    TungsteniteMessage::Close(_) => return,
                    _ => continue,
                }
            }
        })
        .await;

        assert!(
            close_handshake.is_ok(),
            "server should read the client close frame and complete close promptly"
        );

        server.abort();
    }
}
