//
//  PhotoLibraryService.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos
import UIKit

/// Everything the app needs from the photo library, behind a protocol so it can be swapped
/// for a fake in previews and tests.
protocol PhotoLibraryServiceProtocol {
    func requestAuthorization() async -> PHAuthorizationStatus
    func fetchLibraryAssets() async -> Set<LibraryAsset>
    func requestThumbnail(for asset: LibraryAsset, size: CGSize) async -> UIImage?
    func delete(_ asset: LibraryAsset) async throws
}

final class PhotoLibraryService: PhotoLibraryServiceProtocol {

    private let imageManager = PHCachingImageManager()

    func requestAuthorization() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus()

        switch currentStatus {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        case .restricted, .denied, .authorized, .limited:
            return currentStatus
        @unknown default:
            return currentStatus
        }
    }

    func fetchLibraryAssets() async -> Set<LibraryAsset> {
        var assets = Set<LibraryAsset>()
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        var idx = 0

        PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    idx += 1
                    assets.insert(LibraryAsset(asset: asset, collection: collection, idx: idx))
                }
            }

        PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            .enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image else { return }
                    idx += 1
                    assets.insert(LibraryAsset(asset: asset, collection: collection, idx: idx))
                }
            }

        PHAsset.fetchAssets(with: .image, options: fetchOptions).enumerateObjects { asset, _, _ in
            idx += 1
            assets.insert(LibraryAsset(asset: asset, collection: nil, idx: idx))
        }

        return assets
    }

    func requestThumbnail(for asset: LibraryAsset, size: CGSize) async -> UIImage? {
        let options = PHImageRequestOptions()
        options.deliveryMode = .highQualityFormat
        options.isSynchronous = false

        return await withCheckedContinuation { continuation in
            imageManager.requestImage(for: asset.asset, targetSize: size, contentMode: .aspectFill, options: options) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }

    func delete(_ asset: LibraryAsset) async throws {
        let requestedAssets = [asset.asset] as NSArray

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                if let collection = asset.collection, let collectionRequest = PHAssetCollectionChangeRequest(for: collection) {
                    collectionRequest.removeAssets(requestedAssets)
                } else {
                    PHAssetChangeRequest.deleteAssets(requestedAssets)
                }
            } completionHandler: { _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}
