//
//  FinderIconGridView.swift
//  MacOS
//
//  Created by Codex on 2026/6/12.
//

import AppKit
import SwiftUI

struct FinderIconGridView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(
            width: FinderIconGridMetrics.itemWidth,
            height: FinderIconGridMetrics.itemHeight
        )
        layout.sectionInset = FinderIconGridMetrics.sectionInset
        layout.minimumInteritemSpacing = FinderIconGridMetrics.minimumInteritemSpacing
        layout.minimumLineSpacing = FinderIconGridMetrics.minimumLineSpacing

        let collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.backgroundColors = [.controlBackgroundColor]
        collectionView.delegate = context.coordinator
        collectionView.dataSource = context.coordinator
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.register(
            FinderIconGridItem.self,
            forItemWithIdentifier: FinderIconGridItem.reuseIdentifier
        )

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        collectionView.addGestureRecognizer(doubleClick)

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView

        context.coordinator.collectionView = collectionView
        context.coordinator.entries = entries
        collectionView.reloadData()
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen
        context.coordinator.entries = entries

        guard let collectionView = scrollView.documentView as? NSCollectionView else {
            return
        }

        collectionView.reloadData()
        applySelection(on: collectionView, coordinator: context.coordinator)
    }

    private func applySelection(on collectionView: NSCollectionView, coordinator: Coordinator) {
        coordinator.isApplyingSelection = true
        defer {
            coordinator.isApplyingSelection = false
        }

        guard let selectedPath,
              let index = coordinator.entries.firstIndex(where: { $0.path == selectedPath })
        else {
            collectionView.deselectAll(nil)
            return
        }

        let indexPath = IndexPath(item: index, section: 0)
        if collectionView.selectionIndexPaths != [indexPath] {
            collectionView.selectItems(at: [indexPath], scrollPosition: [])
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var entries: [DirectoryEntry] = []
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var isApplyingSelection = false

        weak var collectionView: NSCollectionView?

        init(
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
        }

        func numberOfSections(in collectionView: NSCollectionView) -> Int {
            1
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            numberOfItemsInSection section: Int
        ) -> Int {
            entries.count
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            itemForRepresentedObjectAt indexPath: IndexPath
        ) -> NSCollectionViewItem {
            let item = collectionView.makeItem(
                withIdentifier: FinderIconGridItem.reuseIdentifier,
                for: indexPath
            )

            guard let iconItem = item as? FinderIconGridItem else {
                return item
            }

            iconItem.configure(with: entries[indexPath.item])
            return iconItem
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didSelectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isApplyingSelection else {
                return
            }

            guard let indexPath = indexPaths.first,
                  entries.indices.contains(indexPath.item)
            else {
                onSelect(nil)
                return
            }

            onSelect(entries[indexPath.item].path)
        }

        func collectionView(
            _ collectionView: NSCollectionView,
            didDeselectItemsAt indexPaths: Set<IndexPath>
        ) {
            guard !isApplyingSelection, collectionView.selectionIndexPaths.isEmpty else {
                return
            }

            onSelect(nil)
        }

        @objc func handleDoubleClick(_ recognizer: NSClickGestureRecognizer) {
            guard recognizer.state == .ended,
                  let collectionView
            else {
                return
            }

            let point = recognizer.location(in: collectionView)
            guard let indexPath = collectionView.indexPathForItem(at: point),
                  entries.indices.contains(indexPath.item)
            else {
                return
            }

            onOpen(entries[indexPath.item])
        }
    }
}

private final class FinderIconGridItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FinderIconGridItem")

    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let selectionView = FinderIconSelectionView()

    override var isSelected: Bool {
        didSet {
            selectionView.isSelected = isSelected
            titleField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        }
    }

    override func loadView() {
        view = NSView()
        view.wantsLayer = true

        selectionView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        iconView.setContentCompressionResistancePriority(.required, for: .vertical)

        titleField.font = .systemFont(ofSize: 12)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 2
        titleField.allowsDefaultTighteningForTruncation = true

        view.addSubview(selectionView)
        selectionView.addSubview(iconView)
        selectionView.addSubview(titleField)

        NSLayoutConstraint.activate([
            selectionView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            selectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: 4),
            selectionView.widthAnchor.constraint(equalToConstant: 96),
            selectionView.bottomAnchor.constraint(lessThanOrEqualTo: view.bottomAnchor, constant: -2),

            iconView.topAnchor.constraint(equalTo: selectionView.topAnchor, constant: 4),
            iconView.centerXAnchor.constraint(equalTo: selectionView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FinderIconGridMetrics.iconSize),
            iconView.heightAnchor.constraint(equalToConstant: FinderIconGridMetrics.iconSize),

            titleField.topAnchor.constraint(
                equalTo: iconView.bottomAnchor,
                constant: FinderIconGridMetrics.labelTopSpacing
            ),
            titleField.leadingAnchor.constraint(equalTo: selectionView.leadingAnchor, constant: 4),
            titleField.trailingAnchor.constraint(equalTo: selectionView.trailingAnchor, constant: -4),
            titleField.bottomAnchor.constraint(lessThanOrEqualTo: selectionView.bottomAnchor, constant: -5)
        ])
    }

    func configure(with entry: DirectoryEntry) {
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(width: FinderIconGridMetrics.iconSize, height: FinderIconGridMetrics.iconSize)
        iconView.image = icon
        titleField.stringValue = FinderListFormatters.displayName(for: entry)
        titleField.toolTip = entry.name
        isSelected = false
    }
}

private final class FinderIconSelectionView: NSView {
    var isSelected = false {
        didSet {
            needsDisplay = true
        }
    }

    override var isFlipped: Bool {
        true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard isSelected else {
            return
        }

        NSColor.controlAccentColor.setFill()
        let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 1), xRadius: 7, yRadius: 7)
        path.fill()
    }
}
