# Terminal Finder Protocol

Early development uses local HTTP JSON.

## Endpoint

```text
POST http://127.0.0.1:3587/rpc
```

## Request

```json
{
  "method": "core.ping",
  "params": {}
}
```

## Response

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
