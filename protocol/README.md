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
```
