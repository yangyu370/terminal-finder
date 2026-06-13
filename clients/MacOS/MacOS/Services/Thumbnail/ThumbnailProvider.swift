//
//  ThumbnailProvider.swift
//  MacOS
//
//  Created by Codex on 2026/6/13.
//

import AppKit
import QuickLookThumbnailing
import UniformTypeIdentifiers

protocol ThumbnailRequestToken: AnyObject {
    func cancel()
}

protocol ThumbnailProviding: AnyObject {
    func cachedThumbnail(for descriptor: ThumbnailDescriptor) -> NSImage?

    @discardableResult
    func thumbnail(
        for descriptor: ThumbnailDescriptor,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailRequestToken
}

enum ThumbnailPurpose: String, Hashable {
    case galleryPreview
    case columnPreview
}

struct ThumbnailDescriptor: Hashable {
    let path: String
    let modifiedAt: String?
    let size: UInt64?
    let pointSize: CGSize
    let scale: CGFloat
    let purpose: ThumbnailPurpose

    init(
        path: String,
        modifiedAt: String?,
        size: UInt64?,
        pointSize: CGSize,
        scale: CGFloat,
        purpose: ThumbnailPurpose
    ) {
        self.path = path
        self.modifiedAt = modifiedAt
        self.size = size
        self.pointSize = pointSize
        self.scale = scale
        self.purpose = purpose
    }

    init(entry: DirectoryEntry, pointSize: CGSize, scale: CGFloat, purpose: ThumbnailPurpose) {
        self.init(
            path: entry.path,
            modifiedAt: entry.modifiedAt,
            size: entry.size,
            pointSize: pointSize,
            scale: scale,
            purpose: purpose
        )
    }

    static func == (lhs: ThumbnailDescriptor, rhs: ThumbnailDescriptor) -> Bool {
        lhs.path == rhs.path
            && lhs.modifiedAt == rhs.modifiedAt
            && lhs.size == rhs.size
            && lhs.roundedPointWidth == rhs.roundedPointWidth
            && lhs.roundedPointHeight == rhs.roundedPointHeight
            && lhs.roundedScale == rhs.roundedScale
            && lhs.purpose == rhs.purpose
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(path)
        hasher.combine(modifiedAt)
        hasher.combine(size)
        hasher.combine(roundedPointWidth)
        hasher.combine(roundedPointHeight)
        hasher.combine(roundedScale)
        hasher.combine(purpose)
    }

    var cacheKey: String {
        [
            path,
            modifiedAt ?? "",
            size.map(String.init) ?? "",
            "\(roundedPointWidth)x\(roundedPointHeight)",
            "\(roundedScale)",
            purpose.rawValue
        ].joined(separator: "\u{1F}")
    }

    private var roundedPointWidth: Int {
        max(1, Int(pointSize.width.rounded()))
    }

    private var roundedPointHeight: Int {
        max(1, Int(pointSize.height.rounded()))
    }

    private var roundedScale: Int {
        max(1, Int((scale * 100).rounded()))
    }
}

enum ThumbnailProviders {
    static let shared: ThumbnailProviding = QuickLookThumbnailProvider()
}

final class QuickLookThumbnailProvider: ThumbnailProviding {
    typealias Generator = (ThumbnailDescriptor, @escaping (NSImage?) -> Void) -> ThumbnailGenerationToken

    private let cache = NSCache<NSString, NSImage>()
    private let generator: Generator
    private var inFlightRequests: [ThumbnailDescriptor: InFlightRequest] = [:]

    init(generator: Generator? = nil) {
        self.generator = generator ?? Self.quickLookGenerator
        cache.countLimit = 128
    }

    func cachedThumbnail(for descriptor: ThumbnailDescriptor) -> NSImage? {
        cache.object(forKey: descriptor.cacheKey as NSString)
    }

