# Finder Display Method Styles Plan

## Goal

Implement the three remaining Finder display modes behind the existing toolbar display-method segmented control:

- Icon view
- Column view
- Gallery view

List view already exists and remains the default. Every mode must keep the existing bottom terminal panel available through the toolbar and menu actions. The work stays on top of the current AppKit Finder rebuild and does not change backend, terminal protocol, or workspace ViewModel semantics.

## Requirements Breakdown

- Create a branch from `master`: `codex/finder-display-method-styles`.
- Keep the Finder-style AppKit architecture:
  - `NSWindow` + unified `NSToolbar`
  - `NSSplitViewController` sidebar
  - AppKit-backed content views for the display modes
  - SwiftUI container only for composition and terminal panel placement
- Enable all four toolbar display segments:
  - Icon
  - List
  - Column
  - Gallery
- Share one display-mode state between toolbar and content.
- Preserve terminal access in every display mode by keeping the terminal panel in `FinderContentView`, below whichever browser surface is active.
- Add focused tests for display-mode state, toolbar/content wiring assumptions, and pure presentation helpers.
- Commit after each completed page style:
  1. Icon view
  2. Column view
  3. Gallery view

## AppKit Control Selection

| Mode | Primary Control | Reason |
| --- | --- | --- |
| Icon | `NSCollectionView` + `NSCollectionViewFlowLayout` | Matches Finder's icon grid behavior, selection, keyboard focus, and scrolling better than a SwiftUI grid. |
| List | Existing `NSOutlineView` | Already matches Finder list columns, inset selection, row height, sorting, and lazy directory expansion. |
| Column | Horizontally stacked `NSTableView` columns in an `NSScrollView` | Gives Finder-like multi-column navigation while keeping async `loadChildren(path:)` explicit and testable. `NSBrowser` is less suitable because backend child loading is async. |
| Gallery | `NSCollectionView` filmstrip plus AppKit preview panel | Mirrors Finder's large preview + bottom strip structure while keeping selected item and open behavior consistent. |

## File Architecture

- `FinderDisplayMode.swift`
  - `FinderDisplayMode`
  - `FinderDisplayModeState`
  - Toolbar segment indexes and labels
- `FinderDisplayItemCell.swift`
  - Shared AppKit collection/table cell helpers for icon, column, and gallery views
- `FinderIconGridView.swift`
  - Icon view `NSViewRepresentable`
- `FinderColumnView.swift`
  - Column browser `NSViewRepresentable`
- `FinderGalleryView.swift`
  - Gallery preview + filmstrip `NSViewRepresentable`
- `FinderContentView.swift`
  - Switches between display modes and keeps the terminal panel below the active surface
- `FinderToolbarController.swift`
  - Enables all display segments and routes selection to `FinderWindowController`
- `FinderWindowController.swift`
  - Owns `FinderDisplayModeState` and exposes `changeDisplayModeAction(_:)`
- `FinderDisplayMethodTests.swift`
  - Pure state and presentation tests

## UI Fidelity Notes

### Icon View

- Background: `.controlBackgroundColor`, no card framing.
- Grid: large 64 pt icons, Finder-like 112 x 108 item cells, centered labels, truncation by tail.
- Selection: rounded accent fill behind icon/label area through `NSCollectionView` selection.
- Double-click: opens directories/files via existing `WorkspaceBrowserViewModel.open(_:)`.

### Column View

- Background: Finder content background.
- Columns: fixed 220 pt widths, vertical separators, no headers, 24 pt rows.
- Row: 16 pt icon, 13 pt label, chevron on directories.
- Selection: single path selection routed back to existing VM.
- Directory selection: async child load appends/replaces the next column.

### Gallery View

- Large preview region with file icon, localized display name, kind, date, and size.
- Bottom filmstrip: horizontal `NSCollectionView`, small icons, selected item synced to VM.
- Open behavior: double-click/Return-like activation opens selected item through existing VM.

## Terminal Panel

Terminal behavior remains centralized in `FinderContentView` and `FinderWindowController`:

- Toolbar terminal item and menu shortcuts call `toggleTerminalPanelAction(_:)`.
- `FinderContentView` always renders:
  - active browser surface
  - optional resize handle
  - optional `FinderTerminalPanelView`
- The display-mode views do not own terminal state. This prevents each mode from duplicating terminal lifecycle logic.

## Testing Strategy

- Unit tests:
  - display mode index mapping
  - display mode state mutation
  - icon/column/gallery metric constants
  - existing formatter and sort tests remain green
- Build/test:
  - `xcodebuild test -project clients/MacOS/MacOS.xcodeproj -scheme MacOS -configuration Debug -destination 'platform=macOS' -derivedDataPath .derivedData/codex-display-methods CODE_SIGNING_ALLOWED=NO`
- Visual validation:
  - Capture Finder icon/column/gallery reference windows.
  - Launch app and capture each display mode.
  - Compare window chrome, sidebar, toolbar segment state, main panel layout, and terminal accessibility.

## Commit Plan

1. `Add Finder icon display mode`
   - display-mode state
   - toolbar segmented control wiring
   - icon grid view
   - plan doc and tests
2. `Add Finder column display mode`
   - column browser view
   - content switch integration
   - tests
3. `Add Finder gallery display mode`
   - gallery preview and filmstrip
   - final tests and screenshot verification
