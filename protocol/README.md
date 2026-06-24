# Terminal Finder Protocol

Early development uses local HTTP JSON.

## Endpoint

```text
GET  http://127.0.0.1:3587/health
POST http://127.0.0.1:3587/rpc
```

## health

### Request

```text
GET /health
```

### Response

```json
{
  "service": "terminal-finder-core",
  "version": "0.1.0"
}
```

`/health` is the client startup gate. The macOS client checks this endpoint before showing the main workspace UI. If the backend is not already healthy, the client starts the backend process and polls `/health` until it succeeds.

## core.ping

### Request

```json
{
  "method": "core.ping",
  "params": {}
}
```

### Response

```json
{
  "ok": true,
  "result": {
    "service": "terminal-finder-core",
    "version": "0.1.0"
  }
}
```

`core.ping` is the Phase 0 connectivity check between clients and the Rust backend.

## workspace.getState

### Request

```json
{
  "method": "workspace.getState",
  "params": {}
}
```

### Response

```json
{
  "ok": true,
  "result": {
    "state": {
      "workspaceRoot": "/Users/mac",
      "currentDirectory": "/Users/mac",
      "scheme": "local",
      "connectionId": null
    }
  }
}
```

`workspace.getState` returns the backend-owned workspace state. `workspaceRoot` is the root of the current workspace and `currentDirectory` is the directory currently shown by the client. `scheme` is `"local"` for the LocalFsProvider or `"s3"` when the workspace is browsing an S3 connection. `connectionId` is `null` for local browsing or the registered S3 connection id when `scheme == "s3"`.

## workspace.openDirectory

### Request

```json
{
  "method": "workspace.openDirectory",
  "params": {
    "path": "/Users/mac/Desktop",
    "connection_id": null
  }
}
```

`connection_id` is optional. `null` (or omitted) routes the request to the LocalFsProvider — `path` is interpreted as an OS path. A registered S3 connection id routes to that connection's `S3Provider`; `path` is then a bucket-relative prefix (the configured `base_prefix` is prepended on the server side and is never sent by the client).

### Response

```json
{
  "ok": true,
  "result": {
    "state": {
      "workspaceRoot": "/Users/mac",
      "currentDirectory": "/Users/mac/Desktop",
      "scheme": "local",
      "connectionId": null
    },
    "listing": {
      "path": "/Users/mac/Desktop",
      "entries": [
        {
          "name": "Project",
          "path": "/Users/mac/Desktop/Project",
          "kind": "directory",
          "isDirectory": true,
          "size": null,
          "modifiedAt": "2026-06-01T08:00:00Z"
        }
      ]
    }
  }
}
```

`workspace.openDirectory` validates that `path` exists and is a directory, then returns the refreshed state plus a non-recursive directory listing so clients can redraw immediately.

For `connection_id == null` (local): opening a directory inside the canonical current `workspaceRoot` preserves that root and updates `currentDirectory`. Opening a directory outside it, opening an ancestor of it, or opening a directory after the current root can no longer be canonicalized sets both `workspaceRoot` and `currentDirectory` to the canonical target directory.

For a registered S3 `connection_id` (`scheme: "s3"`): there is no canonical-path / workspace-root concept; both `workspaceRoot` and `currentDirectory` report the resolved S3 prefix (with a trailing `/` for non-empty prefixes). The local workspace store is untouched. An unknown `connection_id` returns the `connection_not_found` error code.

## workspace.listDirectory

### Request

```json
{
  "method": "workspace.listDirectory",
  "params": {
    "path": "/Users/mac",
    "connection_id": null
  }
}
```

`connection_id` follows the same routing rules as `workspace.openDirectory`.

### Response

```json
{
  "ok": true,
  "result": {
    "path": "/Users/mac",
    "entries": [
      {
        "name": "Desktop",
        "path": "/Users/mac/Desktop",
        "kind": "directory",
        "isDirectory": true,
        "size": null,
        "modifiedAt": "2026-06-01T08:00:00Z"
      }
    ]
  }
}
```

Entries are non-recursive. Directories are returned before files, then sorted by name. For S3 routing, entries reflect the bucket-relative paths under the connection's `base_prefix`.

## connection.create

### Request

```json
{
  "method": "connection.create",
  "params": {
    "display_name": "MinIO local",
    "endpoint": "http://localhost:9000",
    "region": "us-east-1",
    "bucket": "test-bucket",
    "base_prefix": "",
    "path_style": true,
    "access_key_id": "<redacted>",
    "secret_access_key": "<redacted>"
  }
}
```

