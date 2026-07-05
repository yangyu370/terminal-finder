# Terminal Finder Protocol

The macOS client defaults to in-process UniFFI and holds a `CoreHandle` directly.
The local HTTP/WebSocket server is optional server-mode infrastructure for
debugging and future non-macOS clients; its RPC methods mirror the same backend
semantics where exposed.

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

`/health` is only a server-mode readiness check. The default macOS client uses
in-process UniFFI (`CoreHandle::ping`) and does not start or poll a backend
process.

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

## Command surface (FFI)

The command surface exposes a small runtime registry over UniFFI. It is additive
to the existing direct FFI methods; the current macOS client still links core
in-process and does not depend on HTTP or a local port.

### Methods

```text
command_list() -> String
command_describe(id: String) -> Result<String, CoreError>
command_invoke(id: String, params_json: String) -> Result<String, CoreError>
```

`command_list` returns a JSON array of command descriptors. `command_describe`
returns one descriptor JSON object. `command_invoke` parses `params_json` as
JSON, invokes the matching backend command against the same `AppState` held by
the `CoreHandle`, and returns the command result serialized as JSON.

Descriptor objects have exactly these fields:

| Field | Type | Meaning |
|---|---|---|
| `id` | string | Stable command id, such as `workspace.listDirectory`. |
| `title` | string | Human-readable command name. |
| `category` | string | Broad command group. |
| `summary` | string | Short description for command pickers or docs. |
| `params_schema` | JSON object | JSON Schema-style description of accepted params. |
| `result_schema` | JSON object | JSON Schema-style description of the result. |
| `destructive` | boolean | Whether the command can mutate or delete user data. |
| `context_requirements` | string array | Required runtime context flags; empty when none. |

Phase 0 commands:

| Command id | Params | Result | State effect |
|---|---|---|---|
| `workspace.listDirectory` | `{ "path": string, "connection_id"?: string \| null }` | Existing `workspace.listDirectory` result | Stateless; does not change workspace state. |
| `workspace.openDirectory` | `{ "path": string, "connection_id"?: string \| null }` | Existing `workspace.openDirectory` result | Updates backend workspace state only after validation and listing succeed. |

Command responses reuse the existing camelCase workspace structures:
`workspaceRoot`, `currentDirectory`, `connectionId`, `isDirectory`, and
`modifiedAt` keep the same shape as the direct workspace APIs.

Error code convention:

- `unknown_method` — `command_describe` or `command_invoke` received an unknown command id.
- `invalid_params` — `command_invoke` received invalid JSON or params rejected by the command.
- Domain errors from the invoked command propagate unchanged, such as `not_directory`, `filesystem_read_failed`, `connection_not_found`, `authentication_failed`, `network_error`, and `provider_error`.

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

Removes the connection, its in-memory credentials, any cached S3 provider, and any workspace runtime exposure for that connection so the `connection_id` can no longer be used to access objects. Returns the `connection_not_found` error code when the `connection_id` is unknown.

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

## Workspace-Bound Terminal (FFI)

The macOS client uses these methods through in-process UniFFI. The optional
`/terminal` WebSocket mirrors the same semantic surface for server-mode testing
and future non-macOS clients.

### create_workspace_terminal

```text
create_workspace_terminal(cols: u16, rows: u16, listener: TerminalEventListener) -> Result<WorkspaceTerminalCreateDto, CoreError>
```

Creates a terminal from the current backend-owned workspace context and returns
its binding metadata:

```json
{
  "binding": {
    "sessionId": "a1b2c3...",
    "kind": "local",
    "launchWorkspaceRoot": "/Users/mac/project",
    "launchWorkspaceCurrentDirectory": "/Users/mac/project",
    "scheme": "local",
    "connectionId": null,
    "latestTerminalWorkingDirectory": null,
    "syncCapability": "bidirectionalLocal"
  }
}
```

Local workspace terminals launch a zsh PTY in `currentDirectory`, with
per-session shell integration injected by core. The integration emits OSC 7 cwd
reports and owns the controlled `cd` request file. Connection-backed workspace
terminals remain launch-bound and report `syncCapability: "launchOnly"`.

### update_terminal_working_directory

```text
update_terminal_working_directory(session_id: String, directory_url: String) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError>
```

Called when the terminal view reports an OSC 7 `file://host/path` cwd. Core
percent-decodes the URL, rejects non-local hosts, records the decoded path as
advisory terminal state, then canonicalizes the reported directory and the live
workspace `currentDirectory` in a blocking filesystem task.

