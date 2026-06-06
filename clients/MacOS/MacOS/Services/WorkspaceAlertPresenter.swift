//
//  WorkspaceAlertPresenter.swift
//  MacOS
//
//  Created by Codex on 2026/6/6.
//

import AppKit

struct WorkspaceAlertWarning: Equatable {
    let message: String
    let informativeText: String
    let detailText: String?
    let recoverySuggestion: String?
    let buttonTitle: String

    init(
        message: String,
        informativeText: String,
        detailText: String? = nil,
        recoverySuggestion: String? = nil,
        buttonTitle: String = "OK"
    ) {
        self.message = message
        self.informativeText = informativeText
        self.detailText = detailText
        self.recoverySuggestion = recoverySuggestion
        self.buttonTitle = buttonTitle
    }
}

protocol WorkspaceAlertPresenting: AnyObject {
    func showWarning(_ warning: WorkspaceAlertWarning)
}

extension WorkspaceAlertPresenting {
    func showWarning(
        message: String,
        informativeText: String,
        detailText: String? = nil,
        recoverySuggestion: String? = nil,
        buttonTitle: String = "OK"
    ) {
        showWarning(
            WorkspaceAlertWarning(
                message: message,
                informativeText: informativeText,
                detailText: detailText,
                recoverySuggestion: recoverySuggestion,
                buttonTitle: buttonTitle
            )
        )
    }
}

final class WorkspaceAlertPresenter: WorkspaceAlertPresenting {
    func showWarning(_ warning: WorkspaceAlertWarning) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = warning.message
        alert.informativeText = warning.informativeText
        alert.addButton(withTitle: warning.buttonTitle)
        if warning.hasAccessoryContent {
            alert.accessoryView = WorkspaceAlertAccessoryView(warning: warning)
        }
        alert.buttons.first?.keyEquivalent = "\r"

        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

private extension WorkspaceAlertWarning {
    var hasAccessoryContent: Bool {
        detailText?.trimmedNonEmpty != nil || recoverySuggestion?.trimmedNonEmpty != nil
    }
}

private final class WorkspaceAlertAccessoryView: NSView {
    private let preferredWidth: CGFloat = 376

    init(warning: WorkspaceAlertWarning) {
        super.init(frame: NSRect(x: 0, y: 0, width: preferredWidth, height: 1))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)

        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: preferredWidth),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        if let detailText = warning.detailText?.trimmedNonEmpty {
            stack.addArrangedSubview(
                makeInfoPanel(
                    title: "Reason",
                    body: detailText,
                    symbolName: "exclamationmark.circle"
                )
            )
        }

        if let recoverySuggestion = warning.recoverySuggestion?.trimmedNonEmpty {
            stack.addArrangedSubview(
                makeInfoPanel(
                    title: "Next Step",
                    body: recoverySuggestion,
                    symbolName: "arrow.clockwise.circle"
                )
            )
        }

        layoutSubtreeIfNeeded()
        frame.size = fittingSize
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    private func makeInfoPanel(title: String, body: String, symbolName: String) -> NSView {
        let panel = WorkspaceAlertPanelView()
        panel.translatesAutoresizingMaskIntoConstraints = false

        let row = NSStackView()
        row.orientation = .horizontal
        row.alignment = .top
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false

        let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: title)
        let imageView = NSImageView(image: image ?? NSImage())
        imageView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        imageView.contentTintColor = NSColor.secondaryLabelColor
        imageView.translatesAutoresizingMaskIntoConstraints = false

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 11, weight: .semibold)
        titleLabel.textColor = NSColor.secondaryLabelColor

        let bodyLabel = NSTextField(wrappingLabelWithString: body)
        bodyLabel.font = NSFont.systemFont(ofSize: 12)
        bodyLabel.textColor = NSColor.labelColor
        bodyLabel.maximumNumberOfLines = 3
        bodyLabel.lineBreakMode = .byTruncatingTail

        textStack.addArrangedSubview(titleLabel)
        textStack.addArrangedSubview(bodyLabel)
        row.addArrangedSubview(imageView)
        row.addArrangedSubview(textStack)

        panel.addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 12),
            row.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -12),
            row.topAnchor.constraint(equalTo: panel.topAnchor, constant: 10),
            row.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -10),
            imageView.widthAnchor.constraint(equalToConstant: 16),
            imageView.heightAnchor.constraint(equalToConstant: 16),
            panel.widthAnchor.constraint(equalToConstant: preferredWidth)
        ])

        return panel
    }
}

private final class WorkspaceAlertPanelView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        updateLayerColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateLayerColors()
    }

    private func updateLayerColors() {
        guard let layer else {
            return
        }

        layer.cornerRadius = 8
        layer.masksToBounds = true
        layer.borderWidth = 1
        layer.backgroundColor = NSColor.controlBackgroundColor
            .withAlphaComponent(0.72)
            .cgColor
        layer.borderColor = NSColor.separatorColor
            .withAlphaComponent(0.65)
            .cgColor
    }
}

private extension String {
    var trimmedNonEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
