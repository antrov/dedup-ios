//
//  FiltersView.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

/// Content of the filters sheet. Takes only the plain values/bindings it actually needs
/// instead of the whole `PhotosViewModel`, so it stays previewable and reusable on its own.
struct FiltersView: View {
    @Binding var distanceThreshold: Double
    @Binding var iCloudIncluded: Bool
    let progress: Double
    let onThresholdCommitted: () -> Void

    var body: some View {
        VStack {
            ProgressView("Progress", value: progress)
            Slider(value: $distanceThreshold, in: 0 ... 30, step: 1) { editing in
                guard !editing else { return }
                onThresholdCommitted()
            }
            Toggle(isOn: $iCloudIncluded) {
                Text("Include iCloud Shared Albums")
            }
        }
        .contentMargins(8)
        .padding(.top)
    }
}

#Preview {
    FiltersView(
        distanceThreshold: .constant(4),
        iCloudIncluded: .constant(true),
        progress: 0.6,
        onThresholdCommitted: {}
    )
}