### Response

```json
{
  "ok": true,
  "result": { "connection_id": "a1b2c3d4-1111-2222-3333-444455556666" }
}
```

`connection.create` registers an S3 connection in core's in-memory `ConnectionRegistry`. **Credentials are NEVER persisted by core** — the client (currently macOS Keychain) owns persistence and must re-pass credentials on each app start. The returned `connection_id` is a UUID v4 string the client uses for subsequent calls.

This method never fails on bad credentials at registration time (no network round-trip happens here); credential validity is only checked when the connection is first used to list / read / write objects.

## connection.list

### Request

```json
{ "method": "connection.list", "params": {} }
```

### Response

```json
{
  "ok": true,
  "result": {
    "connections": [
      {
        "connection_id": "a1b2c3d4-1111-2222-3333-444455556666",
        "display_name": "MinIO local",
        "endpoint": "http://localhost:9000",
        "bucket": "test-bucket",
        "base_prefix": ""
      }
    ]
  }
}
```

Returns connection summaries (`ConnectionInfoDto` cross-FFI). Credentials are intentionally omitted from the response shape — they live only in the in-memory registry and the client's Keychain.

## connection.remove

### Request

```json
{ "method": "connection.remove", "params": { "connection_id": "a1b2c3d4-1111-2222-3333-444455556666" } }
```

### Response

```json
{ "ok": true, "result": {} }
```

Removes the connection, its in-memory credentials, and any cached S3 provider so the `connection_id` can no longer be used to access objects. Returns the `connection_not_found` error code when the `connection_id` is unknown.

## workspace.downloadFile

### Request (FFI only)

```text
download_file(connection_id: Option<String>, remote_path: String, local_destination: String) -> Result<(), CoreError>
```

### Response

Returns `Ok(())` on success. There is no JSON-RPC equivalent in this phase: the in-process Swift client invokes it directly through the UniFFI `CoreHandle`.

Reads `remote_path` from the addressed provider (`connection_id == None` → local FS, `Some(id)` → registered S3 connection) and writes the bytes to `local_destination`. The provider enforces a 50 MiB per-object cap and returns `provider_error` when the source is larger; oversized objects must be streamed by future phases.

Other error codes mirror the underlying provider:
- `connection_not_found` — `connection_id` is not in the registry.
- `object_not_found` / `filesystem_read_failed` — the remote/local path is missing.
- `authentication_failed` — S3 credentials were rejected.
- `network_error` — transient S3 transport issue.

## workspace.uploadFile

### Request (FFI only)

```text
upload_file(connection_id: Option<String>, remote_path: String, local_source: String) -> Result<(), CoreError>
```

Reads `local_source` from disk and writes the contents to `remote_path` on the addressed provider. Local writes overwrite; S3 PUTs the object. Emits two `transfer_progress` events on the event channel: one with `bytes_transferred == 0` and one with `bytes_transferred == total_bytes`. Phase 1 reads the source into memory inline, so callers should respect the 50 MiB convention used by `download_file` until phase 2 lands streaming uploads.

## workspace.deleteEntry

### Request (FFI only)

```text
delete_entry(connection_id: Option<String>, path: String) -> Result<(), CoreError>
```

Deletes one entry. Local removes file or recursively removes directory; S3 deletes only the named key (no recursive prefix sweep — phase 2 owns that).

## workspace.createRemoteDirectory

### Request (FFI only)

```text
create_remote_directory(connection_id: Option<String>, path: String) -> Result<(), CoreError>
```

Creates a directory at `path`. Local uses `create_dir_all`; S3 writes a zero-byte object keyed `<path>/` as a placeholder so subsequent `list` calls surface it. Clients should check `connection_capabilities().has_native_directories` first and warn the user when it is `false`.

## workspace.renameEntry

### Request (FFI only)

```text
rename_entry(connection_id: Option<String>, from: String, to: String) -> Result<(), CoreError>
```

Renames / moves `from` → `to` on the same provider. Local is atomic on the same volume; S3 performs copy + delete and is **not atomic** — a failure between the two steps leaves both `from` and `to` in the bucket. Clients should check `connection_capabilities().can_rename` and warn the user when it is `false`.

## workspace.connectionCapabilities

### Request (FFI only)

```text
connection_capabilities(connection_id: String) -> Result<ProviderCapsDto, CoreError>
```

