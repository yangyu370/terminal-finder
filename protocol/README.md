# Terminal Finder Protocol

Early development uses local HTTP JSON.

## Endpoint

```text
POST http://127.0.0.1:3587/rpc
```

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
