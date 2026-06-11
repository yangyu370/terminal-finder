//
//  FinderTerminalSurfaceMetrics.swift
//  MacOS
//
//  Created by Codex on 2026/6/11.
//

import CoreGraphics

struct FinderTerminalGridSize: Equatable {
    let cols: Int
    let rows: Int
}

enum FinderTerminalSurfaceMetrics {
    static let estimatedCellWidth: CGFloat = 7.2
    static let estimatedCellHeight: CGFloat = 14.4

    static func gridSize(for viewportSize: CGSize) -> FinderTerminalGridSize {
        FinderTerminalGridSize(
            cols: max(1, Int((viewportSize.width / estimatedCellWidth).rounded(.down))),
            rows: max(1, Int((viewportSize.height / estimatedCellHeight).rounded(.down)))
        )
    }
}
