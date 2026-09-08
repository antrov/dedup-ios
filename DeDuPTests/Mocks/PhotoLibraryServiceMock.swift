//
//  PhotoLibraryServiceMock.swift
//  DeDuPTests
//
//  Created by Hubert Andrzejewski on 17/05/2024.
//

@testable import DeDuP
import Photos
import UIKit

final class PhotoLibraryServiceMock: PhotoLibraryServiceProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var _assetsToReturn: Set<LibraryAsset> = []
    private var _authorizationStatus: PHAuthorizationStatus = .authorized

    var authorizationStatusToReturn: PHAuthorizationStatus {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _authorizationStatus
        }
        set {
            lock.lock()
            _authorizationStatus = newValue
            lock.unlock()
        }
    }

    var authorizationStatus: PHAuthorizationStatus {
        get { authorizationStatusToReturn }
        set { authorizationStatusToReturn = newValue }
    }

    var authorizationDelay: Duration?

    var assetsToReturn: Set<LibraryAsset> {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _assetsToReturn
        }
        set {
            lock.lock()
            _assetsToReturn = newValue
            lock.unlock()
        }
    }

    var libraryAssets: Set<LibraryAsset> {
        get { assetsToReturn }
        set { assetsToReturn = newValue }
    }

    var fetchCallCount = 0
    /// Lets a test tell "went through the incremental path" apart from "did a full walk" (W-55),
    /// which `fetchCallCount` alone can't: the default implementation of the `reusing:` overload
    /// falls back to the very method `fetchCallCount` already counts.
    var reusingFetchCallCount = 0
    var lastPreviousSnapshot: [LibraryAssetSnapshot]?
    var thumbnailRequestCount = 0
    var deletedAssets: [LibraryAsset] = []

    private var _changesContinuation: AsyncStream<Void>.Continuation!
    lazy var libraryChanges: AsyncStream<Void> = AsyncStream { continuation in
        self._changesContinuation = continuation
    }

    init() {
        _ = libraryChanges
    }

    func yieldChange() {
        _changesContinuation.yield()
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        if let authorizationDelay {
            await Task.detached { try? await Task.sleep(for: authorizationDelay) }.value
        }
        return authorizationStatusToReturn
    }

    func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset> {
        fetchCallCount += 1
        let assets = assetsToReturn
        onProgress(assets.count, assets.count)
        return assets
    }

    func fetchLibraryAssets(
        reusing previousSnapshot: [LibraryAssetSnapshot],
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> Set<LibraryAsset> {
        reusingFetchCallCount += 1
        lastPreviousSnapshot = previousSnapshot
        fetchCallCount += 1
        let assets = assetsToReturn
        onProgress(assets.count, assets.count)
        return assets
    }

    func requestThumbnail(for _: LibraryAsset, size _: CGSize) async -> UIImage? {
        thumbnailRequestCount += 1
        return UIImage(named: "StockPhoto1")
    }

    func delete(_ asset: LibraryAsset) async throws {
        lock.lock()
        _assetsToReturn.remove(asset)
        deletedAssets.append(asset)
        lock.unlock()
    }
}