```json
{
  "binding": { "...": "..." },
  "reportedDirectory": "/Users/mac/project",
  "openable": true,
  "matchesCurrent": true,
  "reason": null
}
```

`openable: false` may carry reasons such as `unsupported_host`,
`unsupported`, `not_openable`, `not_directory`, or
`current_directory_unavailable`. Unknown sessions return `unknown_session`.

### compare_terminal_working_directory

```text
compare_terminal_working_directory(session_id: String) -> Result<TerminalWorkingDirectoryUpdateDto, CoreError>
```

Recomputes the same canonical comparison using the latest cwd previously
reported for the terminal and the current live workspace state. If no cwd has
been reported yet, the result is `openable: false`, `matchesCurrent: false`,
and `reason: "cwd_unknown"`.

### change_terminal_directory

```text
change_terminal_directory(session_id: String, target_directory: String) -> Result<TerminalDirectoryChangeDto, CoreError>
```

Queues a controlled directory change for a local workspace terminal. Core
rejects unknown sessions, connection-backed sessions, targets with control
characters, and targets that are not openable local directories. On success,
core atomically writes the canonical target directory to the session's private
request file and returns:

```json
{
  "binding": { "...": "..." },
  "queued": true,
  "targetDirectory": "/Users/mac/project/src",
  "reason": null
}
```

Success means the request was safely queued, not that the shell has already
confirmed the new directory. The shell applies the request on the next prompt
cycle and confirms via a later OSC 7 report. For idle prompts, core also wakes a
per-session FIFO watched by zsh `zle -F`, so the request can apply without
submitting or clearing the user's current input line. If the wake path is not
available, the safe queued request-file semantics still hold.

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

### Terminal Channel

The optional server mode exposes a dedicated terminal WebSocket/session channel
separate from `/events`. The macOS client defaults to in-process FFI and does
not depend on this socket.

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
{ "type": "terminal.createWorkspace", "id": "req-ws-1", "data": { "cols": 80, "rows": 24 } }
```

Creates a workspace-bound terminal from the current backend workspace context.
The backend replies with `terminal.created`; `data.binding` contains the same
workspace terminal binding fields returned by `create_workspace_terminal`.

```json
{ "type": "terminal.updateWorkingDirectory", "sessionId": "a1b2c3", "id": "req-cwd-1", "data": { "directoryUrl": "file://localhost/Users/mac/project" } }
```

Records and validates a terminal cwd report. The backend replies with
`terminal.workingDirectoryUpdated`.

```json
{ "type": "terminal.compareWorkingDirectory", "sessionId": "a1b2c3", "id": "req-cwd-2", "data": {} }
```

Recomputes the validated cwd comparison against the live workspace state using
the latest reported terminal cwd. The backend replies with
`terminal.workingDirectoryUpdated`.

```json
{ "type": "terminal.changeDirectory", "sessionId": "a1b2c3", "id": "req-cd-1", "data": { "targetDirectory": "/Users/mac/project/src" } }
```

Queues a controlled local terminal directory change via the workspace-bound
terminal request file. The backend replies with
`terminal.directoryChangeQueued`.

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

Acknowledges `terminal.create`. Echoes the request `id` and assigns the `sessionId` used by all later messages for this session. For `terminal.createWorkspace`, the same event additionally includes `data.binding`.

```json
{
  "type": "terminal.workingDirectoryUpdated",
  "sessionId": "a1b2c3",
  "id": "req-cwd-1",
  "data": {
    "binding": { "sessionId": "a1b2c3", "kind": "local", "syncCapability": "bidirectionalLocal" },
    "reportedDirectory": "/Users/mac/project",
    "openable": true,
    "matchesCurrent": true,
    "reason": null
  }
}
```

Acknowledges `terminal.updateWorkingDirectory` or
`terminal.compareWorkingDirectory`.

```json
{
  "type": "terminal.directoryChangeQueued",
  "sessionId": "a1b2c3",
  "id": "req-cd-1",
  "data": {
    "binding": { "sessionId": "a1b2c3", "kind": "local", "syncCapability": "bidirectionalLocal" },
    "queued": true,
    "targetDirectory": "/Users/mac/project/src",
    "reason": null
  }
}
```

Acknowledges that `terminal.changeDirectory` was accepted and queued. A later
OSC 7 cwd report confirms whether the shell has actually moved.

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
