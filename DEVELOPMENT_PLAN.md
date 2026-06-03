# Terminal Finder Development Plan

## 1. Product Direction

Terminal Finder is a local-first workspace system.

The Rust core is the product backend. Native and web clients are presentation layers that connect to the same backend API.

The first client is a macOS app built with Swift and AppKit. It should feel close to Finder: native window behavior, sidebar, toolbar, file list, context menus, keyboard shortcuts, and platform conventions.

Future Windows, Linux, and web clients should reuse the same Rust backend and only replace the UI/client layer.

## 2. Target Architecture

```text
terminal-finder/
├── core/                         # Rust local backend
│   ├── crates/
│   │   ├── tf-api                # API types and protocol definitions
│   │   ├── tf-server             # HTTP/WebSocket/local server
│   │   ├── tf-workspace          # workspace state and orchestration
│   │   ├── tf-fs                 # file system operations
│   │   ├── tf-terminal           # PTY/session management
│   │   ├── tf-search             # search and indexing
│   │   ├── tf-git                # git status and repository features
│   │   └── tf-events             # event bus
│   └── Cargo.toml
│
├── clients/
│   ├── MacOS/                    # Swift + AppKit client
│   ├── web/                      # future browser client
│   ├── windows/                  # future Windows client
│   └── linux/                    # future Linux client
│
├── protocol/                     # API docs, schemas, examples
└── docs/
```

### Current Repository Structure

The current repository is intentionally smaller than the long-term target architecture.

```text
terminal-finder/
├── core/                         # Rust local backend
│   ├── src/
│   │   ├── api/                  # HTTP/RPC routing and controllers
│   │   ├── workspace/            # workspace state, service, DTOs, and filesystem adapter
│   │   ├── error.rs              # API error response mapping
│   │   ├── main.rs               # backend process entrypoint
│   │   └── state.rs              # shared backend state
│   ├── Cargo.toml
│   └── Cargo.lock
│
├── clients/
│   └── MacOS/                    # first macOS client
│       └── MacOS/
│           ├── API/              # backend HTTP/RPC client
│           ├── Models/           # client-side state models
│           ├── Services/         # client system integrations such as backend process launch
│           ├── ViewModels/       # UI state and async actions
│           ├── Views/            # SwiftUI views and components
│           └── Assets.xcassets/  # static visual assets
│
└── protocol/
    └── README.md                 # current protocol notes
```

Keep the current structure lightweight until a feature needs more separation. Do not create the future `core/crates/*` workspace until the backend has enough real surface area to justify it.

### Current Status As Of 2026-06-03

The project is now past the pure connectivity baseline.

Completed:

- Phase 0 baseline: Rust backend, macOS client shell, `core.ping`, `/health`, protocol notes, and lightweight module split.
- Phase 1 first slice: `workspace.listDirectory` exists in the Rust backend and is callable from the macOS client.
- The macOS client can request a directory path and render returned entries in a simple SwiftUI list.
- The default client directory uses the real user home path from the password database instead of the sandbox container home.
- Backend request logging uses `tracing` with method/status/duration fields.
- Directory listing runs through `tokio::task::spawn_blocking` so filesystem scans do not block async runtime workers.
- Workspace state is now owned by the backend through `workspace.getState` and `workspace.openDirectory`.
- The macOS client checks `/health` on startup, launches the bundled Rust backend with `Process` when needed, polls health, and only then enters the main workspace UI.
- The macOS build copies the Rust core executable into the app bundle so the client can start it without relying on a manually launched backend.
- The macOS app sandbox is disabled for the current local-first backend model so a client-launched backend can see the same real user directories as a manually launched backend.

Still active:

- The client is still only partially Finder-like; the directory table has moved toward AppKit, but sidebar, toolbar, context menus, and keyboard behavior still need refinement.
- Backend process lifecycle is a first working path, but packaging/signing and graceful shutdown semantics should be revisited before distribution.
- There is no event stream or file watcher yet.
- File operations, terminal sessions, search, and git awareness remain deferred.

## 3. Core Technology Stack

### Rust Backend

Use Rust as a local backend process. It owns workspace state, file operations, terminal sessions, search, git status, events, and future automation/plugin capabilities.

Recommended stack:

```text
tokio             async runtime
axum              HTTP and WebSocket server
serde             request/response serialization
serde_json        JSON encoding
tracing           structured logging
thiserror         typed errors
anyhow            application-level error handling
uuid              IDs for sessions, workspaces, operations
notify            file system watching
portable-pty      cross-platform pseudo-terminal support
ignore            gitignore-aware walking
walkdir           recursive directory traversal
rusqlite/sqlx     SQLite storage
tantivy           later full-text search indexing
gix or git2       later git integration
trash             move-to-trash/recycle-bin behavior
```

