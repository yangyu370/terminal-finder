use std::{collections::HashSet, net::SocketAddr, path::PathBuf};

use axum::{
    extract::{
        ConnectInfo, State,
        ws::{Message, WebSocket, WebSocketUpgrade},
    },
    response::IntoResponse,
};
use base64::{Engine as _, engine::general_purpose};
use futures_util::{SinkExt, StreamExt, stream::SplitSink};
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use tokio::sync::mpsc;
use uuid::Uuid;

use crate::state::AppState;

use super::session::TerminalEvent;

const LOG_TARGET: &str = "terminal";
const TERMINAL_EVENT_BUFFER: usize = 256;

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct IncomingEnvelope {
    #[serde(rename = "type")]
    message_type: String,
    session_id: Option<Uuid>,
    id: Option<String>,
    #[serde(default)]
    data: Value,
}

#[derive(Debug, Deserialize)]
struct CreateData {
    cwd: Option<PathBuf>,
    cols: u16,
    rows: u16,
    #[allow(dead_code)]
    shell: Option<String>,
}

#[derive(Debug, Deserialize)]
struct InputData {
    bytes: String,
}

#[derive(Debug, Deserialize)]
struct ResizeData {
    cols: u16,
    rows: u16,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct OutgoingEnvelope<T>
where
    T: Serialize,
{
    #[serde(rename = "type")]
    message_type: &'static str,
    #[serde(skip_serializing_if = "Option::is_none")]
    session_id: Option<Uuid>,
    #[serde(skip_serializing_if = "Option::is_none")]
    id: Option<String>,
    data: T,
}

pub async fn handle_terminal(
    ConnectInfo(remote_addr): ConnectInfo<SocketAddr>,
    State(state): State<AppState>,
    upgrade: WebSocketUpgrade,
) -> impl IntoResponse {
    tracing::info!(
        target: LOG_TARGET,
        ip = %remote_addr.ip(),
        "terminal websocket upgrade requested"
    );

    upgrade.on_upgrade(move |socket| handle_socket(socket, state, remote_addr))
}

async fn handle_socket(socket: WebSocket, state: AppState, remote_addr: SocketAddr) {
    tracing::info!(
        target: LOG_TARGET,
        ip = %remote_addr.ip(),
        "terminal websocket connected"
    );
    let (mut sender, mut receiver) = socket.split();
    let (event_tx, mut event_rx) = mpsc::channel(TERMINAL_EVENT_BUFFER);
    let mut owned_sessions = HashSet::new();

    let disconnect_reason = loop {
        tokio::select! {
            received = receiver.next() => match received {
                Some(Ok(Message::Text(text))) => {
                    match serde_json::from_str::<IncomingEnvelope>(&text) {
                        Ok(envelope) => {
                            if let Err(reason) = handle_incoming(
                                envelope,
                                &state,
                                &event_tx,
                                &mut sender,
                                &mut owned_sessions,
                            ).await {
                                break reason;
                            }
                        }
                        Err(error) => {
                            if send_error(
                                &mut sender,
                                None,
                                None,
                                "invalid_message",
                                &error.to_string(),
                            ).await.is_err() {
                                break "send_failed";
                            }
                        }
                    }
                }
                Some(Ok(Message::Close(close_frame))) => {
                    if let Err(error) = sender.send(Message::Close(close_frame)).await {
                        tracing::debug!(
                            target: LOG_TARGET,
                            message = %error,
                            "terminal websocket close acknowledgement failed"
                        );
                    }
                    break "client_close";
                }
                Some(Ok(Message::Binary(_))) => {
                    if send_error(
                        &mut sender,
                        None,
                        None,
                        "invalid_message",
                        "binary terminal messages are not supported",
                    ).await.is_err() {
                        break "send_failed";
                    }
                }
                Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => {}
                Some(Err(error)) => {
                    tracing::warn!(
                        target: LOG_TARGET,
                        error = "read_failed",
                        "terminal websocket read failed"
                    );
                    tracing::debug!(
                        target: LOG_TARGET,
                        message = %error,
                        "terminal websocket read failed detail"
                    );
                    break "read_failed";
                }
                None => break "client_eof",
            },
            event = event_rx.recv() => match event {
                Some(event) => {
                    let session_id = event.session_id();
                    let is_exit = matches!(event, TerminalEvent::Exit { .. });
                    if send_terminal_event(&mut sender, event).await.is_err() {
                        break "send_failed";
                    }
                    if is_exit {
                        state.terminals().remove(session_id);
                        owned_sessions.remove(&session_id);
                    }
                }
                None => break "terminal_event_channel_closed",
            },
        }
    };

    state.terminals().close_many(owned_sessions.iter().copied());
    tracing::info!(
        target: LOG_TARGET,
        reason = disconnect_reason,
        "terminal websocket disconnected"
    );
}

async fn handle_incoming(
    envelope: IncomingEnvelope,
    state: &AppState,
    event_tx: &mpsc::Sender<TerminalEvent>,
    sender: &mut SplitSink<WebSocket, Message>,
    owned_sessions: &mut HashSet<Uuid>,
) -> Result<(), &'static str> {
    match envelope.message_type.as_str() {
        "terminal.create" => {
            let data = match serde_json::from_value::<CreateData>(envelope.data) {
                Ok(data) => data,
                Err(error) => {
                    if send_error(
                        sender,
                        None,
                        envelope.id,
                        "invalid_message",
                        &error.to_string(),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let cwd = data
                .cwd
                .unwrap_or_else(|| state.workspace().state().current_directory);

            match state
                .terminals()
                .create_session(cwd, data.cols, data.rows, event_tx.clone())
            {
                Ok(session_id) => {
                    owned_sessions.insert(session_id);
                    if send_envelope(
                        sender,
                        "terminal.created",
                        Some(session_id),
                        envelope.id,
                        json!({ "cols": data.cols, "rows": data.rows }),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
                Err(error) => {
                    if send_error(
                        sender,
                        None,
                        envelope.id,
                        "create_failed",
                        &error.to_string(),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
            }
        }
        "terminal.input" => {
            let Some(session_id) = envelope.session_id else {
                if send_error(
                    sender,
                    None,
                    envelope.id,
                    "invalid_message",
                    "missing sessionId",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            };
            let data = match serde_json::from_value::<InputData>(envelope.data) {
                Ok(data) => data,
                Err(error) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "invalid_message",
                        &error.to_string(),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let bytes = match general_purpose::STANDARD.decode(data.bytes) {
                Ok(bytes) => bytes,
                Err(error) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "invalid_message",
                        &error.to_string(),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            match state.terminals().session(session_id) {
                Some(session) if session.input(bytes) => {}
                _ => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "unknown_session",
                        "sessionId does not match a live session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
            }
        }
        "terminal.resize" => {
            let Some(session_id) = envelope.session_id else {
                if send_error(
                    sender,
                    None,
                    envelope.id,
                    "invalid_message",
                    "missing sessionId",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            };
            let data = match serde_json::from_value::<ResizeData>(envelope.data) {
                Ok(data) => data,
                Err(error) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "invalid_message",
                        &error.to_string(),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            match state.terminals().session(session_id) {
                Some(session) if session.resize(data.cols, data.rows) => {
                    if send_envelope(
                        sender,
                        "terminal.resized",
                        Some(session_id),
                        envelope.id,
                        json!({ "cols": data.cols, "rows": data.rows }),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
                _ => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "unknown_session",
                        "sessionId does not match a live session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
            }
        }
        "terminal.close" => {
            let Some(session_id) = envelope.session_id else {
                if send_error(
                    sender,
                    None,
                    envelope.id,
                    "invalid_message",
                    "missing sessionId",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            };
            if state.terminals().close(session_id) {
                if send_envelope(
                    sender,
                    "terminal.closed",
                    Some(session_id),
                    envelope.id,
                    json!({}),
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
            } else if send_error(
                sender,
                Some(session_id),
                envelope.id,
                "unknown_session",
                "sessionId does not match a live session",
            )
            .await
            .is_err()
            {
                return Err("send_failed");
            }
            owned_sessions.remove(&session_id);
        }
        _ => {
            if send_error(
                sender,
                envelope.session_id,
                envelope.id,
                "invalid_message",
                "unknown terminal message type",
            )
            .await
            .is_err()
            {
                return Err("send_failed");
            }
        }
    }

    Ok(())
}

async fn send_terminal_event(
    sender: &mut SplitSink<WebSocket, Message>,
    event: TerminalEvent,
) -> Result<(), axum::Error> {
    match event {
        TerminalEvent::Output { session_id, bytes } => {
            send_envelope(
                sender,
                "terminal.output",
                Some(session_id),
                None,
                json!({ "bytes": general_purpose::STANDARD.encode(bytes) }),
            )
            .await
        }
        TerminalEvent::Exit {
            session_id,
            code,
            signal,
        } => {
            send_envelope(
                sender,
                "terminal.exit",
                Some(session_id),
                None,
                json!({ "code": code, "signal": signal }),
            )
            .await
        }
        TerminalEvent::Error {
            session_id,
            code,
            message,
        } => send_error(sender, Some(session_id), None, code, &message).await,
    }
}

async fn send_error(
    sender: &mut SplitSink<WebSocket, Message>,
    session_id: Option<Uuid>,
    id: Option<String>,
    code: &'static str,
    message: &str,
) -> Result<(), axum::Error> {
    send_envelope(
        sender,
        "terminal.error",
        session_id,
        id,
        json!({ "code": code, "message": message }),
    )
    .await
}

async fn send_envelope<T>(
    sender: &mut SplitSink<WebSocket, Message>,
    message_type: &'static str,
    session_id: Option<Uuid>,
    id: Option<String>,
    data: T,
) -> Result<(), axum::Error>
where
    T: Serialize,
{
    let message = serde_json::to_string(&OutgoingEnvelope {
        message_type,
        session_id,
        id,
        data,
    })
    .expect("terminal websocket envelope serializes");
    sender.send(Message::Text(message)).await
}

impl TerminalEvent {
    fn session_id(&self) -> Uuid {
        match self {
            TerminalEvent::Output { session_id, .. }
            | TerminalEvent::Exit { session_id, .. }
            | TerminalEvent::Error { session_id, .. } => *session_id,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::net::SocketAddr;

    use futures_util::{SinkExt, StreamExt};
    use serde_json::Value;
    use tokio::net::TcpListener;
    use tokio_tungstenite::{connect_async, tungstenite::Message as TungsteniteMessage};

    use crate::{api::routes, state::AppState};

    #[test]
    fn terminal_output_event_uses_base64_bytes() {
        let encoded = general_purpose::STANDARD.encode([0x1b, b'[', b'A']);

        assert_eq!(encoded, "G1tB");
    }

    #[test]
    fn incoming_create_accepts_protocol_shape() {
        let envelope: IncomingEnvelope = serde_json::from_value(json!({
            "type": "terminal.create",
            "id": "req-1",
            "data": {
                "cwd": "/tmp",
                "cols": 80,
                "rows": 24,
                "shell": null
            }
        }))
        .expect("create envelope decodes");

        assert_eq!(envelope.message_type, "terminal.create");
        assert_eq!(envelope.id.as_deref(), Some("req-1"));
        let data: CreateData = serde_json::from_value(envelope.data).expect("create data decodes");
        assert_eq!(data.cols, 80);
        assert_eq!(data.rows, 24);
        assert_eq!(data.cwd, Some(PathBuf::from("/tmp")));
    }

    #[tokio::test]
    async fn terminal_route_rejects_unknown_message_type() {
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

        let (mut socket, _) = connect_async(format!("ws://{addr}/terminal"))
            .await
            .expect("connects to terminal websocket");
        socket
            .send(TungsteniteMessage::Text(
                json!({ "type": "terminal.unknown", "data": {} }).to_string(),
            ))
            .await
            .expect("sends unknown terminal message");

        let frame = socket
            .next()
            .await
            .expect("receives terminal error frame")
            .expect("terminal error frame is ok");
        let message: Value =
            serde_json::from_str(frame.to_text().expect("terminal error frame is text"))
                .expect("terminal error frame decodes");

        assert_eq!(message["type"], "terminal.error");
        assert_eq!(message["data"]["code"], "invalid_message");
        assert_eq!(message["data"]["message"], "unknown terminal message type");

        server.abort();
    }

    #[tokio::test]
    async fn terminal_route_creates_and_closes_zsh_session() {
        if !PathBuf::from(DEFAULT_TEST_SHELL).exists() {
            return;
        }

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

        let (mut socket, _) = connect_async(format!("ws://{addr}/terminal"))
            .await
            .expect("connects to terminal websocket");
        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.create",
                    "id": "req-1",
                    "data": {
                        "cwd": "/tmp",
                        "cols": 80,
                        "rows": 24,
                        "shell": null
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.create");

        let created = next_terminal_message(&mut socket)
            .await
            .expect("receives terminal.created");
        assert_eq!(created["type"], "terminal.created");
        assert_eq!(created["id"], "req-1");
        let session_id = created["sessionId"]
            .as_str()
            .expect("created message includes sessionId")
            .to_string();

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.resize",
                    "sessionId": session_id,
                    "id": "req-2",
                    "data": {
                        "cols": 100,
                        "rows": 30
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.resize");

        let resized = next_terminal_message_of_type(&mut socket, "terminal.resized")
            .await
            .expect("receives terminal.resized");
        assert_eq!(resized["type"], "terminal.resized");
        assert_eq!(resized["id"], "req-2");
        assert_eq!(resized["sessionId"], session_id);
        assert_eq!(resized["data"]["cols"], 100);
        assert_eq!(resized["data"]["rows"], 30);

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.close",
                    "sessionId": session_id,
                    "id": "req-3",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.close");

        let closed = next_terminal_message_of_type(&mut socket, "terminal.closed")
            .await
            .expect("receives terminal.closed");
        assert_eq!(closed["type"], "terminal.closed");
        assert_eq!(closed["id"], "req-3");
        assert_eq!(closed["sessionId"], session_id);

        let exit = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.exit"),
        )
        .await
        .expect("receives terminal.exit after close")
        .expect("terminal.exit frame exists");

        assert_eq!(exit["sessionId"], session_id);

        server.abort();
    }

    async fn next_terminal_message(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
    ) -> Option<Value> {
        let frame = socket.next().await?.ok()?;
        serde_json::from_str(frame.to_text().ok()?).ok()
    }

    async fn next_terminal_message_of_type(
        socket: &mut tokio_tungstenite::WebSocketStream<
            tokio_tungstenite::MaybeTlsStream<tokio::net::TcpStream>,
        >,
        message_type: &str,
    ) -> Option<Value> {
        loop {
            let message = next_terminal_message(socket).await?;
            if message["type"] == message_type {
                return Some(message);
            }
        }
    }

    const DEFAULT_TEST_SHELL: &str = "/bin/zsh";
}
