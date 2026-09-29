// TrackRowSelectionStyle.swift
//
// Decides the background color of a song row in a track list: highlighted when selected, a
// lighter shade when the mouse hovers over it, and plain otherwise. The selected color changes
// to suit the Retro MoonPod theme.

import SwiftUI

enum TrackRowBackgroundKind: Equatable {
    case selected
    case hover
    case clear

    static func resolve(isSelected: Bool, isCurrent: Bool, isHovered: Bool) -> TrackRowBackgroundKind {
        if isSelected { return .selected }
        if isHovered { return .hover }
        return .clear
    }

    func color() -> Color {
        switch self {
        case .selected:
            AppTheme.current.isRetroMoonPod ? Color.dAccent : Color.bgSelectedActive
        case .hover:
            Color.bgHover
        case .clear:
            .clear
        }
    }
}
