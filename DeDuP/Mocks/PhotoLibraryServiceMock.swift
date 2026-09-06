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
        /// Holds the scan where the system permission prompt holds it, so a test can act while
        /// one is waiting for an answer.
        var authorizationDelay: Duration?
        var libraryAssets: Set<LibraryAsset> = []
        var thumbnail: UIImage? = UIImage(named: "StockPhoto1")
        private(set) var deletedAssets: [LibraryAsset] = []
        /// Lets a test assert that a scan that was called off never went on to read the library.
        private(set) var fetchCallCount = 0
        /// Lets a test assert that a cell doesn't ask for a thumbnail it already has (W-42).
        private(set) var thumbnailRequestCount = 0

        func requestAuthorization() async -> PHAuthorizationStatus {
            if let authorizationDelay {
                // Detached, so cancelling the scan doesn't cut the wait short: the system prompt
                // stays up until the user answers it whatever the app has since decided.
                await Task.detached { try? await Task.sleep(for: authorizationDelay) }.value
            }
            return authorizationStatus
        }

        func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset> {
            fetchCallCount += 1
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

        var libraryChanges: AsyncStream<Void> {
            AsyncStream { _ in }
        }
    }

#endif
