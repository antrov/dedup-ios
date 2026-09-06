//
//  Asset.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import UIKit

/// A single library asset plus its perceptual hash. Loads its own thumbnail lazily through
/// an injected `PhotoLibraryServiceProtocol`, so it stays testable/previewable without PhotoKit.
class Asset: Equatable, ObservableObject, Identifiable {
    @Published var thumbnail: UIImage?

    /// CocoaImageHashing's 64-bit `OSHashType`, reduced to a plain `UInt64` (W-02): the grouping
    /// layer works entirely in `Hashing/PHash.swift`'s own bit operations and never touches
    /// `ImageHashingServiceProtocol.distance` or any other CocoaImageHashing type.
    let pHash: UInt64
    let libraryAsset: LibraryAsset

    private let photoLibrary: PhotoLibraryServiceProtocol

    var id: String {
        libraryAsset.asset.localIdentifier
    }

    var collectionName: String? {
        libraryAsset.collectionName
    }

    var creationDate: Date? {
        libraryAsset.asset.creationDate
    }

    lazy var meta = Meta.create(from: libraryAsset)

    init(libraryAsset: LibraryAsset, pHash: UInt64, photoLibrary: PhotoLibraryServiceProtocol) {
        self.libraryAsset = libraryAsset
        self.pHash = pHash
        self.photoLibrary = photoLibrary
    }

    /// Loads the thumbnail at most once, on the main actor (W-42). The owning cell drives this
    /// from its own task, so scrolling the cell away cancels the request instead of leaving it
    /// queued in PhotoKit, and a cell that scrolls back into view finds the image already here
    /// rather than asking for it again.
    @MainActor
    func loadThumbnail(size: CGSize) async {
        guard thumbnail == nil else { return }
        let image = await photoLibrary.requestThumbnail(for: libraryAsset, size: size)
        guard !Task.isCancelled else { return }
        thumbnail = image
    }

    static func == (lhs: Asset, rhs: Asset) -> Bool {
        lhs.id == rhs.id
    }
}

extension [Asset] {
    /// Adds `newAssets`, replacing the entry for a photo that already has one rather than
    /// appending a second. A photo is one element here by construction — grouping keys its input
    /// by identifier — and the iCloud retry can produce an asset a scan running alongside it has
    /// already picked up from the records the retry saved (W-19).
    mutating func mergeByIdentifier(_ newAssets: [Asset]) {
        guard !newAssets.isEmpty else { return }

        var indexByID = [String: Int](minimumCapacity: count + newAssets.count)
        for (index, asset) in enumerated() {
            indexByID[asset.id] = index
        }
        for asset in newAssets {
            if let index = indexByID[asset.id] {
                self[index] = asset
            } else {
                indexByID[asset.id] = count
                append(asset)
            }
        }
    }
}

extension Asset {
    /// The UI models for one pass of the hashing pipeline. Only records that actually produced a
    /// hash become assets: cloud-only, unsupported and failed ones stay in the cache and are
    /// reported as counts (W-22, W-43) instead of silently reaching grouping as if they had been
    /// compared. `libraryAssets` is expected to hold one entry per photo, as `Set<LibraryAsset>`
    /// guarantees.
    static func make(
        from records: [HashRecord],
        for libraryAssets: [LibraryAsset],
        photoLibrary: PhotoLibraryServiceProtocol
    ) -> [Asset] {
        let assetsByID = Dictionary(uniqueKeysWithValues: libraryAssets.map { ($0.asset.localIdentifier, $0) })
        return records.compactMap { record in
            guard record.state == .computed, let phash = record.phash,
                  let libraryAsset = assetsByID[record.localIdentifier] else { return nil }
            return Asset(libraryAsset: libraryAsset, pHash: phash, photoLibrary: photoLibrary)
        }
    }
}
