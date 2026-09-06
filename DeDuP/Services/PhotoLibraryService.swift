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

    /// `onProgress` receives `(completed, total)` photo counts as the library is walked, so the
    /// scan phase can be shown with real progress instead of an unlabelled spinner (W-38).
    func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset>

    /// Cancelling the calling task cancels the underlying PhotoKit request (W-42), so a cell
    /// scrolled off screen stops occupying a slot in PhotoKit's queue.
    func requestThumbnail(for asset: LibraryAsset, size: CGSize) async -> UIImage?

    func delete(_ asset: LibraryAsset) async throws
}

final class PhotoLibraryService: PhotoLibraryServiceProtocol {
    /// "Images only" applied at the fetch-options level, on every path that pulls assets out of
    /// the library (W-20) — previously only the iCloud-shared-album path filtered by media type,
    /// so videos from regular albums reached the hashing service and were rejected there instead
    /// (B-17).
    private static let imageOnlyOptions: PHFetchOptions = {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
        return options
    }()

    /// One in-flight thumbnail request, with cancellation wired through a single lock (W-42).
    /// Two races have to be covered: `requestImage` only hands back its request ID after it may
    /// already have called the result handler, and the calling task can be cancelled before that
    /// ID exists at all. Whichever side gets the lock first wins, and because the continuation is
    /// cleared under it, it is resumed exactly once no matter how the request ends.
    private final class ThumbnailRequest: @unchecked Sendable {
        private let imageManager: PHImageManager
        private let lock = NSLock()
        private var continuation: CheckedContinuation<UIImage?, Never>?
        private var requestID: PHImageRequestID?
        private var isCancelled = false

        init(imageManager: PHImageManager) {
            self.imageManager = imageManager
        }

        func start(for asset: PHAsset, size: CGSize, continuation: CheckedContinuation<UIImage?, Never>) {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                continuation.resume(returning: nil)
                return
            }
            self.continuation = continuation
            lock.unlock()

            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isSynchronous = false

            let identifier = imageManager
                .requestImage(for: asset, targetSize: size, contentMode: .aspectFill, options: options) { [weak self] image, _ in
                    self?.finish(with: image)
                }

            lock.lock()
            requestID = identifier
            let cancelledMeanwhile = isCancelled
            lock.unlock()

            if cancelledMeanwhile {
                imageManager.cancelImageRequest(identifier)
            }
        }

        func cancel() {
            lock.lock()
            isCancelled = true
            let identifier = requestID
            let pending = continuation
            continuation = nil
            lock.unlock()

            if let identifier {
                imageManager.cancelImageRequest(identifier)
            }
            pending?.resume(returning: nil)
        }

        private func finish(with image: UIImage?) {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: image)
        }
    }

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

    func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset> {
        let passes = fetchPasses()
        // `PHFetchResult.count` is cheap, so the total is known before a single asset is
        // enumerated. It counts enumeration work, not distinct photos — an asset in an album is
        // visited by that album's pass and by the whole-library pass — which is why the UI shows
        // this as a bar without absolute numbers. Progress is reported once per pass rather than
        // once per asset, keeping the number of updates bounded without throttling here (W-21).
        let total = passes.reduce(0) { $0 + $1.assets.count }
        var completed = 0
        var assets = Set<LibraryAsset>()

        for pass in passes {
            guard !Task.isCancelled else { break }
            pass.assets.enumerateObjects { asset, _, stop in
                // A single album can be most of the library, so checking only between passes
                // would leave "the screen going away stops the work" (W-40) true at a granularity
                // the user would never notice. The caller discards a partial result anyway; what
                // this saves is the rest of the walk, and the wait it would put on the scan
                // queued behind this one.
                guard !Task.isCancelled else {
                    stop.pointee = true
                    return
                }
                assets.insert(LibraryAsset(asset: asset, collection: pass.collection))
            }
            completed += pass.assets.count
            onProgress(completed, total)
        }

        return assets
    }

    /// The three paths assets are pulled from, in the order that decides which album an asset
    /// present in several of them keeps: regular albums, iCloud shared albums, then everything
    /// else in the library.
    private func fetchPasses() -> [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?)] {
        var passes: [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?)] = []

        for subtype in [PHAssetCollectionSubtype.albumRegular, .albumCloudShared] {
            PHAssetCollection
                .fetchAssetCollections(with: .album, subtype: subtype, options: nil)
                .enumerateObjects { collection, _, _ in
                    passes.append((PHAsset.fetchAssets(in: collection, options: Self.imageOnlyOptions), collection))
                }
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        fetchOptions.predicate = Self.imageOnlyOptions.predicate
        passes.append((PHAsset.fetchAssets(with: .image, options: fetchOptions), nil))

        return passes
    }

    func requestThumbnail(for asset: LibraryAsset, size: CGSize) async -> UIImage? {
        let request = ThumbnailRequest(imageManager: imageManager)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                request.start(for: asset.asset, size: size, continuation: continuation)
            }
        } onCancel: {
            request.cancel()
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
