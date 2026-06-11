//
//  FinderListFormatters.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import Foundation
import UniformTypeIdentifiers

/// Pure presentation formatting for the directory list columns.
/// Display text only; never a source of product facts.
enum FinderListFormatters {
    static let placeholderText = "--"

    static func displayName(for entry: DirectoryEntry) -> String {
        if let localizedName = localizedFinderName(for: entry.name) {
            return localizedName
        }

        let displayName = FileManager.default.displayName(atPath: entry.path)
        return displayName.isEmpty ? entry.name : displayName
    }

    private static func localizedFinderName(for name: String) -> String? {
        switch name {
        case "Desktop":
            return "桌面"
        case "Documents":
            return "文稿"
        case "Downloads":
            return "下载"
        case "Movies":
            return "影片"
        case "Music":
            return "音乐"
        case "Pictures":
            return "图片"
        case "Public":
            return "公共"
        case "Virtual Machines.localized":
            return "虚拟机"
        default:
            return nil
        }
    }

    // MARK: Date

    private static let isoFormatterWithFractionalSeconds: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let finderLocale = Locale(identifier: "zh_CN")

    private static let defaultDateDisplayFormatter = makeDateDisplayFormatter(
        locale: finderLocale,
        timeZone: .autoupdatingCurrent
    )

    private static func makeDateDisplayFormatter(locale: Locale, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }

    /// Parses backend `modifiedAt` strings (ISO8601 with or without fractional seconds).
    static func parseModifiedDate(_ isoString: String?) -> Date? {
        guard let isoString, !isoString.isEmpty else {
            return nil
        }

        return isoFormatterWithFractionalSeconds.date(from: isoString)
            ?? isoFormatter.date(from: isoString)
    }

    /// "修改日期" column text. Follows the system locale/time zone by default;
    /// tests may inject a fixed locale/time zone.
    static func dateDisplayText(
        isoString: String?,
        locale: Locale? = nil,
        timeZone: TimeZone? = nil
    ) -> String {
        guard let date = parseModifiedDate(isoString) else {
            return placeholderText
        }

        if locale == nil, timeZone == nil {
            return defaultDateDisplayFormatter.string(from: date)
        }

        let formatter = makeDateDisplayFormatter(
            locale: locale ?? finderLocale,
            timeZone: timeZone ?? .autoupdatingCurrent
        )
        return formatter.string(from: date)
    }

    // MARK: Size

    private static let byteCountFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter
    }()

    /// "大小" column text. Directories and unknown sizes render as `--`.
    static func sizeDisplayText(isDirectory: Bool, size: UInt64?) -> String {
        guard !isDirectory, let size else {
            return placeholderText
        }

        return byteCountFormatter.string(fromByteCount: Int64(clamping: size))
    }

    // MARK: Kind

    /// "种类" column text derived from the entry kind and filename extension.
    /// Display-only mapping; not reported back to the backend.
    static func kindDisplayText(name: String, kind: EntryKind, isDirectory: Bool) -> String {
        if kind == .symlink {
            return "替身"
        }

        if isDirectory || kind == .directory {
            return "文件夹"
        }

        let fileExtension = (name as NSString).pathExtension
        switch fileExtension.lowercased() {
        case "txt", "text":
            return "纯文本文稿"
        case "json":
            return "JSON"
        case "md", "markdown":
            return "Markdown 文稿"
        case "pdf":
            return "PDF 文稿"
        case "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "bmp":
            return "图像"
        default:
            break
        }

        if !fileExtension.isEmpty,
           let type = UTType(filenameExtension: fileExtension),
           let description = type.localizedDescription,
           !description.isEmpty {
            return description
        }

        return "文稿"
    }

    /// Convenience overload for a directory entry.
    static func kindDisplayText(for entry: DirectoryEntry) -> String {
        kindDisplayText(name: entry.name, kind: entry.kind, isDirectory: entry.isDirectory)
    }
}
