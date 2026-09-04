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
        libraryAsset.collection?.localizedTitle
    }

    var creationDate: Date? {
        libraryAsset.asset.creationDate
    }

    lazy var meta = Meta.create(from: libraryAsset.asset, collection: libraryAsset.collection)

    init(libraryAsset: LibraryAsset, pHash: UInt64, photoLibrary: PhotoLibraryServiceProtocol) {
        self.libraryAsset = libraryAsset
        self.pHash = pHash
        self.photoLibrary = photoLibrary
    }

    func requestThumbnail(_ size: CGSize) {
        Task {
            let image = await photoLibrary.requestThumbnail(for: libraryAsset, size: size)
            await MainActor.run { self.thumbnail = image }
        }
    }

    static func == (lhs: Asset, rhs: Asset) -> Bool {
        lhs.id == rhs.id
    }
}
