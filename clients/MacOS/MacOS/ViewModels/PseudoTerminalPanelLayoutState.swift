//
//  PseudoTerminalPanelLayoutState.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import CoreGraphics
import Combine
import Foundation

@MainActor
final class PseudoTerminalPanelLayoutState: ObservableObject {
    nonisolated static let defaultHeight: CGFloat = 184
    nonisolated static let minimumHeight: CGFloat = 120
    nonisolated static let maximumHeight: CGFloat = 420
    nonisolated static let minimumDirectoryHeight: CGFloat = 160
    nonisolated static let viewportResizeDebounceNanoseconds: UInt64 = 60_000_000

    @Published private(set) var isOpen = false
    @Published private(set) var height: CGFloat
    @Published private(set) var viewportSize: CGSize = .zero

    var onViewportResize: ((CGSize) -> Void)?

    private let viewportResizeDebounceNanoseconds: UInt64
    private var pendingViewportSize: CGSize?
    private var viewportResizeTask: Task<Void, Never>?

    init(
        height: CGFloat = PseudoTerminalPanelLayoutState.defaultHeight,
        viewportResizeDebounceNanoseconds: UInt64 = PseudoTerminalPanelLayoutState.viewportResizeDebounceNanoseconds
    ) {
        self.height = Self.clamped(height)
        self.viewportResizeDebounceNanoseconds = viewportResizeDebounceNanoseconds
    }

    deinit {
        viewportResizeTask?.cancel()
    }

    func open() {
        isOpen = true
    }

    func close() {
        isOpen = false
    }

    func resize(
        byVerticalDrag verticalDrag: CGFloat,
        availableContentHeight: CGFloat? = nil
    ) {
        setHeight(
            height - verticalDrag,
            availableContentHeight: availableContentHeight
        )
    }

    func setHeight(
        _ proposedHeight: CGFloat,
        availableContentHeight: CGFloat? = nil
    ) {
        height = Self.clamped(
            proposedHeight,
            availableContentHeight: availableContentHeight
        )
    }

    func noteViewportSize(_ size: CGSize) {
        let normalizedSize = CGSize(
            width: max(0, size.width.rounded(.down)),
            height: max(0, size.height.rounded(.down))
        )

        guard normalizedSize != pendingViewportSize,
              normalizedSize != viewportSize
        else {
            return
        }

        pendingViewportSize = normalizedSize
        viewportResizeTask?.cancel()
        let debounceNanoseconds = viewportResizeDebounceNanoseconds
        viewportResizeTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: debounceNanoseconds)
            } catch {
                return
            }

            guard !Task.isCancelled else {
                return
            }

            self?.deliverPendingViewportSize()
        }
    }

    private func deliverPendingViewportSize() {
        guard let pendingViewportSize else {
            return
        }

        self.pendingViewportSize = nil
        viewportSize = pendingViewportSize
        onViewportResize?(pendingViewportSize)
    }

    private nonisolated static func clamped(
        _ height: CGFloat,
        availableContentHeight: CGFloat? = nil
    ) -> CGFloat {
        let maximumHeight = availableContentHeight.map {
            min(Self.maximumHeight, max(Self.minimumHeight, $0 - Self.minimumDirectoryHeight))
        } ?? Self.maximumHeight

        return min(max(height, Self.minimumHeight), maximumHeight)
    }
}
