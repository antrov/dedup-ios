//
//  AssetsGroup.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation

/// A cluster of visually similar assets (section 2 of the requirements doc) — a connected
/// component of the similarity graph. Pure container: the grouping logic that decides which
/// assets end up together lives in `GroupingEngine`, not here.
class AssetsGroup: Equatable, Comparable, Identifiable {
    /// Sorted deterministically by creation date, falling back to identifier for ties or missing
    /// dates (W-31) — never by the order hashing/grouping tasks happened to finish in.
    let assets: [Asset]
    let creationDate: ClosedRange<Date>?

    /// Stable across re-groupings of the same data (W-30): the lexicographically smallest member
    /// identifier, never a freshly generated UUID. This is what lets the SwiftUI list keep this
    /// group's identity — scroll position, animations — across a re-threshold instead of tearing
    /// down and rebuilding every row every time (B-14).
    var id: String {
        assets.map(\.id).min() ?? ""
    }

    /// Largest Hamming distance between any two members (W-33) — shown in the details view as a
    /// signal of the chain effect (2.4).
    var diameter: Int {
        PHash.diameter(of: assets.map(\.pHash))
    }

    init(assets: [Asset]) {
        self.assets = assets.sorted {
            ($0.creationDate ?? .distantPast, $0.id) < ($1.creationDate ?? .distantPast, $1.id)
        }
        creationDate = Self.creationDateOfAssets(self.assets)
    }

    private static func creationDateOfAssets(_ assets: [Asset]) -> ClosedRange<Date>? {
        let dates = assets.compactMap(\.creationDate)
        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
        return minDate ... maxDate
    }

    /// Tie-broken by `id` (W-31) instead of a random UUID, so groups with equal (or missing)
    /// creation dates still sort the same way every time.
    static func < (lhs: AssetsGroup, rhs: AssetsGroup) -> Bool {
        (lhs.creationDate?.lowerBound ?? .distantPast, lhs.id) < (rhs.creationDate?.lowerBound ?? .distantPast, rhs.id)
    }

    static func == (lhs: AssetsGroup, rhs: AssetsGroup) -> Bool {
        lhs.id == rhs.id
    }

    func comparedAssets() -> [(Asset, Meta)] {
        Array(
            zip(
                assets,
                assets.map(\.meta).compared()
            )
        )
    }
}

extension ClosedRange<Date> {
    var formatted: String {
        let lowerFormatted = lowerBound.formatted(.iso8601)
        guard lowerBound != upperBound else { return lowerFormatted }
        return "\(lowerFormatted) - \(upperBound.formatted(.iso8601))"
    }
}