### macOS Client

Use Swift as the first native client.

Phase 0 uses SwiftUI because the current client is only a connectivity shell. Finder-like browsing screens can still move toward AppKit controls where native behavior matters, especially sidebar/file-table interactions.

Recommended stack:

```text
Swift
SwiftUI            early screens and simple state-driven views
AppKit
async/await
URLSession
URLSessionWebSocketTask
NSWindowController
NSSplitViewController
NSOutlineViewDelegate/DataSource
NSTableViewDelegate/DataSource
NSToolbar
NSMenu
NSWorkspace
QuickLook
SwiftTerm
```

The macOS client should not own core business logic. It renders backend state, sends user actions to the backend, and subscribes to backend events.

Current client layering:

```text
Views        layout and user interaction
ViewModels   UI state, async actions, API orchestration
API          backend HTTP/RPC calls and DTOs
Services     client system integrations such as Process-based backend launch
Models       client-side state models
Assets       static images, colors, icons, and app assets
```

### Future Web Client

Use the same backend API.

Recommended stack:

```text
TypeScript
React or Svelte
xterm.js
WebSocket
TanStack Query or equivalent client cache
```

### Future Windows/Linux Clients

There are two reasonable paths:

```text
Path A: shared web UI inside a native shell
- Tauri
- React/Svelte
- xterm.js

Path B: native UI per platform
- Windows: WinUI / WPF / Avalonia
- Linux: GTK / Qt / Avalonia
```

Prefer Path A unless native platform fidelity becomes a product requirement.

## 4. Communication Model

Use a local backend server started by the client.

Early transport:

```text
HTTP JSON API for request/response
WebSocket for events and streams
```

Avoid gRPC at the beginning. JSON is easier to debug, easier to consume from Swift and web clients, and good enough for the first several phases.

Later, if stronger typing or high-throughput streaming becomes necessary, the protocol can evolve.

### API Shape

Use method-style endpoints or JSON-RPC-style calls.

Initial methods:

```text
core.ping
workspace.getState
workspace.openDirectory
workspace.listDirectory
workspace.revealPath
events.subscribe
```

Later methods:

```text
terminal.createSession
terminal.write
terminal.resize
terminal.close
search.query
search.indexWorkspace
git.status
task.run
task.cancel
```

Initial events:

```text
workspace.changed
directory.updated
file.changed
backend.ready
backend.error
```

Later events:

```text
terminal.output
terminal.exit
search.result
git.updated
task.output
task.finished
```

## 5. Development Phases

## Phase 0: Repository And Architecture Baseline

Goal: create a stable monorepo foundation and decide how clients launch/connect to the backend.

Status: completed as the initial baseline commit.

Built:

- Create repository structure.
- Create Rust backend under `core/`.
- Create macOS client under `clients/MacOS/`.
- Add protocol docs under `protocol/`.
- Add basic logging and error conventions.
- Add unified root Git repository.
- Add `core.ping` over local HTTP JSON RPC.
- Add macOS connectivity UI.
- Split macOS client into lightweight MVVM folders.
- Split Rust backend into lightweight API/controller/workspace/error/state modules.

Rust stack used:

```text
cargo
tokio
axum
serde
serde_json
tracing
thiserror
anyhow
```

macOS stack used:

```text
Swift
SwiftUI
URLSession
```

Deliverables:

- Rust backend can start locally on `127.0.0.1:3587`.
- Backend exposes `POST /rpc` with `core.ping`.
- Backend exposes `GET /health`.
- macOS client can connect to an already running backend.
- macOS client can call `core.ping` and display connection status.
- Protocol is documented in `protocol/README.md`.

Still deferred:

- macOS client launching the backend automatically.
- Production launch/port discovery flow.

Do not build yet:

- Real Finder UI
- Terminal
- Search
- Git
- File mutations

## Phase 1: Workspace And Directory Browsing

Goal: prove the core product loop: macOS client asks Rust backend for a directory, then renders it in native AppKit controls.

Status: first backend-to-client directory browsing slice completed. Full Finder-like Phase 1 is still in progress.

First slice:

- Add `workspace.listDirectory`.
- Backend reads a requested directory using Rust filesystem APIs.
- Backend returns file metadata: name, path, kind, size, modified date, directory flag.
- macOS client sends a path to the backend.
- macOS client renders the returned entries in a simple list/table.
- Start with a default directory such as the user's home directory, or a path input.

First slice built:

