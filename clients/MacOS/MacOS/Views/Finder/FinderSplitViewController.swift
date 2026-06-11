//
//  FinderSplitViewController.swift
//  MacOS
//
//  Created by Claude on 2026/6/11.
//

import AppKit

/// Split view controller hosting the Liquid Glass sidebar and the content area.
/// The sidebar material comes entirely from `NSSplitViewItem(sidebarWithViewController:)`;
/// no extra visual effect views are layered on top.
final class FinderSplitViewController: NSSplitViewController {
    private static let defaultSidebarWidth: CGFloat = 186

    private var hasAppliedInitialSidebarWidth = false

    init(sidebarViewController: NSViewController, contentViewController: NSViewController) {
        super.init(nibName: nil, bundle: nil)

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarViewController)
        sidebarItem.minimumThickness = 160
        sidebarItem.maximumThickness = 320
        sidebarItem.canCollapse = true
        addSplitViewItem(sidebarItem)

        let contentItem = NSSplitViewItem(viewController: contentViewController)
        addSplitViewItem(contentItem)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidAppear() {
        super.viewDidAppear()

        guard !hasAppliedInitialSidebarWidth else {
            return
        }

        hasAppliedInitialSidebarWidth = true
        splitView.setPosition(Self.defaultSidebarWidth, ofDividerAt: 0)
    }
}
