//
//  WindowsXPBevel.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//
//  The single source of 3D edge drawing for the Windows XP shell. Softer and
//  warmer than Win98's hard black/white bevel; fields use the signature XP
//  single blue-gray line (#7F9DB9).

import SwiftUI

/// Soft raised cell border: warm highlight top-left, warm shadow bottom-right.
struct WindowsXPRaisedBorder: View {
    var body: some View {
        Rectangle()
            .strokeBorder(WindowsXPPalette.highlight, lineWidth: 1)
            .overlay(alignment: .trailing) {
                WindowsXPPalette.shadow.frame(width: 1)
            }
            .overlay(alignment: .bottom) {
                WindowsXPPalette.shadow.frame(height: 1)
            }
    }
}

/// XP field / inset border: a single 1px blue-gray line — the signature XP text
/// field / list frame. Optional slight rounding.
struct WindowsXPFieldBorder: View {
    var cornerRadius: CGFloat = 0

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .strokeBorder(WindowsXPPalette.fieldBorder, lineWidth: 1)
    }
}

/// Thin raised separator line for toolbar / menu base / pane dividers.
struct WindowsXPRaisedDivider: View {
    enum Axis {
        case horizontal
        case vertical
    }

    let axis: Axis

    var body: some View {
        switch axis {
        case .horizontal:
            VStack(spacing: 0) {
                WindowsXPPalette.shadow.frame(height: 1)
                WindowsXPPalette.highlight.frame(height: 1)
            }
        case .vertical:
            HStack(spacing: 0) {
                WindowsXPPalette.shadow.frame(width: 1)
                WindowsXPPalette.highlight.frame(width: 1)
            }
        }
    }
}