- Rust `workspace.listDirectory` controller.
- Directory entry DTOs with name, path, kind, size, modified date, and directory flag.
- Directories sorted before files.
- Symlinked directories marked openable.
- API errors for invalid params, missing paths, permission failures, and non-directory paths.
- RPC logs with method, status, elapsed time, and compact response summaries.
- Filesystem listing isolated in a blocking task.
- Swift `BackendClient.listDirectory`.
- Swift RPC models for directory entries and RPC errors.
- `WorkspaceBrowserViewModel` with cancellable directory loads.
- Simple SwiftUI path field and list rendering.
- Default path fixed to the real user home instead of the sandbox container home.

Initial request shape:

```json
{
  "method": "workspace.listDirectory",
  "params": {
    "path": "/Users/mac"
  }
}
```

Initial response shape:

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

Full Phase 1 build:

- Backend workspace state.
- `workspace.getState`.
- `workspace.openDirectory`.
- `workspace.listDirectory`.
- Basic file metadata: name, path, kind, size, modified date, directory flag.
- macOS Finder-like main window.
- Sidebar with common locations.
- File list using `NSTableView`.
- Double-click folder to open.
- Double-click file to ask macOS to open with default app.

Implementation note:

The first slice may use SwiftUI `List` or `Table` to prove the backend-to-client data loop quickly. Move to AppKit `NSTableView` once the data shape and navigation behavior are stable.

Rust stack used:

```text
std::fs
tokio
tokio::task::spawn_blocking
serde
axum
tracing
ignore or walkdir, only if recursive walking is needed
```

macOS stack used:

```text
NSWindowController
NSSplitViewController
NSOutlineView
NSTableView
NSToolbar
NSWorkspace
```

Backend owns:

- Current workspace.
- Current directory.
- Directory listing result.

Client owns:

- Selection state.
- UI focus.
- Table sorting display state if it does not affect backend state.

Deliverables:

- Native macOS window resembling Finder.
- Sidebar selection loads file list through Rust backend.
- File list is populated by backend data, not Swift `FileManager`.
- Basic error UI for permission or missing directory.

Do not build yet:

- Delete/move/rename
- Real terminal
- File watching
- Search
- Git

## Phase 2: Events And File Watching

Goal: make the backend active instead of only request/response.

Build:

- WebSocket event channel.
- `events.subscribe`.
- Directory watcher for current directory.
- Refresh file list when files change.
- Backend emits `directory.updated`.
- Client updates visible file list without manual reload.

Rust stack used:

```text
notify
tokio broadcast/mpsc channels
axum WebSocket
serde
```

macOS stack used:

```text
URLSessionWebSocketTask
MainActor UI updates
NSTableView reload/diff updates
```

Deliverables:

- Create/delete/rename files externally and see the client update.
- Backend event logs are inspectable.
- Client reconnects if event connection drops.

Do not build yet:

- Heavy recursive indexing
- Full file operation history
- Multi-client conflict resolution

## Phase 3: Terminal Sessions

Goal: add the Slot-like execution layer: terminal sessions are backend resources bound to workspace/directories.

Build:

- `terminal.createSession`.
- `terminal.write`.
- `terminal.resize`.
- `terminal.close`.
- `terminal.output` event.
- Terminal cwd follows selected/opened directory when configured.
- macOS terminal panel at bottom of the Finder-like window.

Rust stack used:

```text
portable-pty
tokio task management
uuid
axum WebSocket events
```

macOS stack used:

```text
SwiftTerm
NSSplitViewController
keyboard event forwarding
MainActor event rendering
```

Backend owns:

- PTY process.
- Terminal session lifecycle.
- Terminal cwd.
- Output stream.

Client owns:

- Terminal view rendering.
- Keyboard focus.
- Panel size and visibility.

Deliverables:

- Open terminal in current directory.
- Type commands and receive output.
- Resize terminal panel and propagate PTY size.
- Close session cleanly.

Do not build yet:

- Multiple terminal tabs unless single-session UX is stable.
- Task runner abstraction.
- Remote terminal support.

## Phase 4: File Operations

Goal: support practical file management while keeping destructive actions safe.

Build:

- Rename.
- Create folder.
- Create file.
- Move to trash.
- Copy path.
- Reveal in system file manager.
- Context menus.
- Keyboard shortcuts matching Finder where appropriate.

Rust stack used:

```text
std::fs
trash
thiserror
serde
notify
```

macOS stack used:

```text
NSMenu
NSTableView editing
NSPasteboard
NSWorkspace
keyboard shortcuts
```

Deliverables:

- Common Finder-like actions work.
- Delete means move to trash, not permanent delete.
- Backend sends file operation result and updated directory events.

Do not build yet:

- Complex drag/drop between remote clients.
- Batch operation progress UI, unless needed.

## Phase 5: Search And Indexing

Goal: move from browsing files to finding and acting on workspace contents.

Build:

- Fast filename search.
- Optional content search.
- Workspace index database.
- Respect `.gitignore`.
- Search result streaming.
- Search UI in macOS toolbar.

