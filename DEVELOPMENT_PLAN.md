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

Use Swift and AppKit as the first native client.

Recommended stack:

```text
Swift
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

Build:

- Create repository structure.
- Create Rust workspace under `core/`.
- Create macOS AppKit project under `clients/macos/`.
- Add protocol docs under `protocol/`.
- Add basic logging and error conventions.
- Decide development launch flow.

Rust stack used:

```text
cargo workspace
tokio
axum
serde
tracing
thiserror
```

macOS stack used:

```text
Swift
AppKit
URLSession
```

Deliverables:

- Rust backend can start locally.
- Backend exposes `core.ping`.
- macOS client can launch the backend or connect to an already running backend.
- macOS client can call `core.ping` and display connection status.

Do not build yet:

- Real Finder UI
- Terminal
- Search
- Git
- File mutations

## Phase 1: Workspace And Directory Browsing

Goal: prove the core product loop: macOS client asks Rust backend for a directory, then renders it in native AppKit controls.

Build:

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

Rust stack used:

```text
std::fs
tokio
serde
axum
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

1. Create monorepo structure.
2. Scaffold Rust backend with `core.ping`.
3. Scaffold macOS AppKit client.
4. Implement backend launch/connect flow.
5. Implement `workspace.listDirectory`.
6. Render backend directory entries in `NSTableView`.
7. Add placeholder terminal panel showing current backend cwd.
