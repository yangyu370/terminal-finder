//
//  FinderWriteOpDialogs.swift
//  MacOS
//

import AppKit

/// AppKit dialog helpers for the workspace write actions.
/// Returns `nil` on cancel; otherwise a trimmed name string (which the caller
/// must still validate for emptiness / illegal characters).
///
/// Implementation note: we deliberately use `NSAlert.runModal()` (app-modal,
/// centered on screen) rather than `beginSheetModal(for:)`. An earlier
/// attempt to fake a synchronous sheet by pairing `beginSheetModal` with
/// `NSApp.runModal(for: parentWindow)` produced the parent-window-as-modal
/// state where the sheet either never appeared or `stopModal` failed to
/// unblock the run loop — symptom: "新建文件夹" did nothing. Standalone
/// `runModal()` is the boring-but-bulletproof AppKit pattern.
@MainActor
enum FinderWriteOpDialogs {
    static func promptForName(
        window: NSWindow,
        title: String,
        informativeText: String,
        defaultName: String,
        confirmTitle: String
    ) -> String? {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = title
        alert.informativeText = informativeText
        alert.addButton(withTitle: confirmTitle)
        alert.addButton(withTitle: "取消")

        let inputField = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 22))
        inputField.stringValue = defaultName
        inputField.lineBreakMode = .byTruncatingTail
        inputField.usesSingleLineMode = true
        alert.accessoryView = inputField
        alert.window.initialFirstResponder = inputField

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        return inputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func confirm(
        window: NSWindow,
        title: String,
        informativeText: String,
        confirmTitle: String,
        confirmIsDestructive: Bool
    ) -> Bool {
        let alert = NSAlert()
        alert.alertStyle = confirmIsDestructive ? .warning : .informational
        alert.messageText = title
        alert.informativeText = informativeText
        let confirmButton = alert.addButton(withTitle: confirmTitle)
        if confirmIsDestructive {
            confirmButton.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "取消")

        return alert.runModal() == .alertFirstButtonReturn
    }

    static func moveConflictResolution(
        window: NSWindow,
        item: FinderDragItem,
        existingEntry: DirectoryEntry
    ) -> MoveConflictResolution {
        let alert = NSAlert()
        alert.alertStyle = existingEntry.isDirectory ? .warning : .informational
        alert.messageText = "“\(existingEntry.name)”已存在"
        if existingEntry.isDirectory {
            alert.informativeText = "目标位置已有同名文件夹。选择替换会先删除现有的“\(existingEntry.name)”及其中所有内容，再移动“\(item.name)”，且无法恢复。"
        } else {
            alert.informativeText = "目标位置已有同名项目。请选择替换现有项目、将“\(item.name)”保留为副本名称，或取消移动。"
        }

        let replaceButton = alert.addButton(withTitle: "替换")
        if existingEntry.isDirectory {
            replaceButton.hasDestructiveAction = true
        }
        alert.addButton(withTitle: "保留两者")
        alert.addButton(withTitle: "取消")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return .replace
        case .alertSecondButtonReturn:
            return .keepBoth
        default:
            return .cancel
        }
    }
}
