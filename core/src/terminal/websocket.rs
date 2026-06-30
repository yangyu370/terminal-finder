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

use super::{
    binding::{WorkspaceTerminalKind, WorkspaceTerminalLaunchSnapshot},
    session::{TerminalEvent, TerminalLaunch},
    shell_integration::ShellIntegration,
};

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
struct CreateWorkspaceData {
    cols: u16,
    rows: u16,
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

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct WorkingDirectoryData {
    directory_url: String,
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct ChangeDirectoryData {
    target_directory: String,
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
                        state.workspace_terminal_bindings().remove(session_id);
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
        "terminal.createWorkspace" => {
            let data = match serde_json::from_value::<CreateWorkspaceData>(envelope.data) {
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
            let workspace = state.workspace().state();
            let (session_id, kind) = if workspace.scheme == "local" {
                let integration = match ShellIntegration::create() {
                    Ok(integration) => integration,
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
                        return Ok(());
                    }
                };
                let integration_for_binding = integration.clone();
                let launch = TerminalLaunch::LocalShell {
                    cwd: workspace.current_directory.clone(),
                    integration: Some(integration),
                };
                match state.terminals().create_session_with_launch(
                    launch,
                    data.cols,
                    data.rows,
                    event_tx.clone(),
                ) {
                    Ok(session_id) => {
                        state
                            .workspace_terminal_bindings()
                            .attach_shell_integration(session_id, integration_for_binding);
                        (session_id, WorkspaceTerminalKind::Local)
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
                        return Ok(());
                    }
                }
            } else if let Some(connection_id) = workspace.connection_id.clone() {
                match crate::terminal::connection::create_connection_terminal(
                    state,
                    connection_id,
                    data.cols,
                    data.rows,
                    event_tx.clone(),
                )
                .await
                {
                    Ok(session_id) => (session_id, WorkspaceTerminalKind::Connection),
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
                        return Ok(());
                    }
                }
            } else {
                if send_error(
                    sender,
                    None,
                    envelope.id,
                    "unsupported_workspace_terminal",
                    "workspace terminal creation for this workspace scheme is not implemented",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            };

            let snapshot = WorkspaceTerminalLaunchSnapshot {
                workspace_root: workspace.workspace_root.to_string_lossy().into_owned(),
                current_directory: workspace.current_directory.to_string_lossy().into_owned(),
                scheme: workspace.scheme,
                connection_id: workspace.connection_id,
            };
            let binding = state
                .workspace_terminal_bindings()
                .create(session_id, kind, snapshot);
            owned_sessions.insert(session_id);
            if send_envelope(
                sender,
                "terminal.created",
                Some(session_id),
                envelope.id,
                json!({
                    "cols": data.cols,
                    "rows": data.rows,
                    "binding": workspace_terminal_binding_json(binding),
                }),
            )
            .await
            .is_err()
            {
                return Err("send_failed");
            }
        }
        "terminal.updateWorkingDirectory" => {
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
            let data = match serde_json::from_value::<WorkingDirectoryData>(envelope.data) {
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
            let binding = match state.workspace_terminal_bindings().get(session_id) {
                Some(binding) => binding,
                None => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "unknown_session",
                        "sessionId does not match a live workspace terminal session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let decoded = match decode_file_url(&data.directory_url) {
                Ok(decoded) => decoded,
                Err(CwdDecodeError::UnsupportedHost) => {
                    if send_envelope(
                        sender,
                        "terminal.workingDirectoryUpdated",
                        Some(session_id),
                        envelope.id,
                        json!({
                            "binding": workspace_terminal_binding_json(binding),
                            "reportedDirectory": data.directory_url,
                            "openable": false,
                            "matchesCurrent": false,
                            "reason": "unsupported_host",
                        }),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
                Err(CwdDecodeError::Invalid(message)) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "invalid_message",
                        &message,
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let binding = state
                .workspace_terminal_bindings()
                .record_terminal_working_directory(session_id, decoded.clone())
                .unwrap_or(binding);
            match terminal_working_directory_update_json(state, binding, decoded).await {
                Ok(data) => {
                    if send_envelope(
                        sender,
                        "terminal.workingDirectoryUpdated",
                        Some(session_id),
                        envelope.id,
                        data,
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
                Err(message) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "background_task_failed",
                        &message,
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
            }
        }
        "terminal.compareWorkingDirectory" => {
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
            let binding = match state.workspace_terminal_bindings().get(session_id) {
                Some(binding) => binding,
                None => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "unknown_session",
                        "sessionId does not match a live workspace terminal session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let Some(directory) = binding.latest_terminal_working_directory.clone() else {
                if send_envelope(
                    sender,
                    "terminal.workingDirectoryUpdated",
                    Some(session_id),
                    envelope.id,
                    json!({
                        "binding": workspace_terminal_binding_json(binding),
                        "reportedDirectory": "",
                        "openable": false,
                        "matchesCurrent": false,
                        "reason": "cwd_unknown",
                    }),
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            };
            match terminal_working_directory_update_json(state, binding, directory).await {
                Ok(data) => {
                    if send_envelope(
                        sender,
                        "terminal.workingDirectoryUpdated",
                        Some(session_id),
                        envelope.id,
                        data,
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
                Err(message) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "background_task_failed",
                        &message,
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                }
            }
        }
        "terminal.changeDirectory" => {
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
            let data = match serde_json::from_value::<ChangeDirectoryData>(envelope.data) {
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
            if data.target_directory.chars().any(|ch| ch.is_control()) {
                if send_error(
                    sender,
                    Some(session_id),
                    envelope.id,
                    "invalid_message",
                    "terminal target directory contains unsafe control characters",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            }
            let binding = match state.workspace_terminal_bindings().get(session_id) {
                Some(binding) => binding,
                None => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "unknown_session",
                        "sessionId does not match a live workspace terminal session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            if !matches!(binding.kind, WorkspaceTerminalKind::Local) {
                if send_error(
                    sender,
                    Some(session_id),
                    envelope.id,
                    "unsupported_terminal",
                    "connection-backed terminals do not support directory changes",
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            }
            let integration = match state
                .workspace_terminal_bindings()
                .shell_integration(session_id)
            {
                Some(integration) => integration,
                None => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "terminal_control_unavailable",
                        "terminal shell integration is not available for this session",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            let target_for_task = data.target_directory.clone();
            let canonical_target = match tokio::task::spawn_blocking(move || {
                let path = PathBuf::from(target_for_task);
                let metadata = std::fs::metadata(&path).map_err(|_| "not_openable".to_string())?;
                if !metadata.is_dir() {
                    return Err("not_directory".to_string());
                }
                path.canonicalize().map_err(|_| "not_openable".to_string())
            })
            .await
            {
                Ok(Ok(path)) => path.to_string_lossy().into_owned(),
                Ok(Err(reason)) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        match reason.as_str() {
                            "not_directory" => "not_directory",
                            _ => "not_openable",
                        },
                        "terminal target directory is not openable",
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
                Err(error) => {
                    if send_error(
                        sender,
                        Some(session_id),
                        envelope.id,
                        "background_task_failed",
                        &format!("terminal directory change validation task failed: {error}"),
                    )
                    .await
                    .is_err()
                    {
                        return Err("send_failed");
                    }
                    return Ok(());
                }
            };
            if let Err(error) = integration.write_cd_request(&canonical_target) {
                if send_error(
                    sender,
                    Some(session_id),
                    envelope.id,
                    "terminal_control_failed",
                    &error.to_string(),
                )
                .await
                .is_err()
                {
                    return Err("send_failed");
                }
                return Ok(());
            }
            let binding = state
                .workspace_terminal_bindings()
                .record_pending_target(session_id, canonical_target.clone())
                .unwrap_or(binding);
            if send_envelope(
                sender,
                "terminal.directoryChangeQueued",
                Some(session_id),
                envelope.id,
                json!({
                    "binding": workspace_terminal_binding_json(binding),
                    "queued": true,
                    "targetDirectory": canonical_target,
                    "reason": null,
                }),
            )
            .await
            .is_err()
            {
                return Err("send_failed");
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
                state.workspace_terminal_bindings().remove(session_id);
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

fn workspace_terminal_binding_json(
    binding: crate::terminal::binding::WorkspaceTerminalBinding,
) -> Value {
    json!({
        "sessionId": binding.session_id,
        "kind": match binding.kind {
            WorkspaceTerminalKind::Local => "local",
            WorkspaceTerminalKind::Connection => "connection",
        },
        "launchWorkspaceRoot": binding.launch_workspace_root,
        "launchWorkspaceCurrentDirectory": binding.launch_workspace_current_directory,
        "scheme": binding.scheme,
        "connectionId": binding.connection_id,
        "latestTerminalWorkingDirectory": binding.latest_terminal_working_directory,
        "syncCapability": match binding.sync_capability {
            crate::terminal::binding::WorkspaceTerminalSyncCapability::BidirectionalLocal => {
                "bidirectionalLocal"
            }
            crate::terminal::binding::WorkspaceTerminalSyncCapability::LaunchOnly => "launchOnly",
        },
    })
}

async fn terminal_working_directory_update_json(
    state: &AppState,
    binding: crate::terminal::binding::WorkspaceTerminalBinding,
    reported_directory: String,
) -> Result<Value, String> {
    if matches!(
        binding.sync_capability,
        crate::terminal::binding::WorkspaceTerminalSyncCapability::LaunchOnly
    ) {
        return Ok(json!({
            "binding": workspace_terminal_binding_json(binding),
            "reportedDirectory": reported_directory,
            "openable": false,
            "matchesCurrent": false,
            "reason": "unsupported",
        }));
    }

    let current_directory = state.workspace().state().current_directory;
    let reported_for_task = reported_directory.clone();
    let comparison = tokio::task::spawn_blocking(move || {
        let reported = PathBuf::from(&reported_for_task);
        let reported_metadata =
            std::fs::metadata(&reported).map_err(|_| "not_openable".to_string())?;
        if !reported_metadata.is_dir() {
            return Err("not_directory".to_string());
        }
        let reported_canonical = reported
            .canonicalize()
            .map_err(|_| "not_openable".to_string())?;
        let current_canonical = current_directory
            .canonicalize()
            .map_err(|_| "current_directory_unavailable".to_string())?;
        Ok::<_, String>(reported_canonical == current_canonical)
    })
    .await
    .map_err(|error| format!("terminal cwd comparison task failed: {error}"))?;

    match comparison {
        Ok(matches_current) => Ok(json!({
            "binding": workspace_terminal_binding_json(binding),
            "reportedDirectory": reported_directory,
            "openable": true,
            "matchesCurrent": matches_current,
            "reason": null,
        })),
        Err(reason) => Ok(json!({
            "binding": workspace_terminal_binding_json(binding),
            "reportedDirectory": reported_directory,
            "openable": false,
            "matchesCurrent": false,
            "reason": reason,
        })),
    }
}

#[derive(Debug, PartialEq, Eq)]
enum CwdDecodeError {
    UnsupportedHost,
    Invalid(String),
}

fn decode_file_url(raw: &str) -> Result<String, CwdDecodeError> {
    let rest = raw.strip_prefix("file://").ok_or_else(|| {
        CwdDecodeError::Invalid("terminal cwd update must be a file:// URL".to_string())
    })?;
    let (host, path) = if rest.starts_with('/') {
        ("", rest)
    } else {
        let Some((host, _path_without_host)) = rest.split_once('/') else {
            return Err(CwdDecodeError::Invalid(
                "terminal cwd file URL is missing a path".to_string(),
            ));
        };
        (host, &rest[host.len()..])
    };

    if !host_is_local(host) {
        return Err(CwdDecodeError::UnsupportedHost);
    }

    percent_decode(path)
}

fn host_is_local(host: &str) -> bool {
    if host.is_empty() || host.eq_ignore_ascii_case("localhost") {
        return true;
    }

    std::env::var("HOST")
        .ok()
        .or_else(|| std::env::var("HOSTNAME").ok())
        .map(|local| host.eq_ignore_ascii_case(&local))
        .unwrap_or(false)
}

fn percent_decode(raw: &str) -> Result<String, CwdDecodeError> {
    let bytes = raw.as_bytes();
    let mut decoded = Vec::with_capacity(bytes.len());
    let mut i = 0;
    while i < bytes.len() {
        if bytes[i] == b'%' {
            if i + 2 >= bytes.len() {
                return Err(CwdDecodeError::Invalid(
                    "terminal cwd file URL contains an incomplete percent escape".to_string(),
                ));
            }
            let hex = std::str::from_utf8(&bytes[i + 1..i + 3]).map_err(|_| {
                CwdDecodeError::Invalid(
                    "terminal cwd file URL contains invalid percent escape bytes".to_string(),
                )
            })?;
            let value = u8::from_str_radix(hex, 16).map_err(|_| {
                CwdDecodeError::Invalid(
                    "terminal cwd file URL contains invalid percent escape".to_string(),
                )
            })?;
            decoded.push(value);
            i += 3;
        } else {
            decoded.push(bytes[i]);
            i += 1;
        }
    }

    String::from_utf8(decoded).map_err(|_| {
        CwdDecodeError::Invalid("terminal cwd file URL is not valid UTF-8".to_string())
    })
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

    #[tokio::test]
    async fn terminal_route_creates_workspace_terminal_with_binding() {
        if !PathBuf::from(DEFAULT_TEST_SHELL).exists() {
            return;
        }

        let state = AppState::new("test-version");
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        state
            .workspace()
            .set_directory_state(cwd.clone(), cwd.clone(), "local".to_string(), None);
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
                    "type": "terminal.createWorkspace",
                    "id": "req-workspace",
                    "data": {
                        "cols": 80,
                        "rows": 24
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.createWorkspace");

        let created = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.created"),
        )
        .await
        .expect("receives terminal.created before timeout")
        .expect("terminal.created frame exists");
        assert_eq!(created["id"], "req-workspace");
        let session_id = created["sessionId"]
            .as_str()
            .expect("created message includes sessionId")
            .to_string();
        assert_eq!(created["data"]["cols"], 80);
        assert_eq!(created["data"]["rows"], 24);
        assert_eq!(created["data"]["binding"]["sessionId"], session_id);
        assert_eq!(created["data"]["binding"]["kind"], "local");
        assert_eq!(
            created["data"]["binding"]["launchWorkspaceCurrentDirectory"].as_str(),
            Some(cwd.to_string_lossy().as_ref())
        );
        assert_eq!(
            created["data"]["binding"]["syncCapability"],
            "bidirectionalLocal"
        );

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.close",
                    "sessionId": session_id,
                    "id": "req-close",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.close");
        let closed = next_terminal_message_of_type(&mut socket, "terminal.closed")
            .await
            .expect("receives terminal.closed");
        assert_eq!(closed["id"], "req-close");

        server.abort();
    }

    #[tokio::test]
    async fn terminal_route_updates_workspace_terminal_working_directory() {
        if !PathBuf::from(DEFAULT_TEST_SHELL).exists() {
            return;
        }

        let state = AppState::new("test-version");
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        state
            .workspace()
            .set_directory_state(cwd.clone(), cwd.clone(), "local".to_string(), None);
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
                    "type": "terminal.createWorkspace",
                    "id": "req-workspace",
                    "data": {
                        "cols": 80,
                        "rows": 24
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.createWorkspace");
        let created = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.created"),
        )
        .await
        .expect("receives terminal.created before timeout")
        .expect("terminal.created frame exists");
        let session_id = created["sessionId"]
            .as_str()
            .expect("created message includes sessionId")
            .to_string();

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.updateWorkingDirectory",
                    "sessionId": session_id,
                    "id": "req-cwd",
                    "data": {
                        "directoryUrl": format!("file://localhost{}", cwd.display())
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.updateWorkingDirectory");

        let updated = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.workingDirectoryUpdated"),
        )
        .await
        .expect("receives terminal.workingDirectoryUpdated before timeout")
        .expect("terminal.workingDirectoryUpdated frame exists");
        assert_eq!(updated["id"], "req-cwd");
        assert_eq!(updated["sessionId"], session_id);
        assert_eq!(
            updated["data"]["reportedDirectory"].as_str(),
            Some(cwd.to_string_lossy().as_ref())
        );
        assert_eq!(updated["data"]["openable"], true);
        assert_eq!(updated["data"]["matchesCurrent"], true);
        assert_eq!(
            updated["data"]["binding"]["latestTerminalWorkingDirectory"].as_str(),
            Some(cwd.to_string_lossy().as_ref())
        );

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.close",
                    "sessionId": session_id,
                    "id": "req-close",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.close");

        server.abort();
    }

    #[tokio::test]
    async fn terminal_route_queues_workspace_terminal_directory_change() {
        if !PathBuf::from(DEFAULT_TEST_SHELL).exists() {
            return;
        }

        let state = AppState::new("test-version");
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        let target = cwd.clone();
        state
            .workspace()
            .set_directory_state(cwd.clone(), cwd.clone(), "local".to_string(), None);
        let app = routes::router(state.clone());
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
                    "type": "terminal.createWorkspace",
                    "id": "req-workspace",
                    "data": {
                        "cols": 80,
                        "rows": 24
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.createWorkspace");
        let created = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.created"),
        )
        .await
        .expect("receives terminal.created before timeout")
        .expect("terminal.created frame exists");
        let session_id = created["sessionId"]
            .as_str()
            .expect("created message includes sessionId")
            .to_string();

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.changeDirectory",
                    "sessionId": session_id,
                    "id": "req-cd",
                    "data": {
                        "targetDirectory": target
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.changeDirectory");

        let changed = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.directoryChangeQueued"),
        )
        .await
        .expect("receives terminal.directoryChangeQueued before timeout")
        .expect("terminal.directoryChangeQueued frame exists");
        assert_eq!(changed["id"], "req-cd");
        assert_eq!(changed["sessionId"], session_id);
        assert_eq!(changed["data"]["queued"], true);
        assert_eq!(
            changed["data"]["targetDirectory"].as_str(),
            Some(target.to_string_lossy().as_ref())
        );
        assert_eq!(
            changed["data"]["binding"]["sessionId"].as_str(),
            Some(session_id.as_str())
        );
        let parsed_session_id = Uuid::parse_str(&session_id).expect("session id is uuid");
        assert_eq!(
            state
                .workspace_terminal_bindings()
                .get(parsed_session_id)
                .expect("binding remains visible")
                .pending_target_directory
                .as_deref(),
            Some(target.to_string_lossy().as_ref())
        );

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.close",
                    "sessionId": session_id,
                    "id": "req-close",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.close");

        server.abort();
    }

    #[tokio::test]
    async fn terminal_route_compares_stored_working_directory_against_live_workspace() {
        if !PathBuf::from(DEFAULT_TEST_SHELL).exists() {
            return;
        }

        let state = AppState::new("test-version");
        let cwd = std::env::temp_dir()
            .canonicalize()
            .expect("temp directory canonicalizes");
        state
            .workspace()
            .set_directory_state(cwd.clone(), cwd.clone(), "local".to_string(), None);
        let app = routes::router(state.clone());
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
                    "type": "terminal.createWorkspace",
                    "id": "req-workspace",
                    "data": {
                        "cols": 80,
                        "rows": 24
                    }
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.createWorkspace");
        let created = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.created"),
        )
        .await
        .expect("receives terminal.created before timeout")
        .expect("terminal.created frame exists");
        let session_id = created["sessionId"]
            .as_str()
            .expect("created message includes sessionId")
            .to_string();
        let parsed_session_id = Uuid::parse_str(&session_id).expect("session id is uuid");
        state
            .workspace_terminal_bindings()
            .record_terminal_working_directory(
                parsed_session_id,
                cwd.to_string_lossy().into_owned(),
            )
            .expect("records cwd");

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.compareWorkingDirectory",
                    "sessionId": session_id,
                    "id": "req-compare",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.compareWorkingDirectory");

        let compared = tokio::time::timeout(
            std::time::Duration::from_secs(2),
            next_terminal_message_of_type(&mut socket, "terminal.workingDirectoryUpdated"),
        )
        .await
        .expect("receives terminal.workingDirectoryUpdated before timeout")
        .expect("terminal.workingDirectoryUpdated frame exists");
        assert_eq!(compared["id"], "req-compare");
        assert_eq!(compared["sessionId"], session_id);
        assert_eq!(compared["data"]["openable"], true);
        assert_eq!(compared["data"]["matchesCurrent"], true);
        assert_eq!(
            compared["data"]["reportedDirectory"].as_str(),
            Some(cwd.to_string_lossy().as_ref())
        );

        socket
            .send(TungsteniteMessage::Text(
                json!({
                    "type": "terminal.close",
                    "sessionId": session_id,
                    "id": "req-close",
                    "data": {}
                })
                .to_string(),
            ))
            .await
            .expect("sends terminal.close");

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
