//
//  Windows98IconProvider.swift
//  MacOS
//
//  Created by Codex on 2026/6/14.
//

import AppKit

enum Windows98IconKind: Equatable {
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

struct Windows98IconProvider {
    let size: NSSize

    init(size: NSSize = NSSize(width: 16, height: 16)) {
        self.size = size
    }

    func icon(for entry: DirectoryEntry) -> NSImage {
        makeImage(kind: iconKind(for: entry))
    }

    func iconKind(for entry: DirectoryEntry) -> Windows98IconKind {
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

    func sidebarIconKind(for item: FinderSidebarItem) -> Windows98IconKind {
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

    private func makeImage(kind: Windows98IconKind) -> NSImage {
        NSImage(size: size, flipped: false) { rect in
            NSGraphicsContext.current?.imageInterpolation = .none
            let painter = Windows98IconPainter(rect: rect)

            switch kind {
            case .folder:
                painter.drawFolder()
            case .file:
                painter.drawFile(accent: Windows98IconColors.fileBlue)
            case .symlink:
                painter.drawFile(accent: Windows98IconColors.fileGreen)
                painter.drawShortcutBadge()
            case .other:
                painter.drawOther()
            case .desktop:
                painter.drawDesktop()
            case .downloads:
                painter.drawFolder()
                painter.drawDownArrow()
            case .documents:
                painter.drawFile(accent: Windows98IconColors.fileBlue)
            case .home:
                painter.drawHome()
            case .drive:
                painter.drawDrive()
            }

            return true
        }
    }
}

private enum Windows98IconColors {
    static let black = NSColor.black
    static let white = NSColor.white
    static let shadow = NSColor(calibratedWhite: 0.45, alpha: 1)
    static let surface = NSColor(calibratedWhite: 0.75, alpha: 1)
    static let yellow = NSColor(calibratedRed: 1.0, green: 0.82, blue: 0.22, alpha: 1)
    static let yellowLight = NSColor(calibratedRed: 1.0, green: 0.94, blue: 0.58, alpha: 1)
    static let yellowDark = NSColor(calibratedRed: 0.68, green: 0.45, blue: 0.0, alpha: 1)
    static let fileBlue = NSColor(calibratedRed: 0.0, green: 0.2, blue: 0.72, alpha: 1)
    static let fileGreen = NSColor(calibratedRed: 0.0, green: 0.45, blue: 0.15, alpha: 1)
    static let titleBlue = NSColor(calibratedRed: 0.0, green: 0.0, blue: 0.5, alpha: 1)
}

private struct Windows98IconPainter {
    let rect: NSRect

    private var scaleX: CGFloat {
        rect.width / 16
    }

    private var scaleY: CGFloat {
        rect.height / 16
    }

    func drawFolder() {
        fill(Windows98IconColors.black, x: 1, y: 3, width: 14, height: 11)
        fill(Windows98IconColors.yellowDark, x: 2, y: 4, width: 12, height: 9)
        fill(Windows98IconColors.yellowLight, x: 2, y: 11, width: 5, height: 2)
        fill(Windows98IconColors.yellow, x: 2, y: 5, width: 12, height: 7)
        fill(Windows98IconColors.yellowLight, x: 3, y: 10, width: 10, height: 1)
        fill(Windows98IconColors.white, x: 3, y: 11, width: 3, height: 1)
        fill(Windows98IconColors.shadow, x: 3, y: 4, width: 10, height: 1)
    }

    func drawFile(accent: NSColor) {
        fill(Windows98IconColors.black, x: 3, y: 1, width: 10, height: 14)
        fill(Windows98IconColors.white, x: 4, y: 2, width: 8, height: 12)
        fill(NSColor(calibratedWhite: 0.86, alpha: 1), x: 9, y: 11, width: 3, height: 3)
        fill(Windows98IconColors.black, x: 9, y: 14, width: 4, height: 1)
        fill(Windows98IconColors.black, x: 12, y: 11, width: 1, height: 4)
        fill(accent, x: 5, y: 8, width: 5, height: 1)
        fill(accent, x: 5, y: 6, width: 4, height: 1)
        fill(NSColor(calibratedRed: 0.8, green: 0.0, blue: 0.0, alpha: 1), x: 5, y: 4, width: 2, height: 2)
    }

    func drawShortcutBadge() {
        fill(Windows98IconColors.white, x: 1, y: 1, width: 7, height: 6)
        fill(Windows98IconColors.black, x: 2, y: 2, width: 5, height: 4)
        fill(Windows98IconColors.white, x: 3, y: 3, width: 3, height: 2)
        fill(Windows98IconColors.titleBlue, x: 1, y: 4, width: 5, height: 1)
        fill(Windows98IconColors.titleBlue, x: 2, y: 5, width: 1, height: 1)
    }

    func drawOther() {
        fill(Windows98IconColors.black, x: 4, y: 2, width: 8, height: 12)
        fill(Windows98IconColors.surface, x: 5, y: 3, width: 6, height: 10)
        fill(Windows98IconColors.white, x: 6, y: 10, width: 4, height: 2)
        fill(Windows98IconColors.shadow, x: 6, y: 6, width: 4, height: 1)
        fill(Windows98IconColors.shadow, x: 6, y: 4, width: 3, height: 1)
    }

    func drawDesktop() {
        fill(Windows98IconColors.black, x: 1, y: 4, width: 14, height: 9)
        fill(Windows98IconColors.titleBlue, x: 2, y: 5, width: 12, height: 7)
        fill(NSColor(calibratedRed: 0.1, green: 0.55, blue: 0.6, alpha: 1), x: 3, y: 6, width: 10, height: 5)
        fill(Windows98IconColors.surface, x: 5, y: 2, width: 6, height: 2)
        fill(Windows98IconColors.black, x: 4, y: 1, width: 8, height: 1)
    }

    func drawDownArrow() {
        fill(Windows98IconColors.titleBlue, x: 7, y: 5, width: 2, height: 6)
        fill(Windows98IconColors.titleBlue, x: 5, y: 5, width: 6, height: 2)
        fill(Windows98IconColors.titleBlue, x: 6, y: 3, width: 4, height: 2)
        fill(Windows98IconColors.titleBlue, x: 7, y: 2, width: 2, height: 1)
    }

    func drawHome() {
        fill(Windows98IconColors.black, x: 2, y: 6, width: 12, height: 7)
        fill(Windows98IconColors.yellow, x: 3, y: 6, width: 10, height: 6)
        fill(Windows98IconColors.black, x: 4, y: 3, width: 8, height: 5)
        fill(NSColor(calibratedRed: 0.68, green: 0.0, blue: 0.0, alpha: 1), x: 5, y: 3, width: 6, height: 4)
        fill(Windows98IconColors.white, x: 7, y: 8, width: 2, height: 4)
        fill(Windows98IconColors.titleBlue, x: 4, y: 10, width: 2, height: 2)
    }

    func drawDrive() {
        fill(Windows98IconColors.black, x: 2, y: 4, width: 12, height: 8)
        fill(Windows98IconColors.surface, x: 3, y: 5, width: 10, height: 6)
        fill(Windows98IconColors.white, x: 4, y: 9, width: 8, height: 1)
        fill(Windows98IconColors.shadow, x: 4, y: 6, width: 8, height: 1)
        fill(Windows98IconColors.fileGreen, x: 10, y: 5, width: 2, height: 1)
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
