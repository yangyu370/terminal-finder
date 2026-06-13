//
//  FinderPreviewImageLayout.swift
//  MacOS
//
//  Created by Codex on 2026/6/13.
//

import AppKit

enum FinderPreviewImageLayout {
    static func aspectFitRect(
        imageSize: CGSize,
        container: CGRect,
        maximumScale: CGFloat = .greatestFiniteMagnitude
    ) -> CGRect {
        guard imageSize.width.isFinite,
              imageSize.height.isFinite,
              container.width.isFinite,
              container.height.isFinite,
              maximumScale.isFinite || maximumScale == .greatestFiniteMagnitude,
              imageSize.width > 0,
              imageSize.height > 0,
              container.width > 0,
              container.height > 0,
              maximumScale > 0
        else {
            return CGRect(
                x: container.midX,
                y: container.midY,
                width: 0,
                height: 0
            )
        }

        let scale = min(
            container.width / imageSize.width,
            container.height / imageSize.height,
            maximumScale
        )
        let fittedSize = CGSize(
            width: imageSize.width * scale,
            height: imageSize.height * scale
        )

        return CGRect(
            x: container.midX - fittedSize.width / 2,
            y: container.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        ).integral
    }
}
