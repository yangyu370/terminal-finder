//
//  WindowsXPButtonStyles.swift
//  MacOS
//
//  Created by Claude on 2026/6/14.
//

import SwiftUI

/// Luna push button: rounded 3px, soft vertical gradient face, deep-blue outline.
/// Glossier than the Win98 flat gray raised button.
struct WindowsXPButtonStyle: ButtonStyle {
    var compact = false

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = 3
        return configuration.label
            .font(.system(size: compact ? 11 : 12))
            .foregroundStyle(WindowsXPPalette.text)
            .padding(.horizontal, compact ? 8 : 11)
            .frame(height: compact ? 20 : 23)
            .background(
                LinearGradient(
                    colors: configuration.isPressed
                        ? [WindowsXPPalette.surface, WindowsXPPalette.surfaceLight]
                        : [WindowsXPPalette.surfaceLight, WindowsXPPalette.surface],
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(WindowsXPPalette.buttonBorder.opacity(0.8), lineWidth: 1)
            }
            .offset(y: configuration.isPressed ? 1 : 0)
    }
}

struct WindowsXPShellSwitchButtonStyle: ButtonStyle {
    var isSelected = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(isSelected ? WindowsXPPalette.titleActiveBottom : WindowsXPPalette.text)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(
                LinearGradient(
                    colors: backgroundColors(pressed: configuration.isPressed),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay {
                RoundedRectangle(cornerRadius: 4)
                    .strokeBorder(
                        isSelected ? WindowsXPPalette.highlight : WindowsXPPalette.buttonBorder.opacity(0.75),
                        lineWidth: 1
                    )
            }
            .shadow(color: Color.black.opacity(isSelected ? 0.18 : 0.08), radius: 1, x: 0, y: 1)
            .offset(y: configuration.isPressed ? 1 : 0)
    }

    private func backgroundColors(pressed: Bool) -> [Color] {
        if isSelected {
            return pressed
                ? [WindowsXPPalette.surface, WindowsXPPalette.surfaceLight]
                : [WindowsXPPalette.highlight, WindowsXPPalette.surfaceLight]
        }

        return pressed
            ? [WindowsXPPalette.surface, WindowsXPPalette.surfaceLight]
            : [WindowsXPPalette.surfaceLight, WindowsXPPalette.surface]
    }
}

enum WindowsXPCaptionButtonRole {
    case minimize
    case maximize
    case close
}

/// Luna caption (window control) button: glassy rounded square. Minimize and
/// maximize are blue glass; close is red — the most recognizable XP difference
/// from Win98's uniform gray squares.
struct WindowsXPCaptionButtonStyle: ButtonStyle {
    let role: WindowsXPCaptionButtonRole

    func makeBody(configuration: Configuration) -> some View {
        let radius: CGFloat = 3
        return configuration.label
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(Color.white)
            .frame(width: 22, height: 18)
            .background(
                LinearGradient(
                    colors: faceColors(pressed: configuration.isPressed),
                    startPoint: .top,
                    endPoint: .bottom
                )
            )
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [Color.white.opacity(0.65), Color.clear],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 7)
                .padding(.horizontal, 1)
                .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius))
            .overlay {
                RoundedRectangle(cornerRadius: radius)
                    .strokeBorder(Color.white.opacity(0.7), lineWidth: 1)
            }
            .offset(y: configuration.isPressed ? 1 : 0)
    }

    private func faceColors(pressed: Bool) -> [Color] {
        switch role {
        case .close:
            return pressed
                ? [WindowsXPPalette.closeRed, WindowsXPPalette.closeRedGloss]
                : [WindowsXPPalette.closeRedGloss, WindowsXPPalette.closeRed]
        case .minimize, .maximize:
            return pressed
                ? [WindowsXPPalette.captionBlue, WindowsXPPalette.captionBlueGloss]
                : [WindowsXPPalette.captionBlueGloss, WindowsXPPalette.captionBlue]
        }
    }
}
