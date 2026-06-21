import AppKit
import UniformTypeIdentifiers

/// Picks the right system icon for a `DirectoryEntry` regardless of whether
/// it lives on the local filesystem or on a remote provider (S3).
///
/// Local entries (path begins with `/`) go through `NSWorkspace.icon(forFile:)`
/// so we keep the rich app-specific glyphs (Xcode for .xcodeproj, Pages icon
/// for .pages, etc.).
///
/// Remote entries have relative paths (e.g. `gamma.txt`, `alpha/beta.txt`)
/// that don't exist on the local FS — `icon(forFile:)` would just return a
/// generic placeholder. For those we look up by `UTType` derived from the
/// filename extension (or `.folder` when `isDirectory`), so the user still
/// sees a typed icon ("text doc", "image", "folder") matching the local view.
enum FinderEntryIcon {
    static func image(for entry: DirectoryEntry) -> NSImage {
        let workspace = NSWorkspace.shared
        if entry.path.hasPrefix("/") {
            return workspace.icon(forFile: entry.path)
        }

        if entry.isDirectory {
            return workspace.icon(for: .folder)
        }

        let ext = (entry.name as NSString).pathExtension
        let type = UTType(filenameExtension: ext) ?? .data
        return workspace.icon(for: type)
    }
}
