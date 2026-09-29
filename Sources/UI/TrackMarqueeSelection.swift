// TrackMarqueeSelection.swift
//
// Helper for "rubber-band" selection, where you drag a rectangle across a list to select several
// songs at once. It lets each song row report its position on screen so the album page can work
// out which rows the rectangle touches.

import SwiftUI

struct TrackFramePreferenceKey: PreferenceKey {
    static var defaultValue: [Int64: CGRect] = [:]

    static func reduce(value: inout [Int64: CGRect], nextValue: () -> [Int64: CGRect]) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    @ViewBuilder
    func trackSelectionFrame(id: Int64?, coordinateSpace: String, isEnabled: Bool = true) -> some View {
        if isEnabled, let id {
            background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: TrackFramePreferenceKey.self,
                        value: [id: proxy.frame(in: .named(coordinateSpace))]
                    )
                }
            )
        } else {
            self
        }
    }
}
