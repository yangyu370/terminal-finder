//
//  WindowsXPPalette.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//

import AppKit
import SwiftUI

/// Luna (Windows XP) color palette. Collects every XP shell color so the shell
/// view, bevels, button styles, and icon provider never hand-roll one-off colors.
/// Distinct from Win98's cold gray: warm beige surface + Luna blue glass.
enum WindowsXPPalette {
    private static func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> Color {
        Color(nsColor: NSColor(calibratedRed: r / 255, green: g / 255, blue: b / 255, alpha: a))
    }

    // MARK: Control surface (XP warm beige-gray; vs Win98 cold #C0C0C0)
    static let surface = rgb(236, 233, 216)        // #ECE9D8
    static let surfaceLight = rgb(241, 239, 226)   // #F1EFE2
    static let toolbarTop = rgb(251, 251, 249)     // #FBFBF9
    static let toolbarBottom = rgb(236, 233, 216)  // #ECE9D8

    // MARK: Title bar (Luna blue glass gradient)
    static let titleActiveTop = rgb(42, 142, 244)  // #2A8EF4
    static let titleActiveMid = rgb(30, 120, 230)  // #1E78E6
    static let titleActiveBottom = rgb(0, 63, 200) // #003FC8
    static let titleGloss = Color.white.opacity(0.45)
    static let titleText = Color.white

    // MARK: Task pane (blue Explorer sidebar)
    static let taskPaneTop = rgb(125, 162, 227)    // #7DA2E3
    static let taskPaneBottom = rgb(79, 115, 195)  // #4F73C3
    static let taskPanelFill = Color.white
    static let taskHeaderText = rgb(10, 36, 106)   // #0A246A
    static let linkText = rgb(10, 36, 106)         // #0A246A
    static let linkHover = rgb(31, 91, 181)        // #1F5BB5

    // MARK: Selection / text
    static let selection = rgb(49, 106, 197)       // #316AC5
    static let selectedText = Color.white
    static let text = Color.black
    static let contentBackground = Color.white

    // MARK: Borders / bevel (soft warm gray + XP blue-gray field line)
    static let fieldBorder = rgb(127, 157, 185)    // #7F9DB9
    static let buttonBorder = rgb(0, 60, 116)      // #003C74
    static let highlight = Color.white
    static let light = rgb(241, 239, 226)          // #F1EFE2
    static let shadow = rgb(172, 168, 153)         // #ACA899
    static let darkShadow = rgb(113, 111, 100)     // #716F64

    // MARK: Caption (window) buttons
    static let captionBlue = rgb(60, 129, 243)     // #3C81F3
    static let captionBlueGloss = rgb(187, 214, 255) // #BBD6FF
    static let closeRed = rgb(199, 80, 80)         // #C75050
    static let closeRedGloss = rgb(243, 192, 192)  // #F3C0C0
}
