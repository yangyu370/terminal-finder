# Windows terminal implementation — 2026-10-18

Scope: native Windows local workspace, PowerShell 7 + PSReadLine 2.2+, portable-pty ConPTY, existing HTTP/WS and FFI DTOs unchanged. Keep macOS zsh implementation and its tests. No S3/UI feature expansion.

Design: core owns shell lifecycle and independent per-session control-file queue. Requests contain data, not shell code. PowerShell applies the newest request only from prompt/empty-buffer OnIdle, emits local-authority OSC7, and never injects commands into foreground stdin. Idle redraw goes through PSReadLine. Drive and UNC paths are decoded consistently at FFI/WS boundaries without accepting remote shell authorities. The UI marks Synced only after validated observed cwd.

Implementation sequence:
1. Add tested Windows URL/native path conversion and split platform shell integration.
2. Add immutable sequenced JSON control requests, PowerShell bootstrap, native shell command configuration and Windows hostname support.
3. Make client resource layout and test fixtures portable; add Windows-native launch/build/test scripts and real terminal integration tests.
4. Run macOS Rust fmt/tests/clippy, refresh static FFI artifacts, client race/real PTY tests, and macOS client checks. Cross-build Go Windows target.
5. Add Windows CI for native Rust compilation, real PowerShell/ConPTY, Ghostty rendering and stdin isolation; read actual results and fix failures. Mark unverified GUI/physical-device coverage explicitly.
6. Update handoff/protocol/README with requirements and actual evidence; review and push to the existing experiment branch.

Acceptance: UI→PowerShell cwd and PowerShell→UI; Unicode/spaces/quotes; rapid navigation/old reports; failed navigation keeps listing; busy stdin receives only user input and pending navigation applies after it ends; valid resize, session exit/disconnect cleanup; existing macOS zsh regression passes. No claim of Windows closure from cross-compilation alone.

Verified 2026-10-18: Windows x64 [native CI](https://github.com/yangyu370/terminal-finder/actions/runs/39114335844) passed on c09471f, including C/D drive switching, actual PS/native child cwd, Unicode, Ctrl+C, stdin isolation, shell-side failure/recovery, resize and process exit. Five Windows Rust contract tests and Go vet/all packages passed. macOS Rust209 tests/clippy, refreshed static FFI artifacts (unchanged interface), and MyGo race/real PTY regression passed. Xcode tests remain blocked by the host's unaccepted license. Physical desktop/IME/DPI, real UNC server, and Windows ARM64 remain outside this native x64 CI evidence.
