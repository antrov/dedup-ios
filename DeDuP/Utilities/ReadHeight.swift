//
//  ReadHeight.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

/// Generic utility for measuring a view's rendered height (e.g. to size a sheet's
/// `.presentationDetents` to its content). Not tied to any single feature.
struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let nextValue = nextValue() else { return }
        value = nextValue
    }
}

private struct ReadHeightModifier: ViewModifier {
    private var sizeView: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: HeightPreferenceKey.self, value: geometry.size.height)
        }
    }

    func body(content: Content) -> some View {
        content.background(sizeView)
    }
}

extension View {
    func readHeight() -> some View {
        modifier(ReadHeightModifier())
    }
}
