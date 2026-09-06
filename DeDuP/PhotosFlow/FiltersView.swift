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
    /// What the app is currently doing, if anything — derived from the view model's state by
    /// `ContentView` so this sheet doesn't have to know the state machine (W-38).
    struct Status: Equatable {
        let label: String
        let detail: String?
        /// `nil` for work with no countable unit, which shows an indeterminate bar.
        let fraction: Double?
    }

    @Binding var distanceThreshold: Int
    @Binding var iCloudIncluded: Bool
    let status: Status?
    let counts: ProcessingCounts
    let onFetchCloudOnlyRequested: () -> Void

    private var thresholdBinding: Binding<Double> {
        Binding(
            get: { Double(distanceThreshold) },
            set: { distanceThreshold = Int($0) }
        )
    }

    var body: some View {
        VStack(spacing: 12) {
            statusSection
            VStack(alignment: .leading, spacing: 4) {
                Text("Similarity threshold: \(distanceThreshold)")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // No commit callback: every value is applied, and the view model debounces the
                // re-group so a drag ends in a single result (W-39).
                Slider(value: thresholdBinding, in: 0 ... 16, step: 1)
            }
            Toggle(isOn: $iCloudIncluded) {
                Text("Include iCloud Shared Albums")
            }
            countsSection
        }
        .contentMargins(8)
        .padding(.top)
    }

    @ViewBuilder
    private var statusSection: some View {
        if let status {
            VStack(alignment: .leading, spacing: 2) {
                if let fraction = status.fraction {
                    ProgressView(status.label, value: fraction)
                } else {
                    ProgressView(status.label)
                        .progressViewStyle(.linear)
                }
                if let detail = status.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// W-43: how much of the library actually made it through the pipeline, broken down by
    /// reason (W-22). Without this, "no duplicates found" is indistinguishable from "most of the
    /// library was never hashed".
    private var countsSection: some View {
        VStack(spacing: 2) {
            LabeledContent("Photos in library", value: "\(counts.libraryTotal)")
            LabeledContent("Hashed", value: "\(counts.computed)")
            LabeledContent("Failed", value: "\(counts.failed)")
            LabeledContent("Unsupported type", value: "\(counts.unsupportedType)")
            LabeledContent("Only in iCloud") {
                HStack(spacing: 8) {
                    Text("\(counts.cloudOnly)")
                    if counts.cloudOnly > 0 {
                        // The one place a scan is allowed to download from iCloud, and only
                        // because the user asked for it here (W-19). Off while anything is
                        // running: the count only refreshes once the download finishes, so
                        // otherwise the button keeps inviting taps for work already underway.
                        Button("Fetch", action: onFetchCloudOnlyRequested)
                            .disabled(status != nil)
                    }
                }
            }
        }
        .font(.footnote)
    }
}

#Preview {
    FiltersView(
        distanceThreshold: .constant(4),
        iCloudIncluded: .constant(true),
        status: .init(label: "Analysing photos", detail: "620 / 1 024", fraction: 0.6),
        counts: .init(libraryTotal: 1024, computed: 620, cloudOnly: 3, failed: 1, unsupportedType: 0),
        onFetchCloudOnlyRequested: {}
    )
}
