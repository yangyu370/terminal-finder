//
//  WindowsXPIconProvider.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  Self-drawn XP-flavored icons (no Microsoft assets). Glossier and more
//  saturated than the flatter Win98 set: manila-gold folders with a highlight
//  strip, blue title-bar documents.

import AppKit

enum WindowsXPIconKind: Equatable {
    case folder
    case file
    case symlink
    case other
    case desktop
    case downloads
    case documents
    case home
    case drive
}

struct WindowsXPIconProvider {
    let size: NSSize

    init(size: NSSize = NSSize(width: 16, height: 16)) {
        self.size = size
    }

    func icon(for entry: DirectoryEntry) -> NSImage {
        makeImage(kind: iconKind(for: entry))
    }

    /// Draw an icon for an explicit kind (e.g. the address-bar folder glyph).
    func icon(kind: WindowsXPIconKind) -> NSImage {
        makeImage(kind: kind)
    }

    func iconKind(for entry: DirectoryEntry) -> WindowsXPIconKind {
        if entry.isDirectory || entry.kind == .directory {
            return .folder
        }

        switch entry.kind {
        case .directory:
            return .folder
        case .file:
            return .file
        case .symlink:
            return .symlink
        case .other:
            return .other
        }
    }

    func sidebarIcon(for item: FinderSidebarItem) -> NSImage {
        makeImage(kind: sidebarIconKind(for: item))
    }

    func sidebarIconKind(for item: FinderSidebarItem) -> WindowsXPIconKind {
        switch item.id {
        case "favorites.desktop":
            return .desktop
        case "favorites.downloads":
            return .downloads
        case "favorites.documents":
            return .documents
        case "locations.home":
            return .home
        case let id where id.hasPrefix("locations."):
            return .drive
        default:
            return .folder
        }
    }

    private func makeImage(kind: WindowsXPIconKind) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            let painter = WindowsXPIconPainter(rect: rect)

            switch kind {
            case .folder:
                painter.drawFolder()
            case .file:
                painter.drawFile(accent: WindowsXPIconColors.fileBlue)
            case .symlink:
                painter.drawFile(accent: WindowsXPIconColors.fileGreen)
                painter.drawShortcutBadge()
            case .other:
                painter.drawOther()
            case .desktop:
                painter.drawDesktop()
            case .downloads:
                painter.drawFolder()
                painter.drawDownArrow()
            case .documents:
                painter.drawFile(accent: WindowsXPIconColors.fileBlue)
            case .home:
                painter.drawHome()
            case .drive:
                painter.drawDrive()
            }

            return true
        }
    }
}

private enum WindowsXPIconColors {
    static let outline = NSColor(calibratedRed: 0.32, green: 0.24, blue: 0.05, alpha: 1)
    static let white = NSColor.white
    static let shadow = NSColor(calibratedWhite: 0.55, alpha: 1)
    static let surface = NSColor(calibratedRed: 0.86, green: 0.86, blue: 0.80, alpha: 1)
    static let gold = NSColor(calibratedRed: 0.97, green: 0.78, blue: 0.30, alpha: 1)
    static let goldLight = NSColor(calibratedRed: 1.0, green: 0.92, blue: 0.62, alpha: 1)
    static let goldDark = NSColor(calibratedRed: 0.78, green: 0.55, blue: 0.10, alpha: 1)
    static let fileBlue = NSColor(calibratedRed: 0.16, green: 0.42, blue: 0.78, alpha: 1)
    static let fileBlueDark = NSColor(calibratedRed: 0.05, green: 0.24, blue: 0.55, alpha: 1)
    static let fileGreen = NSColor(calibratedRed: 0.16, green: 0.55, blue: 0.22, alpha: 1)
    static let lunaBlue = NSColor(calibratedRed: 0.0, green: 0.33, blue: 0.78, alpha: 1)
    static let lunaBlueDark = NSColor(calibratedRed: 0.0, green: 0.14, blue: 0.42, alpha: 1)
}

private struct WindowsXPIconPainter {
    let rect: NSRect

    private var scaleX: CGFloat { rect.width / 16 }
    private var scaleY: CGFloat { rect.height / 16 }

    func drawFolder() {
        fill(WindowsXPIconColors.outline, x: 1, y: 3, width: 14, height: 11)
        fill(WindowsXPIconColors.goldDark, x: 2, y: 4, width: 12, height: 9)
        fill(WindowsXPIconColors.goldLight, x: 2, y: 11, width: 5, height: 2)
        fill(WindowsXPIconColors.gold, x: 2, y: 5, width: 12, height: 7)
        // Glossy highlight strip (the XP touch).
        fill(WindowsXPIconColors.goldLight, x: 3, y: 10, width: 10, height: 1)
        fill(WindowsXPIconColors.goldLight, x: 3, y: 8, width: 8, height: 1)
        fill(WindowsXPIconColors.white, x: 3, y: 11, width: 4, height: 1)
        fill(WindowsXPIconColors.goldDark, x: 3, y: 5, width: 10, height: 1)
    }

