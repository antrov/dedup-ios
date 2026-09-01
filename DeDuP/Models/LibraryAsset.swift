//
//  LibraryAsset.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos

/// A PHAsset together with the album it was fetched from. Plain value type, no I/O.
struct LibraryAsset: Hashable, CustomStringConvertible {
    let asset: PHAsset
    let collection: PHAssetCollection?

    var description: String {
        [asset.creationDate?.formatted(), collection?.localizedTitle].compactMap { $0 }.joined(separator: " - ")
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(asset.localIdentifier)
    }

    static func == (lhs: LibraryAsset, rhs: LibraryAsset) -> Bool {
        lhs.asset.localIdentifier == rhs.asset.localIdentifier
    }
}
