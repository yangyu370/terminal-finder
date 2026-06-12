//
//  FinderGalleryView.swift
//  MacOS
//
//  Created by Codex on 2026/6/12.
//

import AppKit
import SwiftUI

enum FinderGalleryMetrics {
    static let previewIconSize: CGFloat = 260
    static let inspectorIconSize: CGFloat = 44
    static let inspectorWidth: CGFloat = 240
    static let filmstripHeight: CGFloat = 118
    static let filmstripItemWidth: CGFloat = 92
    static let filmstripItemHeight: CGFloat = 88
    static let filmstripIconSize: CGFloat = 40
    static let filmstripItemSpacing: CGFloat = 8
    static let filmstripSectionInset = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
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

    private let scrollView = NSScrollView()
    private let previewArea = NSView()
    private let iconView = NSImageView()
    private let horizontalSeparator = NSBox()
    private let verticalSeparator = NSBox()
    private let inspectorView = NSView()
    private let inspectorIconView = NSImageView()
    private let inspectorTitleField = NSTextField(labelWithString: "")
    private let inspectorKindField = NSTextField(labelWithString: "")
    private let inspectorModifiedField = NSTextField(labelWithString: "")
    private let inspectorSizeField = NSTextField(labelWithString: "")

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

    override func layout() {
        super.layout()

        let inspectorWidth = min(FinderGalleryMetrics.inspectorWidth, bounds.width * 0.38)
        let separatorWidth: CGFloat = 1
        let filmstripHeight = min(FinderGalleryMetrics.filmstripHeight, bounds.height * 0.26)
        let leftWidth = max(0, bounds.width - inspectorWidth - separatorWidth)
        let previewHeight = max(0, bounds.height - filmstripHeight - separatorWidth)

        scrollView.frame = NSRect(x: 0, y: 0, width: leftWidth, height: filmstripHeight)
        horizontalSeparator.frame = NSRect(
            x: 0,
            y: filmstripHeight,
            width: leftWidth,
            height: separatorWidth
        )
        previewArea.frame = NSRect(
            x: 0,
            y: filmstripHeight + separatorWidth,
            width: leftWidth,
            height: previewHeight
        )
        verticalSeparator.frame = NSRect(
            x: leftWidth,
            y: 0,
            width: separatorWidth,
            height: bounds.height
        )
        inspectorView.frame = NSRect(
            x: leftWidth + separatorWidth,
            y: 0,
            width: inspectorWidth,
            height: bounds.height
        )

        let iconSize = max(
            96,
            min(
                FinderGalleryMetrics.previewIconSize,
                previewArea.bounds.width - 56,
                previewArea.bounds.height - 56
            )
        )
        iconView.frame = NSRect(
            x: (previewArea.bounds.width - iconSize) / 2,
            y: (previewArea.bounds.height - iconSize) / 2,
            width: iconSize,
            height: iconSize
        )
    }

    func configurePreview(entry: DirectoryEntry?) {
        guard let entry else {
            iconView.image = NSImage(systemSymbolName: "folder", accessibilityDescription: nil)
            inspectorIconView.image = iconView.image
            inspectorTitleField.stringValue = "没有项目"
            inspectorKindField.stringValue = "文件夹为空"
            inspectorModifiedField.stringValue = "--"
            inspectorSizeField.stringValue = "--"
            return
        }

        let icon = NSWorkspace.shared.icon(forFile: entry.path)
        icon.size = NSSize(
            width: FinderGalleryMetrics.previewIconSize,
            height: FinderGalleryMetrics.previewIconSize
        )
        iconView.image = icon
        inspectorIconView.image = icon
        inspectorTitleField.stringValue = FinderListFormatters.displayName(for: entry)
        inspectorKindField.stringValue = FinderListFormatters.kindDisplayText(for: entry)

        inspectorModifiedField.stringValue = FinderListFormatters.dateDisplayText(isoString: entry.modifiedAt)
        inspectorSizeField.stringValue = FinderListFormatters.sizeDisplayText(isDirectory: entry.isDirectory, size: entry.size)
    }

    private func setup() {
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor

        scrollView.borderType = .noBorder
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .controlBackgroundColor
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.documentView = collectionView

        iconView.imageScaling = .scaleProportionallyDown

        previewArea.addSubview(iconView)
        setupInspector()

        horizontalSeparator.boxType = .separator
        verticalSeparator.boxType = .separator

        addSubview(previewArea)
        addSubview(horizontalSeparator)
        addSubview(scrollView)
        addSubview(verticalSeparator)
        addSubview(inspectorView)
    }

