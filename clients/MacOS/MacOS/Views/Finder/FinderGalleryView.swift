//
//  FinderGalleryView.swift
//  MacOS
//
//  Created by Codex on 2026/6/12.
//

import AppKit
import SwiftUI

enum FinderGalleryMetrics {
    static let previewIconSize: CGFloat = 128
    static let filmstripHeight: CGFloat = 118
    static let filmstripItemWidth: CGFloat = 92
    static let filmstripItemHeight: CGFloat = 88
    static let filmstripIconSize: CGFloat = 40
    static let filmstripItemSpacing: CGFloat = 8
    static let filmstripSectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
    static let previewMetadataWidth: CGFloat = 360
}

struct FinderGalleryView: NSViewRepresentable {
    let entries: [DirectoryEntry]
    let selectedPath: String?
    let onSelect: (String?) -> Void
    let onOpen: (DirectoryEntry) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSelect: onSelect, onOpen: onOpen)
    }

    func makeNSView(context: Context) -> FinderGalleryBrowserNSView {
        let browserView = FinderGalleryBrowserNSView()
        browserView.collectionView.delegate = context.coordinator
        browserView.collectionView.dataSource = context.coordinator
        browserView.collectionView.register(
            FinderGalleryStripItem.self,
            forItemWithIdentifier: FinderGalleryStripItem.reuseIdentifier
        )

        let doubleClick = NSClickGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleClick(_:))
        )
        doubleClick.numberOfClicksRequired = 2
        browserView.collectionView.addGestureRecognizer(doubleClick)

        context.coordinator.browserView = browserView
        context.coordinator.rebuild(with: entries)
        browserView.collectionView.reloadData()
        updatePreview(in: browserView)
        applySelection(in: browserView, coordinator: context.coordinator)
        return browserView
    }

    func updateNSView(_ browserView: FinderGalleryBrowserNSView, context: Context) {
        context.coordinator.browserView = browserView
        context.coordinator.onSelect = onSelect
        context.coordinator.onOpen = onOpen

        if context.coordinator.signature(for: entries) != context.coordinator.currentSignature {
            context.coordinator.rebuild(with: entries)
            browserView.collectionView.reloadData()
        }

        updatePreview(in: browserView)
        applySelection(in: browserView, coordinator: context.coordinator)
    }

    private func updatePreview(in browserView: FinderGalleryBrowserNSView) {
        let selectedEntry = selectedPath.flatMap { path in
            entries.first { $0.path == path }
        } ?? entries.first

        browserView.configurePreview(entry: selectedEntry)
    }

    private func applySelection(in browserView: FinderGalleryBrowserNSView, coordinator: Coordinator) {
        coordinator.isApplyingSelection = true
        defer {
            coordinator.isApplyingSelection = false
        }

        guard let selectedPath,
              let index = coordinator.entries.firstIndex(where: { $0.path == selectedPath })
        else {
            browserView.collectionView.deselectAll(nil)
            return
        }

        let indexPath = IndexPath(item: index, section: 0)
        if browserView.collectionView.selectionIndexPaths != [indexPath] {
            browserView.collectionView.selectItems(at: [indexPath], scrollPosition: .centeredHorizontally)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSCollectionViewDataSource, NSCollectionViewDelegate {
        var entries: [DirectoryEntry] = []
        var onSelect: (String?) -> Void
        var onOpen: (DirectoryEntry) -> Void
        var isApplyingSelection = false
        private(set) var currentSignature: [String] = []

        weak var browserView: FinderGalleryBrowserNSView?

        init(
            onSelect: @escaping (String?) -> Void,
            onOpen: @escaping (DirectoryEntry) -> Void
        ) {
            self.onSelect = onSelect
            self.onOpen = onOpen
        }

        func signature(for entries: [DirectoryEntry]) -> [String] {
            entries.map { entry in
                [
                    entry.path,
                    entry.name,
                    entry.kind.rawValue,
                    entry.isDirectory ? "1" : "0",
                    entry.size.map(String.init) ?? "",
                    entry.modifiedAt ?? ""
                ].joined(separator: "\u{1F}")
            }
        }

        func rebuild(with entries: [DirectoryEntry]) {
            self.entries = entries
            currentSignature = signature(for: entries)
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
                withIdentifier: FinderGalleryStripItem.reuseIdentifier,
                for: indexPath
            )

            guard let stripItem = item as? FinderGalleryStripItem else {
                return item
            }

            stripItem.configure(with: entries[indexPath.item])
            return stripItem
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

            let entry = entries[indexPath.item]
            browserView?.configurePreview(entry: entry)
            onSelect(entry.path)
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
                  let collectionView = browserView?.collectionView
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

final class FinderGalleryBrowserNSView: NSView {
    let collectionView: NSCollectionView

    private let previewArea = NSView()
    private let previewStack = NSStackView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private let kindField = NSTextField(labelWithString: "")
    private let detailField = NSTextField(labelWithString: "")
    private let separator = NSBox()

    override init(frame frameRect: NSRect) {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = NSSize(
            width: FinderGalleryMetrics.filmstripItemWidth,
            height: FinderGalleryMetrics.filmstripItemHeight
        )
        layout.sectionInset = FinderGalleryMetrics.filmstripSectionInset
        layout.minimumInteritemSpacing = FinderGalleryMetrics.filmstripItemSpacing
        layout.minimumLineSpacing = FinderGalleryMetrics.filmstripItemSpacing

        collectionView = NSCollectionView()
        collectionView.collectionViewLayout = layout
        collectionView.isSelectable = true
        collectionView.allowsMultipleSelection = false
        collectionView.backgroundColors = [.controlBackgroundColor]

        super.init(frame: frameRect)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    func configurePreview(entry: DirectoryEntry?) {
        guard let entry else {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            titleField.stringValue = "没有项目"
            kindField.stringValue = "文件夹为空"
            detailField.stringValue = ""
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(
            width: FinderGalleryMetrics.previewIconSize,
            height: FinderGalleryMetrics.previewIconSize
        )
        iconView.image = icon
        titleField.stringValue = FinderListFormatters.displayName(for: entry)
        kindField.stringValue = FinderListFormatters.kindDisplayText(for: entry)

        let dateText = FinderListFormatters.dateDisplayText(isoString: entry.modifiedAt)
        let sizeText = FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size)
        detailField.stringValue = "修改日期: \(dateText)    大小: \(sizeText)"
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView

        previewArea.translatesAutoresizingMaskIntoConstraints = false
        previewStack.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        separator.translatesAutoresizingMaskIntoConstraints = false

        previewStack.orientation = .vertical
        previewStack.alignment = .centerX
        previewStack.distribution = .gravityAreas
        previewStack.spacing = 8

        iconView.imageScaling = .scaleProportionallyDown
        titleField.font = .systemFont(ofSize: 16, weight: .semibold)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingMiddle
        titleField.maximumNumberOfLines = 1
        kindField.font = .systemFont(ofSize: 12)
        kindField.alignment = .center
        kindField.textColor = .secondaryLabelColor
        detailField.font = .systemFont(ofSize: 12)
        detailField.alignment = .center
        detailField.textColor = .secondaryLabelColor
        detailField.lineBreakMode = .byTruncatingTail

        previewArea.addSubview(previewStack)
        previewStack.addArrangedSubview(iconView)
        previewStack.addArrangedSubview(titleField)
        previewStack.addArrangedSubview(kindField)
        previewStack.addArrangedSubview(detailField)

        separator.boxType = .separator

        addSubview(previewArea)
        addSubview(separator)
        addSubview(scrollView)

        NSLayoutConstraint.activate([
            previewArea.leadingAnchor.constraint(equalTo: leadingAnchor),
            previewArea.trailingAnchor.constraint(equalTo: trailingAnchor),
            previewArea.topAnchor.constraint(equalTo: topAnchor),

            previewStack.centerXAnchor.constraint(equalTo: previewArea.centerXAnchor),
            previewStack.centerYAnchor.constraint(equalTo: previewArea.centerYAnchor, constant: -4),
            previewStack.widthAnchor.constraint(lessThanOrEqualToConstant: FinderGalleryMetrics.previewMetadataWidth),
            previewStack.widthAnchor.constraint(lessThanOrEqualTo: previewArea.widthAnchor, constant: -48),

            iconView.widthAnchor.constraint(equalToConstant: FinderGalleryMetrics.previewIconSize),
            iconView.heightAnchor.constraint(equalToConstant: FinderGalleryMetrics.previewIconSize),

            titleField.widthAnchor.constraint(equalTo: previewStack.widthAnchor),
            kindField.widthAnchor.constraint(equalTo: previewStack.widthAnchor),
            detailField.widthAnchor.constraint(equalTo: previewStack.widthAnchor),

            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            separator.topAnchor.constraint(equalTo: previewArea.bottomAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.heightAnchor.constraint(equalToConstant: FinderGalleryMetrics.filmstripHeight)
        ])
    }
}

private final class FinderGalleryStripItem: NSCollectionViewItem {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("FinderGalleryStripItem")

    private let selectionView = FinderGalleryStripSelectionView()
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")

    override var isSelected: Bool {
        didSet {
            selectionView.isSelected = isSelected
            titleField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        }
    }

    override func loadView() {
        view = NSView()

        selectionView.translatesAutoresizingMaskIntoConstraints = false
        iconView.translatesAutoresizingMaskIntoConstraints = false
        titleField.translatesAutoresizingMaskIntoConstraints = false

        iconView.imageScaling = .scaleProportionallyDown
        titleField.font = .systemFont(ofSize: 11)
        titleField.alignment = .center
        titleField.lineBreakMode = .byTruncatingTail
        titleField.maximumNumberOfLines = 1

        view.addSubview(selectionView)
        selectionView.addSubview(iconView)
        selectionView.addSubview(titleField)

        NSLayoutConstraint.activate([
            selectionView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 3),
            selectionView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -3),
            selectionView.topAnchor.constraint(equalTo: view.topAnchor, constant: 3),
            selectionView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -3),

            iconView.topAnchor.constraint(equalTo: selectionView.topAnchor, constant: 7),
            iconView.centerXAnchor.constraint(equalTo: selectionView.centerXAnchor),
            iconView.widthAnchor.constraint(equalToConstant: FinderGalleryMetrics.filmstripIconSize),
            iconView.heightAnchor.constraint(equalToConstant: FinderGalleryMetrics.filmstripIconSize),

            titleField.leadingAnchor.constraint(equalTo: selectionView.leadingAnchor, constant: 5),
            titleField.trailingAnchor.constraint(equalTo: selectionView.trailingAnchor, constant: -5),
            titleField.topAnchor.constraint(equalTo: iconView.bottomAnchor, constant: 5)
        ])
    }

    func configure(with entry: DirectoryEntry) {
        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(
            width: FinderGalleryMetrics.filmstripIconSize,
            height: FinderGalleryMetrics.filmstripIconSize
        )
        iconView.image = icon
        titleField.stringValue = FinderListFormatters.displayName(for: entry)
        titleField.toolTip = entry.name
        isSelected = false
    }
}

private final class FinderGalleryStripSelectionView: NSView {
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
        NSBezierPath(roundedRect: bounds.insetBy(dx: 1, dy: 1), xRadius: 7, yRadius: 7).fill()
    }
}
