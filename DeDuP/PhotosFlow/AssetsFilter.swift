//
//  AssetsFilter.swift
//  DeDuP
//

import Photos

extension PhotosViewModel {
    /// Which photos are allowed to reach grouping. Applied when building the arrays handed to
    /// the engine (W-35), never inside the grouping loop, so a filtered-out photo doesn't cost a
    /// single comparison.
    struct AssetsFilter: OptionSet {
        let rawValue: UInt

        static let iCloudIncluded = AssetsFilter(rawValue: 1 << 0)

        func includes(_ asset: LibraryAsset) -> Bool {
            contains(.iCloudIncluded) || asset.asset.sourceType != .typeCloudShared
        }
    }
}