    func drawFile(accent: NSColor) {
        fill(WindowsXPIconColors.outline, x: 3, y: 1, width: 10, height: 14)
        fill(WindowsXPIconColors.white, x: 4, y: 2, width: 8, height: 12)
        // Folded corner.
        fill(NSColor(calibratedWhite: 0.84, alpha: 1), x: 9, y: 11, width: 3, height: 3)
        fill(WindowsXPIconColors.outline, x: 9, y: 14, width: 4, height: 1)
        fill(WindowsXPIconColors.outline, x: 12, y: 11, width: 1, height: 4)
        // Blue title bar + text lines (XP document look).
        fill(accent, x: 4, y: 11, width: 8, height: 2)
        fill(WindowsXPIconColors.shadow, x: 5, y: 8, width: 5, height: 1)
        fill(WindowsXPIconColors.shadow, x: 5, y: 6, width: 4, height: 1)
        fill(WindowsXPIconColors.shadow, x: 5, y: 4, width: 5, height: 1)
    }

    func drawShortcutBadge() {
        fill(WindowsXPIconColors.white, x: 1, y: 1, width: 7, height: 6)
        fill(WindowsXPIconColors.outline, x: 2, y: 2, width: 5, height: 4)
        fill(WindowsXPIconColors.white, x: 3, y: 3, width: 3, height: 2)
        fill(WindowsXPIconColors.lunaBlue, x: 1, y: 4, width: 5, height: 1)
        fill(WindowsXPIconColors.lunaBlue, x: 2, y: 5, width: 1, height: 1)
    }

    func drawOther() {
        fill(WindowsXPIconColors.outline, x: 4, y: 2, width: 8, height: 12)
        fill(WindowsXPIconColors.surface, x: 5, y: 3, width: 6, height: 10)
        fill(WindowsXPIconColors.white, x: 6, y: 10, width: 4, height: 2)
        fill(WindowsXPIconColors.shadow, x: 6, y: 6, width: 4, height: 1)
        fill(WindowsXPIconColors.shadow, x: 6, y: 4, width: 3, height: 1)
    }

    func drawDesktop() {
        fill(WindowsXPIconColors.outline, x: 1, y: 4, width: 14, height: 9)
        fill(WindowsXPIconColors.lunaBlueDark, x: 2, y: 5, width: 12, height: 7)
        fill(WindowsXPIconColors.lunaBlue, x: 3, y: 6, width: 10, height: 5)
        fill(WindowsXPIconColors.goldLight, x: 4, y: 7, width: 4, height: 3)
        fill(WindowsXPIconColors.surface, x: 5, y: 2, width: 6, height: 2)
        fill(WindowsXPIconColors.outline, x: 4, y: 1, width: 8, height: 1)
    }

    func drawDownArrow() {
        fill(WindowsXPIconColors.lunaBlue, x: 7, y: 5, width: 2, height: 6)
        fill(WindowsXPIconColors.lunaBlue, x: 5, y: 5, width: 6, height: 2)
        fill(WindowsXPIconColors.lunaBlue, x: 6, y: 3, width: 4, height: 2)
        fill(WindowsXPIconColors.lunaBlue, x: 7, y: 2, width: 2, height: 1)
    }

    func drawHome() {
        fill(WindowsXPIconColors.outline, x: 2, y: 6, width: 12, height: 7)
        fill(WindowsXPIconColors.gold, x: 3, y: 6, width: 10, height: 6)
        fill(WindowsXPIconColors.outline, x: 4, y: 3, width: 8, height: 5)
        fill(NSColor(calibratedRed: 0.74, green: 0.16, blue: 0.16, alpha: 1), x: 5, y: 3, width: 6, height: 4)
        fill(WindowsXPIconColors.white, x: 7, y: 8, width: 2, height: 4)
        fill(WindowsXPIconColors.lunaBlue, x: 4, y: 10, width: 2, height: 2)
    }

    func drawDrive() {
        fill(WindowsXPIconColors.outline, x: 2, y: 4, width: 12, height: 8)
        fill(WindowsXPIconColors.surface, x: 3, y: 5, width: 10, height: 6)
        fill(WindowsXPIconColors.white, x: 3, y: 10, width: 10, height: 1)
        fill(WindowsXPIconColors.white, x: 4, y: 9, width: 8, height: 1)
        fill(WindowsXPIconColors.lunaBlue, x: 4, y: 6, width: 8, height: 1)
        fill(WindowsXPIconColors.fileGreen, x: 10, y: 5, width: 2, height: 1)
    }

    private func fill(_ color: NSColor, x: CGFloat, y: CGFloat, width: CGFloat, height: CGFloat) {
        color.setFill()
        NSRect(
            x: rect.minX + x * scaleX,
            y: rect.minY + y * scaleY,
            width: width * scaleX,
            height: height * scaleY
        ).fill()
    }
}
