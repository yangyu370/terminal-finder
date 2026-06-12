//
//  FinderDisplayMode.swift
//  MacOS
//
//  Created by Codex on 2026/6/12.
//

import AppKit
import Combine

@MainActor
final class FinderDisplayModeState: ObservableObject {
    @Published private(set) var mode: FinderDisplayMode

    init(mode: FinderDisplayMode = .list) {
        self.mode = mode
    }

    func select(_ mode: FinderDisplayMode) {
        guard mode.isEnabledInToolbar, self.mode != mode else {
            return
        }

        self.mode = mode
    }
}

enum FinderDisplayMode: Int, CaseIterable, Identifiable {
    case icon = 0
    case list = 1
    case column = 2
    case gallery = 3

    var id: Int {
        rawValue
    }

    init?(segmentIndex: Int) {
        self.init(rawValue: segmentIndex)
    }

    var segmentIndex: Int {
        rawValue
    }

    var isEnabledInToolbar: Bool {
        switch self {
        case .icon, .list, .column:
            return true
        case .gallery:
            return false
        }
    }

    var accessibilityDescription: String {
        switch self {
        case .icon:
            return "图标显示"
        case .list:
            return "列表显示"
        case .column:
            return "分栏显示"
        case .gallery:
            return "画廊显示"
        }
    }

    var symbolNames: [String] {
        switch self {
        case .icon:
            return ["square.grid.2x2"]
        case .list:
            return ["list.bullet"]
        case .column:
            return ["rectangle.split.3x1"]
        case .gallery:
            return ["play.square.stack", "squares.below.rectangle"]
        }
    }
}

enum FinderIconGridMetrics {
    static let itemWidth: CGFloat = 112
    static let itemHeight: CGFloat = 108
    static let iconSize: CGFloat = 64
    static let labelTopSpacing: CGFloat = 7
    static let sectionInset = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
    static let minimumInteritemSpacing: CGFloat = 14
    static let minimumLineSpacing: CGFloat = 12
}