    private func setupInspector() {
        inspectorView.wantsLayer = true
        inspectorView.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.88).cgColor

        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14

        let header = NSStackView()
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 10

        inspectorIconView.imageScaling = .scaleProportionallyDown
        inspectorIconView.translatesAutoresizingMaskIntoConstraints = false
        inspectorTitleField.font = .systemFont(ofSize: 13, weight: .semibold)
        inspectorTitleField.lineBreakMode = .byTruncatingMiddle
        inspectorKindField.font = .systemFont(ofSize: 12)
        inspectorKindField.textColor = .secondaryLabelColor

        let titleStack = NSStackView()
        titleStack.orientation = .vertical
        titleStack.alignment = .leading
        titleStack.spacing = 3
        titleStack.addArrangedSubview(inspectorTitleField)
        titleStack.addArrangedSubview(inspectorKindField)

        header.addArrangedSubview(inspectorIconView)
        header.addArrangedSubview(titleStack)

        let infoTitle = makeInspectorSectionTitle("信息")
        let modifiedRow = makeInspectorRow(label: "修改时间", valueField: inspectorModifiedField)
        let sizeRow = makeInspectorRow(label: "大小", valueField: inspectorSizeField)
        let tagTitle = makeInspectorSectionTitle("标签")
        let tagField = NSTextField(labelWithString: "添加标签...")
        tagField.font = .systemFont(ofSize: 12)
        tagField.textColor = .tertiaryLabelColor
        tagField.drawsBackground = true
        tagField.backgroundColor = .textBackgroundColor
        tagField.isBezeled = false
        tagField.alignment = .left

        let spacer = NSView()
        let moreStack = NSStackView()
        moreStack.orientation = .vertical
        moreStack.alignment = .centerX
        moreStack.spacing = 4
        let moreButton = NSButton(
            image: NSImage(systemSymbolName: "ellipsis.circle", accessibilityDescription: "更多") ?? NSImage(),
            target: nil,
            action: nil
        )
        moreButton.isBordered = false
        let moreText = NSTextField(labelWithString: "更多...")
        moreText.font = .systemFont(ofSize: 12)
        moreText.textColor = .secondaryLabelColor
        moreStack.addArrangedSubview(moreButton)
        moreStack.addArrangedSubview(moreText)

        stack.addArrangedSubview(header)
        stack.addArrangedSubview(infoTitle)
        stack.addArrangedSubview(modifiedRow)
        stack.addArrangedSubview(sizeRow)
        stack.addArrangedSubview(tagTitle)
        stack.addArrangedSubview(tagField)
        stack.addArrangedSubview(spacer)
        stack.addArrangedSubview(moreStack)

        inspectorView.addSubview(stack)

        NSLayoutConstraint.activate([
            inspectorIconView.widthAnchor.constraint(equalToConstant: FinderGalleryMetrics.inspectorIconSize),
            inspectorIconView.heightAnchor.constraint(equalToConstant: FinderGalleryMetrics.inspectorIconSize),
            tagField.heightAnchor.constraint(equalToConstant: 34),
            tagField.widthAnchor.constraint(equalTo: stack.widthAnchor),
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 220),

            stack.leadingAnchor.constraint(equalTo: inspectorView.leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: inspectorView.trailingAnchor, constant: -18),
            stack.topAnchor.constraint(equalTo: inspectorView.topAnchor, constant: 28),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: inspectorView.bottomAnchor, constant: -18)
        ])
    }

    private func makeInspectorSectionTitle(_ title: String) -> NSTextField {
        let field = NSTextField(labelWithString: title)
        field.font = .systemFont(ofSize: 13, weight: .semibold)
        return field
    }

    private func makeInspectorRow(label: String, valueField: NSTextField) -> NSStackView {
        let labelField = NSTextField(labelWithString: label)
        labelField.font = .systemFont(ofSize: 12, weight: .medium)
        labelField.textColor = .secondaryLabelColor
        valueField.font = .systemFont(ofSize: 12)
        valueField.alignment = .right
        valueField.lineBreakMode = .byTruncatingMiddle

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.addArrangedSubview(labelField)
        row.addArrangedSubview(valueField)

        labelField.widthAnchor.constraint(equalToConstant: 58).isActive = true
        valueField.widthAnchor.constraint(greaterThanOrEqualToConstant: 110).isActive = true
        return row
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