Returns:
- `can_rename` — provider supports atomic rename (Local `true`, S3 `false`).
- `can_symlink` — provider supports symbolic links (Local `true`, S3 `false`).
- `can_write` — provider exposes `write`/`delete`/`create_directory`/`rename` at all (Local and S3 both `true` in phase 1).
- `has_native_directories` — `false` means "directories are simulated via marker objects" (S3); `true` means the underlying store actually tracks directories (Local).

Caps are read directly from the resolved provider so callers see the same capabilities the operations themselves honour.

## terminal.createConnection (FFI)

### Request (FFI only)

```text
create_connection_terminal(connection_id: String, cols: u16, rows: u16, listener: TerminalEventListener) -> Result<String, CoreError>
```

Creates a terminal for a registered S3 connection. Core ensures the workspace runtime is ready, asks the runtime to expose the connection's bucket as a runtime-private path, and opens a PTY session rooted at that path. Credentials are injected only through the runtime's safe channel at mount time; they are not persisted and do not appear in launch arguments.

The returned string is the terminal `sessionId`. After creation, `send_terminal_input`, `resize_terminal`, `close_terminal`, and `TerminalEventListener` callbacks behave the same as a local PTY session.

The workspace runtime is an abstraction. The FFI method and error codes stay runtime-neutral so future runtime implementations can replace the current one without client contract changes.

Error codes:
- `connection_not_found` — `connection_id` is not in the registry.
- `workspace_runtime_unavailable` — the workspace runtime cannot be reached.
- `workspace_provision_failed` — runtime prerequisites are missing or cannot be prepared.
- `workspace_start_failed` — the workspace session or terminal could not start.
- `mount_failed` — the bucket could not be exposed as a workspace path.
- `mount_timeout` — the mount did not become ready in time.

## workspace.shutdown (FFI)

### Request (FFI only)

```text
shutdown_workspace() -> Result<(), CoreError>
```

Best-effort cleanup for the current workspace runtime. The macOS client calls this during app termination. The runtime releases any shared workspace resources and clears cached mount reservations. The method is idempotent from the client's point of view.

### Event: `transfer_progress`

Sent through the `EventClientProtocol` channel during long transfers (`upload_file` today, future streaming `download_file`):

```json
{
  "type": "transfer_progress",
  "connection_id": "a1b2c3d4-...",
  "path": "bucket/key.bin",
  "bytes_transferred": 0,
  "total_bytes": 5242880
}
```

`bytes_transferred == total_bytes` signals completion. Multiple in-flight transfers share the channel — clients should key progress UI off `(connection_id, path)`.

## Errors

RPC errors use a shared shape:

```json
{
  "ok": false,
  "error": {
    "code": "not_directory",
    "message": "path is not a directory: /Users/mac/file.txt"
  }
}
```

Common workspace error codes include `invalid_params`, `filesystem_read_failed`, `not_directory`, and `background_task_failed`. Missing paths return HTTP 404, permission failures return HTTP 403, and non-directory paths return HTTP 400.

## WebSocket Transports

Phase 2 onward adds WebSocket channels alongside the HTTP JSON API. The HTTP `/rpc` endpoint stays strictly request/response.

`/events` is the backend lifecycle/event stream. It does not carry terminal (PTY) I/O. PTY traffic uses the separate `/terminal` WebSocket/session channel.

### Event Channel

```text
GET ws://127.0.0.1:3587/events
```

The client upgrades to `/events` after `/health` passes. The connection is bound to `127.0.0.1` only and is currently unauthenticated; token auth is deferred to the multi-client phase.

### Message Envelope

Every WebSocket message is a JSON text frame wrapped in a shared envelope:

```json
{
  "type": "backend.ready",
  "data": {
    "service": "terminal-finder-core",
    "version": "0.1.0"
  }
}
```

| Field | Required | Direction | Meaning |
|---|---|---|---|
| `type` | always | both | Message kind. Selects how `data` is interpreted and dispatched. |
| `sessionId` | `terminal.*` on the PTY channel | both | Which PTY session the message belongs to. Absent for connection-wide events (`backend.ready`, `heartbeat`). |
| `id` | optional | both | Correlates a command with its acknowledgement. Used by terminal commands that expect a reply (`terminal.create`, `terminal.resize`, `terminal.close`); echoed on the matching reply. Omitted for high-frequency `terminal.input` / `terminal.output`. |
| `data` | always | both | Type-specific payload. `{}` when the type carries no fields. |

The envelope is intentionally separate from the RPC `{ "ok": true, "result": ... }` shape. Events are not request/response pairs, so they do not use `ok`.

### Connection Events (backend to client)

Connection-wide events carry no `sessionId`.

