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

### Current Status As Of 2026-06-06

The project is between Phase 1 hardening and the first Phase 3 terminal slice. The basic backend/client browsing loop is in place, and the minimal WebSocket event lifecycle is now implemented, so the active plan focuses on finishing browsing hardening while starting PTY through a narrow backend-owned minimum loop.

Active:

- Finish Finder-like browsing polish: context menus, native table behavior, toolbar/sidebar refinement, and broader keyboard behavior.
- Revisit backend process lifecycle before distribution, especially packaging/signing, port discovery, and graceful shutdown semantics.
- Harden backend directory scanning so entry deletion races skip only `NotFound`, while permission and metadata failures still fail clearly.
- Add `RwLock` poison recovery and additional backend state concurrency coverage where state snapshots matter.
- Minimize path/params exposure in service and RPC info/warn logs.
- Start PTY as a minimum backend-owned loop: `terminal.create`, `terminal.output`, `terminal.input`, `terminal.resize`, `terminal.close`, and `terminal.exit`.

Deferred:

- File mutations such as delete, move, rename, and create.
- File watcher and automatic directory refresh from file system changes.
- Full terminal UX beyond a single-session PTY minimum loop.
- Search and indexing.
- Git awareness.

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

SwiftUI can remain useful for state-driven composition, but Finder-like browsing screens should use AppKit controls where native behavior matters, especially sidebar/file-table interactions.

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
WebSocket channels for backend events and future PTY streams
```

Avoid gRPC at the beginning. JSON is easier to debug, easier to consume from Swift and web clients, and good enough for the first several phases.

Later, if stronger typing or high-throughput streaming becomes necessary, the protocol can evolve.

### API Shape

Use method-style endpoints or JSON-RPC-style calls.

Current method contracts live in `protocol/README.md`.

Current method names:

```text
core.ping
workspace.getState
workspace.openDirectory
workspace.listDirectory
/events WebSocket channel for backend lifecycle events
/terminal WebSocket channel for terminal session messages
```

Later methods:

```text
terminal.create
terminal.input
terminal.resize
terminal.close
search.query
search.indexWorkspace
git.status
task.run
task.cancel
```

Initial `/events` messages:

```text
backend.ready
heartbeat
backend.error
```

Later `/events` messages:

```text
workspace.changed
directory.updated
file.changed
search.result
git.updated
task.output
task.finished
```

Planned `/terminal` messages:

```text
terminal.create
terminal.input
terminal.resize
terminal.close
terminal.created
terminal.output
terminal.resized
terminal.closed
terminal.exit
terminal.error
```

## 5. Development Phases

## Phase 0: Repository And Architecture Baseline

Goal: create a stable monorepo foundation and decide how clients launch/connect to the backend.

Status: closed. No active Phase 0 work remains in this plan.

## Phase 1: Workspace And Directory Browsing

Goal: prove the core product loop: macOS client asks Rust backend for a directory, then renders it in native AppKit controls.

Status: active. The remaining work is hardening and Finder-like polish, not another browsing-loop rebuild.

Remaining Phase 1 work:

- Directory scan should explicitly skip `NotFound` entry races and fail on permission or other metadata errors.
- Workspace state should recover from poisoned `RwLock` with warning logs.
- Service and RPC logs should avoid full paths and detailed params at info/warn level.
- Add backend tests for failed `openDirectory` preserving previous root/current once service-level test hooks exist.
- Refine Finder-like behavior: context menus, keyboard behavior, selection stability, and native table details.
- Revisit production launch details: signing, packaging, port discovery, and graceful shutdown verification.

Implementation note:

Keep AppKit where it materially improves Finder-like usage. SwiftUI can remain around state-driven composition and layout glue.

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

Remaining deliverables:

- Finder-like browsing refinements that close native behavior gaps.
- Hardened backend edge-case behavior for scanning, state recovery, and logging.
- Automated coverage for the remaining backend state and failure-path semantics.

Already implemented:

- Independent `/events` WebSocket route outside `/rpc`.
- `backend.ready` and heartbeat envelopes.
- Backend-side socket reads for close/error/eof detection and cleaner connection teardown.
- Heartbeat logs filtered from normal info noise.
- macOS event client, event connection status display, alert-based error reporting, and client heartbeat timeout detection for half-open streams.

Do not build yet:

- Delete/move/rename
- Full terminal UX beyond the PTY minimum loop
- File watching
- Search
- Git

## Phase 2: Events And File Watching

Goal: make the backend active instead of only request/response.

Status: partially complete. The minimal WebSocket event transport is implemented and usable for backend lifecycle events. Directory file watching and automatic list refresh remain future Phase 2 work.

Already built:

- WebSocket event channel.
- `backend.ready` and heartbeat events.
- Backend event logs are inspectable without heartbeat noise.
- Client detects dropped event connections and missing heartbeats.

Still build:

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
- File watcher events reuse the existing event transport without changing `/events` into PTY or high-volume `terminal.output` traffic.

Do not build yet:

- Heavy recursive indexing
- Full file operation history
- Multi-client conflict resolution

## Phase 3: Terminal Sessions

Goal: add the Slot-like execution layer through a narrow PTY minimum loop. Terminal sessions are backend resources bound to workspace/directories.

Build first:

- `terminal.create`.
- A PTY-specific `/terminal` WebSocket/session channel, separate from `/events`.
- `terminal.input`.
- `terminal.output`.
- `terminal.close`.
- `terminal.resize`.
- `terminal.exit`.
- Terminal cwd follows selected/opened directory when configured.
- Connect the existing macOS bottom panel to real backend terminal sessions.

Rust stack used:

```text
portable-pty
tokio task management
uuid
axum WebSocket
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

Minimum acceptance:

- PTY traffic does not use `/events`.
- Backend owns session registry, shell process, PTY IO, resize, exit state, and cleanup.
- Client owns only input forwarding, output rendering, viewport/rows/cols measurement, focus, and alert/status presentation.
- Dropped PTY channels and missing heartbeats have explicit cleanup/timeout behavior.

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

## 6. Next Milestone Definition

The next useful milestone should be:

```text
Phase 1 hardening is complete and PTY minimum loop is ready to start.
Directory scan races are handled intentionally.
Workspace state survives lock poisoning with warning logs.
Info/warn logs avoid full paths and request params.
Failed openDirectory paths preserve previous backend state.
Finder-like table, sidebar, toolbar, context menu, and keyboard behavior feel coherent.
The `/events` lifecycle channel remains stable and separate from future PTY traffic.
The PTY boundary is defined as backend session/process ownership plus a dedicated channel.
```

This closes the remaining browsing hardening while keeping the next terminal step narrow and backend-owned.

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

1. Harden backend directory scanning around `NotFound`, permission, and metadata errors.
2. Add `RwLock` poison recovery for workspace state and cover it with Rust tests.
3. Minimize full paths and request params in service/RPC info and warn logs.
4. Add service-level coverage for failed `openDirectory` preserving previous root/current.
5. Refine Finder-like context menus, keyboard behavior, and native table interactions.
6. Define the PTY minimum-loop protocol and backend ownership model before writing client UI glue.
7. Implement backend PTY `terminal.create` / `terminal.input` / `terminal.output` / `terminal.resize` / `terminal.close` / `terminal.exit` with cleanup tests.
8. Connect the macOS pseudo-terminal panel to the PTY channel only after the backend loop is testable.
9. Revisit production backend launch details: signing, packaging, port discovery, and graceful shutdown verification.
