//
//  PhotoLibraryServiceMock.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

#if DEBUG

    import Foundation
    import Photos
    import UIKit

    final class PhotoLibraryServiceMock: PhotoLibraryServiceProtocol {
        var authorizationStatus: PHAuthorizationStatus = .authorized
        var libraryAssets: Set<LibraryAsset> = []
        var thumbnail: UIImage? = UIImage(named: "StockPhoto1")
        private(set) var deletedAssets: [LibraryAsset] = []
        /// Lets a test assert that a cell doesn't ask for a thumbnail it already has (W-42).
        private(set) var thumbnailRequestCount = 0

        func requestAuthorization() async -> PHAuthorizationStatus {
            authorizationStatus
        }

        func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset> {
            onProgress(libraryAssets.count, libraryAssets.count)
            return libraryAssets
        }

        func requestThumbnail(for _: LibraryAsset, size _: CGSize) async -> UIImage? {
            thumbnailRequestCount += 1
            return thumbnail
        }

        func delete(_ asset: LibraryAsset) async throws {
            deletedAssets.append(asset)
        }
    }

#endif