Rust stack used:

```text
ignore
walkdir
tantivy
SQLite
tokio
```

macOS stack used:

```text
NSSearchField
NSTableView result mode
keyboard navigation
```

Deliverables:

- Search files by name.
- Open result location.
- Search results stream progressively for large workspaces.

Do not build yet:

- Cloud sync
- Global machine-wide indexing

## Phase 6: Git And Project Awareness

Goal: make the app understand developer workspaces.

Build:

- Detect git repository.
- Show branch.
- Show file status.
- Basic changed files panel.
- Optional terminal shortcuts for common git commands.

Rust stack used:

```text
gix or git2
notify
tokio
```

macOS stack used:

```text
NSTableView cell styling
sidebar badges
toolbar status item
```

Deliverables:

- Current repository status appears in UI.
- Changed files are marked in file list.
- Git status updates when files change.

Do not build yet:

- Full graphical git client.
- Merge conflict editor.

## Phase 7: Command Palette And Tasks

Goal: turn the product into a workspace action surface.

Build:

- Command palette.
- Backend command registry.
- Task detection from project files.
- Run/cancel task.
- Stream task output.

Rust stack used:

```text
tokio process
serde
uuid
event bus
```

macOS stack used:

```text
custom command palette window/panel
keyboard shortcuts
NSTableView or custom list view
```

Deliverables:

- Open command palette with keyboard shortcut.
- Run detected project commands.
- See output in terminal/task panel.

Do not build yet:

- Public plugin API
- Remote execution

## Phase 8: Multi-Client And Web Preparation

Goal: ensure the backend can support non-macOS clients.

Build:

- Stable protocol docs.
- Shared API schema.
- Web client prototype.
- Authentication/token for local web access.
- Client capability negotiation.

Rust stack used:

```text
axum
WebSocket
serde
OpenAPI/JSON schema tooling if useful
```

Web stack used:

```text
TypeScript
React or Svelte
xterm.js
WebSocket
```

Deliverables:

- Minimal web client can connect to the same backend.
- Web client can list directory and open terminal.
- API docs are good enough for another client implementation.

Do not build yet:

- Hosted cloud backend.
- Account system.

## Phase 9: Windows And Linux Clients

Goal: validate that the architecture is truly client-adaptable.

Build:

- Decide native shell strategy.
- Package Rust backend with each desktop client.
- Implement platform-specific file opening, trash, and shell defaults.

Recommended first approach:

```text
Tauri shell
shared TypeScript UI
xterm.js
same backend API
```

Deliverables:

- Windows client can browse files and open terminal.
- Linux client can browse files and open terminal.
- Backend differences are isolated behind Rust platform modules.

## Phase 10: Plugin And Automation System

Goal: make the product extensible.

Build:

- Backend plugin model.
- Command contribution points.
- Workspace hooks.
- Sandboxing model.
- Permission model.

Possible stack:

```text
WASM plugins
JSON manifest
capability permissions
event subscriptions
```

Deliverables:

- A plugin can add commands.
- A plugin can react to workspace events.
- Plugin permissions are explicit.

Do not build early:

- Marketplace
- Untrusted plugin execution without a permission model

## 6. First Milestone Definition

The first useful milestone should be:

```text
Rust backend starts.
macOS AppKit client starts.
Client connects to backend.
Sidebar has Home/Desktop/Downloads/Documents.
Clicking a sidebar item calls backend.
Backend returns directory entries.
NSTableView renders entries.
Double-click folder opens folder.
Bottom terminal panel exists as a placeholder showing current cwd.
```

This proves the architecture without getting trapped in terminal complexity too early.

## 7. Engineering Rules

- Backend is the source of truth for workspace state.
- Clients render state and send user intentions.
- File mutations go through backend APIs.
- Terminal lifecycle belongs to backend.
- Events are first-class; do not rely only on polling.
- Keep protocol simple and inspectable early.
- Do not add search, git, plugins, or AI features before file browsing and terminal are stable.
- macOS should feel native, not like a web app.
- Future clients should not require rewriting core behavior.

## 8. Recommended Immediate Next Steps

1. Add backend launch and port-discovery flow from the macOS client.
2. Add `workspace.getState` and `workspace.openDirectory` so the backend owns current workspace state instead of only listing arbitrary paths.
3. Replace the current SwiftUI proof-of-flow with a Finder-like AppKit shell: sidebar, toolbar, and `NSTableView`.
4. Add sidebar locations for Home, Desktop, Downloads, and Documents.
5. Add file open/reveal actions through backend-approved commands and macOS `NSWorkspace`.
6. Add a placeholder terminal panel bound to the current backend cwd.
7. Add event transport planning for Phase 2 before implementing file watching.