```json
{ "type": "backend.ready", "data": { "service": "terminal-finder-core", "version": "0.1.0" } }
```

Sent once immediately after the WebSocket upgrade, confirming the channel is live.

```json
{ "type": "heartbeat", "data": {} }
```

Sent on a fixed interval so the client can detect a silently dropped connection. The client ignores the payload.

```json
{ "type": "backend.error", "data": { "code": "internal", "message": "..." } }
```

A connection-level error not tied to a specific session.

### Terminal Channel (planned)

Phase 3 adds a dedicated terminal WebSocket/session channel separate from `/events`.

```text
GET ws://127.0.0.1:3587/terminal
```

Terminal messages use the same envelope shape, but they are not sent over `/events`.

### Byte Encoding

PTY input and output are raw byte streams that are not guaranteed to be valid UTF-8 (they carry escape sequences). The `bytes` field in `terminal.input` and `terminal.output` is Base64-encoded. A later optimization may move `terminal.output` to binary WebSocket frames; control messages stay JSON text frames.

### Terminal Commands (client to backend)

```json
{ "type": "terminal.create", "id": "req-1", "data": { "cwd": "/Users/mac", "cols": 80, "rows": 24, "shell": null } }
```

Opens a PTY session. `cwd` is the working directory, `cols`/`rows` the initial size, `shell` an optional explicit shell (null lets the backend choose the default). The backend replies with `terminal.created` carrying the assigned `sessionId`, echoing `id`.

```json
{ "type": "terminal.input", "sessionId": "a1b2c3", "data": { "bytes": "bHMK" } }
```

Feeds keyboard input to the PTY. `bytes` is Base64-encoded raw input. High-frequency, so it carries no `id`; failures surface as `terminal.error`.

```json
{ "type": "terminal.resize", "sessionId": "a1b2c3", "id": "req-2", "data": { "cols": 120, "rows": 40 } }
```

Propagates a viewport change to the PTY. The backend replies with `terminal.resized`, echoing `id`.

```json
{ "type": "terminal.close", "sessionId": "a1b2c3", "id": "req-3", "data": {} }
```

Closes the session and terminates its PTY process. The backend replies with `terminal.closed` when close has been accepted, echoing `id`; the process end is still reported separately as `terminal.exit`.

### Terminal Events (backend to client)

```json
{ "type": "terminal.created", "sessionId": "a1b2c3", "id": "req-1", "data": { "cols": 80, "rows": 24 } }
```

Acknowledges `terminal.create`. Echoes the request `id` and assigns the `sessionId` used by all later messages for this session.

```json
{ "type": "terminal.output", "sessionId": "a1b2c3", "data": { "bytes": "JCA=" } }
```

A chunk of PTY output. `bytes` is Base64-encoded raw output, fed directly to the terminal view. High-frequency, no `id`.

```json
{ "type": "terminal.resized", "sessionId": "a1b2c3", "id": "req-2", "data": { "cols": 120, "rows": 40 } }
```

Acknowledges `terminal.resize`. Echoes the request `id` and the accepted PTY size.

```json
{ "type": "terminal.closed", "sessionId": "a1b2c3", "id": "req-3", "data": {} }
```

Acknowledges that `terminal.close` was accepted. The session's PTY process may still be shutting down; `terminal.exit` reports the final process end.

```json
{ "type": "terminal.exit", "sessionId": "a1b2c3", "data": { "code": 0, "signal": null } }
```

The PTY process ended. `code` is the exit status; `signal` is set instead when the process was terminated by a signal.

```json
{ "type": "terminal.error", "sessionId": "a1b2c3", "id": "req-2", "data": { "code": "create_failed", "message": "..." } }
```

A session-scoped failure. Echoes `id` when it answers a specific command (`terminal.create` / `terminal.resize` / `terminal.close`); omits `id` for asynchronous failures such as a rejected `terminal.input`.

### WebSocket Error Codes

```text
internal           connection-level backend failure (backend.error)
create_failed      PTY session could not be created
read_failed        PTY output could not be read
write_failed       input could not be written to the PTY
resize_failed      PTY size could not be changed
wait_failed        PTY process exit could not be observed
unknown_session    sessionId does not match a live session
invalid_message    envelope or data failed to parse
workspace_runtime_unavailable   workspace runtime is not reachable
workspace_provision_failed      workspace prerequisites are missing or could not be prepared
workspace_start_failed          shared workspace or terminal could not start
mount_failed                    bucket mount failed
mount_timeout                   mount did not become ready in time
```
