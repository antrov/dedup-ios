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
        authorizationStatusToReturn
    }

    func fetchLibraryAssets(onProgress: @escaping @Sendable (Int, Int) -> Void) async -> Set<LibraryAsset> {
        let assets = assetsToReturn
        onProgress(assets.count, assets.count)
        return assets
    }

    func requestThumbnail(for _: LibraryAsset, size _: CGSize) async -> UIImage? {
        nil
    }

    func delete(_ asset: LibraryAsset) async throws {
        lock.lock()
        _assetsToReturn.remove(asset)
        lock.unlock()
    }
}
