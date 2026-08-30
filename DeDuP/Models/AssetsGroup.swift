//
//  AssetsGroup.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation

/// A cluster of visually similar assets. Pure container - grouping/matching logic lives in
/// PhotosViewModel, which is the only layer that knows about the hashing service.
class AssetsGroup: Equatable, Comparable, Identifiable {
    let id: UUID
    var assets: [Asset]
    var creationDate: ClosedRange<Date>?

    init(asset: Asset) {
        assets = [asset]
        id = UUID()
        creationDate = Self.creationDateOfAssets([asset])
    }

    init(assets: [Asset]) {
        self.assets = assets
        id = UUID()
        creationDate = Self.creationDateOfAssets(assets)
    }

    func addAsset(_ asset: Asset) {
        assets.append(asset)
        creationDate = Self.creationDateOfAssets(assets)
    }

    private static func creationDateOfAssets(_ assets: [Asset]) -> ClosedRange<Date>? {
        let dates = assets.compactMap(\.creationDate)
        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
        return minDate ... maxDate
    }

    static func < (lhs: AssetsGroup, rhs: AssetsGroup) -> Bool {
        guard let ldate = lhs.creationDate, let rdate = rhs.creationDate else { return lhs.id < rhs.id }
        return ldate.lowerBound < rdate.lowerBound
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
