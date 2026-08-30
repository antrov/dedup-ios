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

        func requestAuthorization() async -> PHAuthorizationStatus {
            authorizationStatus
        }

        func fetchLibraryAssets() async -> Set<LibraryAsset> {
            libraryAssets
        }

        func requestThumbnail(for _: LibraryAsset, size _: CGSize) async -> UIImage? {
            thumbnail
        }

        func delete(_ asset: LibraryAsset) async throws {
            deletedAssets.append(asset)
        }
    }

#endif