    @discardableResult
    func thumbnail(
        for descriptor: ThumbnailDescriptor,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailRequestToken {
        if let image = cachedThumbnail(for: descriptor) {
            let token = ThumbnailCallbackToken()
            DispatchQueue.main.async { [weak token] in
                guard token?.isCancelled == false else {
                    return
                }
                completion(image)
            }
            return token
        }

        let callbackID = UUID()
        if var inFlight = inFlightRequests[descriptor] {
            inFlight.completions[callbackID] = completion
            inFlightRequests[descriptor] = inFlight
            return ThumbnailCallbackToken { [weak self] in
                self?.cancelCallback(callbackID, for: descriptor)
            }
        }

        let generation = generator(descriptor) { [weak self] image in
            Task { @MainActor in
                self?.complete(descriptor: descriptor, image: image)
            }
        }
        inFlightRequests[descriptor] = InFlightRequest(
            generation: generation,
            completions: [callbackID: completion]
        )

        return ThumbnailCallbackToken { [weak self] in
            self?.cancelCallback(callbackID, for: descriptor)
        }
    }

    private func cancelCallback(_ callbackID: UUID, for descriptor: ThumbnailDescriptor) {
        guard var inFlight = inFlightRequests[descriptor] else {
            return
        }

        inFlight.completions.removeValue(forKey: callbackID)
        if inFlight.completions.isEmpty {
            inFlight.generation.cancel()
            inFlightRequests.removeValue(forKey: descriptor)
        } else {
            inFlightRequests[descriptor] = inFlight
        }
    }

    private func complete(descriptor: ThumbnailDescriptor, image: NSImage?) {
        guard let inFlight = inFlightRequests.removeValue(forKey: descriptor) else {
            return
        }

        let preparedImage = image.map { Self.preparedImage($0, forPath: descriptor.path) }
        if let preparedImage {
            cache.setObject(preparedImage, forKey: descriptor.cacheKey as NSString)
        }

        for completion in inFlight.completions.values {
            completion(preparedImage)
        }
    }

    private static func quickLookGenerator(
        descriptor: ThumbnailDescriptor,
        completion: @escaping (NSImage?) -> Void
    ) -> ThumbnailGenerationToken {
        let request = QLThumbnailGenerator.Request(
            fileAt: URL(fileURLWithPath: descriptor.path),
            size: descriptor.pointSize,
            scale: descriptor.scale,
            representationTypes: .thumbnail
        )
        let generator = QLThumbnailGenerator.shared
        generator.generateBestRepresentation(for: request) { representation, _ in
            completion(representation?.nsImage)
        }

        return ThumbnailGenerationToken {
            generator.cancel(request)
        }
    }

    private static func preparedImage(_ image: NSImage, forPath path: String) -> NSImage {
        guard needsNeutralBackground(path: path) else {
            return image
        }

        let outputSize = image.size.width > 0 && image.size.height > 0
            ? image.size
            : NSSize(width: 1, height: 1)
        let output = NSImage(size: outputSize)
        output.lockFocus()
        NSColor.windowBackgroundColor.setFill()
        NSRect(origin: .zero, size: outputSize).fill()
        image.draw(
            in: NSRect(origin: .zero, size: outputSize),
            from: NSRect(origin: .zero, size: image.size),
            operation: .sourceOver,
            fraction: 1
        )
        output.unlockFocus()
        return output
    }

    private static func needsNeutralBackground(path: String) -> Bool {
        let url = URL(fileURLWithPath: path)
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return false
        }

        return type.conforms(to: .svg)
            || type.conforms(to: .plainText)
            || type.conforms(to: .sourceCode)
            || type.identifier == "public.png"
    }

    private struct InFlightRequest {
        let generation: ThumbnailGenerationToken
        var completions: [UUID: (NSImage?) -> Void]
    }
}

final class ThumbnailGenerationToken {
    private let onCancel: () -> Void
    private var cancelled = false

    init(onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !cancelled else {
            return
        }

        cancelled = true
        onCancel()
    }
}

private final class ThumbnailCallbackToken: ThumbnailRequestToken {
    private let onCancel: () -> Void
    private(set) var isCancelled = false

    init(onCancel: @escaping () -> Void = {}) {
        self.onCancel = onCancel
    }

    func cancel() {
        guard !isCancelled else {
            return
        }

        isCancelled = true
        onCancel()
    }
}
