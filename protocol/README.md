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
      "currentDirectory": "/Users/mac"
    }
  }
}
```

`workspace.getState` returns the backend-owned workspace state. In the current Phase 1 shape, `workspaceRoot` is the root of the current workspace and `currentDirectory` is the directory currently shown by the client.

## workspace.openDirectory

### Request

```json
{
  "method": "workspace.openDirectory",
  "params": {
    "path": "/Users/mac/Desktop"
  }
}
```

### Response

```json
{
  "ok": true,
  "result": {
    "state": {
      "workspaceRoot": "/Users/mac",
      "currentDirectory": "/Users/mac/Desktop"
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

`workspace.openDirectory` validates that `path` exists and is a directory, updates `currentDirectory`, and returns the refreshed state plus a non-recursive directory listing so clients can redraw immediately. It does not change `workspaceRoot`.

## workspace.listDirectory

### Request

```json
{
  "method": "workspace.listDirectory",
  "params": {
    "path": "/Users/mac"
  }
}
```

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

Entries are non-recursive. Directories are returned before files, then sorted by name.

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
