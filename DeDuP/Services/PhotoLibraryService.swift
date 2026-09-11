//
//  PhotoLibraryService.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos
import UIKit

/// Which element of the library a scan is currently working through (W-57) — shown in the UI so
/// "scanning" doesn't read as one undifferentiated step when its two halves follow very different
/// rules and can take very different amounts of time.
enum LibraryScanStep: Hashable, Sendable {
    /// The user's own photos: the main library and their regular albums. An incremental scan
    /// (W-55) skips almost all of this for a photo it already knows about, so on a scan that finds
    /// nothing new, this step is close to instant regardless of library size.
    case localPhotos
    /// Albums other people have shared over iCloud. Unlike regular albums, these are always
    /// walked in full, on every single scan (W-55's shortcut deliberately doesn't extend to them —
    /// see `fetchLibraryAssets(reusing:onProgress:)`), so this is the one step that both runs on
    /// every launch without exception and can be the slowest part of an otherwise-instant scan if
    /// a lot of photos have been shared with the user.
    case sharedAlbums
}

/// Everything the app needs from the photo library, behind a protocol so it can be swapped
/// for a fake in previews and tests.
protocol PhotoLibraryServiceProtocol {
    func requestAuthorization() async -> PHAuthorizationStatus

    /// `onProgress` receives the step currently being walked (W-57) and `(completed, total)` photo
    /// counts within it, so the scan phase can be shown with real progress — and with which part
    /// of the library it reflects — instead of an unlabelled spinner (W-38).
    func fetchLibraryAssets(onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void) async -> Set<LibraryAsset>

    /// Reuses `previousSnapshot` — the previous scan's identifiers and album membership — instead
    /// of re-deriving everything from scratch (W-55): a photo present in both is assumed
    /// unchanged and keeps the album membership it already had, so only a genuinely new photo
    /// pays for the per-album walk that finds out which albums it's in. An empty snapshot (the
    /// very first scan) makes every photo "new," so this does exactly the work
    /// `fetchLibraryAssets` always has.
    ///
    /// This only ever narrows *how* the current library is discovered, never *what* counts as
    /// having changed: hash-cache validity still turns on `PHAsset.modificationDate` (W-11), and a
    /// photo missing from the result is still pruned from the cache the same way a full scan would
    /// prune it (W-13). What it can miss is a photo moving between two albums it was already in
    /// without anything else about it changing — the album name shown for it can lag until the
    /// next full `fetchLibraryAssets` (pull-to-refresh, or the first scan after this one fails).
    ///
    /// Shared albums (`LibraryScanStep.sharedAlbums`) are never part of that shortcut — they're
    /// walked in full here exactly as they are in `fetchLibraryAssets(onProgress:)`.
    func fetchLibraryAssets(
        reusing previousSnapshot: [LibraryAssetSnapshot],
        onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void
    ) async -> Set<LibraryAsset>

    /// Cancelling the calling task cancels the underlying PhotoKit request (W-42), so a cell
    /// scrolled off screen stops occupying a slot in PhotoKit's queue.
    func requestThumbnail(for asset: LibraryAsset, size: CGSize) async -> UIImage?

    func delete(_ asset: LibraryAsset) async throws

    var libraryChanges: AsyncStream<Void> { get }
}

extension PhotoLibraryServiceProtocol {
    /// Default for every conformance that has no cheaper way to answer (every mock/fake, and any
    /// future non-PhotoKit backend): the full walk is always correct, just not always the fastest
    /// route there.
    func fetchLibraryAssets(
        reusing previousSnapshot: [LibraryAssetSnapshot],
        onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void
    ) async -> Set<LibraryAsset> {
        await fetchLibraryAssets(onProgress: onProgress)
    }
}

final class PhotoLibraryService: NSObject, PhotoLibraryServiceProtocol, PHPhotoLibraryChangeObserver, @unchecked Sendable {
    /// "Images only" applied at the fetch-options level, on every path that pulls assets out of
    /// the library (W-20) — previously only the iCloud-shared-album path filtered by media type,
    /// so videos from regular albums reached the hashing service and were rejected there instead
    /// (B-17).
    private static let imageOnlyPredicate = NSPredicate(format: "mediaType = %d", PHAssetMediaType.image.rawValue)
    private static let imageOnlyOptions: PHFetchOptions = {
        let options = PHFetchOptions()
        options.predicate = imageOnlyPredicate
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
    private let passesLock = NSLock()
    private var lastFetchPasses: [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?, step: LibraryScanStep)] = []
    private var lastCollectionFetches: [PHFetchResult<PHAssetCollection>] = []
    private var changesContinuation: AsyncStream<Void>.Continuation!
    lazy var libraryChanges: AsyncStream<Void> = AsyncStream { continuation in
        self.changesContinuation = continuation
    }

    override init() {
        super.init()
        // Ensure stream is initialized before registering observer
        _ = libraryChanges
        PHPhotoLibrary.shared().register(self)
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
    }

    func photoLibraryDidChange(_ changeInstance: PHChange) {
        passesLock.lock()
        let passes = lastFetchPasses
        let collectionFetches = lastCollectionFetches
        passesLock.unlock()

        for collectionFetch in collectionFetches where changeInstance.changeDetails(for: collectionFetch) != nil {
            changesContinuation.yield()
            return
        }

        for pass in passes where changeInstance.changeDetails(for: pass.assets) != nil {
            changesContinuation.yield()
            return
        }
    }

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

    func fetchLibraryAssets(onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void) async -> Set<LibraryAsset> {
        let (passes, collectionFetches) = fetchPasses()
        passesLock.lock()
        lastFetchPasses = passes
        lastCollectionFetches = collectionFetches
        passesLock.unlock()
        // `PHFetchResult.count` is cheap, so the total is known before a single asset is
        // enumerated. It counts enumeration work, not distinct photos — an asset in an album is
        // visited by that album's pass and by the whole-library pass — which is why the UI shows
        // this as a bar without absolute numbers. Progress is reported once per pass rather than
        // once per asset, keeping the number of updates bounded without throttling here (W-21).
        // Totals are tracked per step (W-57) rather than as one combined figure, since the two
        // steps run one after the other rather than interleaved — a combined total would make the
        // bar jump partway through as soon as the step changes.
        let totalsByStep = Dictionary(grouping: passes) { $0.step }.mapValues { $0.reduce(0) { $0 + $1.assets.count } }
        var completedByStep: [LibraryScanStep: Int] = [:]
        var assetDict = [String: LibraryAsset]()

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

                if let existing = assetDict[asset.localIdentifier] {
                    if let collection = pass.collection, !existing.collections.contains(collection) {
                        var collections = existing.collections
                        collections.append(collection)
                        assetDict[asset.localIdentifier] = LibraryAsset(asset: asset, collections: collections)
                    }
                } else {
                    let collections = pass.collection.map { [$0] } ?? []
                    assetDict[asset.localIdentifier] = LibraryAsset(asset: asset, collections: collections)
                }
            }
            let completed = (completedByStep[pass.step] ?? 0) + pass.assets.count
            completedByStep[pass.step] = completed
            onProgress(pass.step, completed, totalsByStep[pass.step] ?? completed)
        }

        return Set(assetDict.values)
    }

    func fetchLibraryAssets(
        reusing previousSnapshot: [LibraryAssetSnapshot],
        onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void
    ) async -> Set<LibraryAsset> {
        // Nothing recorded yet — the very first scan — so every photo is "new" regardless; the
        // full walk is exactly the right amount of work, and it's the one path guaranteed to seed
        // `lastFetchPasses`/`lastCollectionFetches` properly for the live observer below.
        guard !previousSnapshot.isEmpty else {
            return await fetchLibraryAssets(onProgress: onProgress)
        }

        var previousCollectionsByID = [String: [String]](minimumCapacity: previousSnapshot.count)
        for entry in previousSnapshot {
            previousCollectionsByID[entry.localIdentifier] = entry.collectionIdentifiers
        }

        var assetDict = [String: LibraryAsset]()

        // Shared albums are usually few, so — same as a full scan — they're still walked in full:
        // exact membership and insert/delete detection without a separate diffing story for them.
        // Reported as its own step (W-57): it runs unconditionally, on every incremental scan, so
        // it's worth the UI being explicit about which part of the wait this is.
        let sharedCollectionsFetch = PHAssetCollection.fetchAssetCollections(
            with: .album, subtype: .albumCloudShared, options: nil
        )
        var sharedPasses: [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?)] = []
        sharedCollectionsFetch.enumerateObjects { collection, _, _ in
            sharedPasses.append((PHAsset.fetchAssets(in: collection, options: Self.imageOnlyOptions), collection))
        }
        let sharedTotal = sharedPasses.reduce(0) { $0 + $1.assets.count }
        onProgress(.sharedAlbums, 0, sharedTotal)
        for pass in sharedPasses {
            guard let collection = pass.collection else { continue }
            pass.assets.enumerateObjects { asset, _, _ in
                Self.mergeCollection(collection, for: asset, into: &assetDict)
            }
        }
        onProgress(.sharedAlbums, sharedTotal, sharedTotal)

        // The rest of the library is one predicate-filtered fetch (W-01), cheap regardless of how
        // many regular albums exist, and gives every remaining photo its live `PHAsset` whether or
        // not anything about it changed.
        let mainFetchOptions = PHFetchOptions()
        mainFetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        mainFetchOptions.predicate = Self.imageOnlyPredicate
        let mainLibraryFetch = PHAsset.fetchAssets(with: .image, options: mainFetchOptions)
        let localTotal = mainLibraryFetch.count
        onProgress(.localPhotos, 0, localTotal)

        var newIdentifiers = Set<String>()
        mainLibraryFetch.enumerateObjects { asset, _, _ in
            guard assetDict[asset.localIdentifier] == nil else { return }
            if previousCollectionsByID[asset.localIdentifier] == nil {
                newIdentifiers.insert(asset.localIdentifier)
            }
            // Collections are filled in below, once regular-album membership for new photos —
            // and reused membership for everyone else — has been resolved.
            assetDict[asset.localIdentifier] = LibraryAsset(asset: asset, collections: [])
        }

        // Only a scan that actually found a new photo pays for a per-regular-album walk at all
        // (W-55) — reopening the app with nothing new added since skips it entirely, which is the
        // common case this exists for. When it does run, it walks each album the same way
        // `fetchPasses()` always has (PhotoKit's supported predicate keys for `PHAsset` are
        // deliberately kept to the same handful already proven here — W-20's `mediaType` filter —
        // rather than risking an undocumented `localIdentifier IN` predicate), and just ignores
        // anything that isn't one of the new identifiers.
        if !newIdentifiers.isEmpty {
            let regularCollectionsFetch = PHAssetCollection.fetchAssetCollections(
                with: .album, subtype: .albumRegular, options: nil
            )
            regularCollectionsFetch.enumerateObjects { collection, _, _ in
                PHAsset.fetchAssets(in: collection, options: Self.imageOnlyOptions).enumerateObjects { asset, _, _ in
                    guard newIdentifiers.contains(asset.localIdentifier) else { return }
                    Self.mergeCollection(collection, for: asset, into: &assetDict)
                }
            }
        }

        // Everything else — a photo already known before this scan — keeps the album membership
        // recorded on it last time (W-54), resolved back into live `PHAssetCollection`s with one
        // batched lookup instead of one fetch per photo. Snapshotted into a plain array first:
        // `assetDict` is mutated below, and `.keys` is a live view over the same storage, not a
        // copy, so iterating it directly while writing to the dictionary is not safe.
        let keptIdentifiers = assetDict.keys.filter { !newIdentifiers.contains($0) }

        var collectionIdentifiersToResolve = Set<String>()
        for identifier in keptIdentifiers {
            collectionIdentifiersToResolve.formUnion(previousCollectionsByID[identifier] ?? [])
        }
        if !collectionIdentifiersToResolve.isEmpty {
            var resolvedCollections = [String: PHAssetCollection](minimumCapacity: collectionIdentifiersToResolve.count)
            PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: Array(collectionIdentifiersToResolve), options: nil
            ).enumerateObjects { collection, _, _ in
                resolvedCollections[collection.localIdentifier] = collection
            }
            for identifier in keptIdentifiers {
                guard let libraryAsset = assetDict[identifier], libraryAsset.collections.isEmpty else { continue }
                let collections = (previousCollectionsByID[identifier] ?? []).compactMap { resolvedCollections[$0] }
                guard !collections.isEmpty else { continue }
                assetDict[identifier] = LibraryAsset(asset: libraryAsset.asset, collections: collections)
            }
        }

        onProgress(.localPhotos, localTotal, localTotal)

        // Keeps the live, in-foreground change observer working (W-55): it can no longer notice a
        // photo moving between two regular albums it already knew about — the same trade made
        // above — but still catches a photo being added to, or removed from, the library or a
        // shared album while the app stays open.
        passesLock.lock()
        lastFetchPasses = [(assets: mainLibraryFetch, collection: nil, step: .localPhotos)]
            + sharedPasses.map { (assets: $0.assets, collection: $0.collection, step: .sharedAlbums) }
        lastCollectionFetches = [sharedCollectionsFetch]
        passesLock.unlock()

        return Set(assetDict.values)
    }

    /// Adds `collection` to whatever `asset` is already recorded under in `assetDict`, or records
    /// it fresh — the same accumulation `fetchLibraryAssets` does inline, factored out so the
    /// incremental scan above can reuse it for both its shared- and regular-album passes.
    private static func mergeCollection(
        _ collection: PHAssetCollection,
        for asset: PHAsset,
        into assetDict: inout [String: LibraryAsset]
    ) {
        if let existing = assetDict[asset.localIdentifier] {
            guard !existing.collections.contains(collection) else { return }
            assetDict[asset.localIdentifier] = LibraryAsset(asset: asset, collections: existing.collections + [collection])
        } else {
            assetDict[asset.localIdentifier] = LibraryAsset(asset: asset, collections: [collection])
        }
    }

    /// The three paths assets are pulled from, in the order that decides which album an asset
    /// present in several of them keeps: regular albums, iCloud shared albums, then everything
    /// else in the library. Each pass carries which `LibraryScanStep` it belongs to (W-57), so a
    /// caller reporting progress can say which element of the library a given pass is part of.
    private func fetchPasses() -> (
        passes: [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?, step: LibraryScanStep)],
        collectionFetches: [PHFetchResult<PHAssetCollection>]
    ) {
        var passes: [(assets: PHFetchResult<PHAsset>, collection: PHAssetCollection?, step: LibraryScanStep)] = []
        var collectionFetches: [PHFetchResult<PHAssetCollection>] = []

        for subtype in [PHAssetCollectionSubtype.albumRegular, .albumCloudShared] {
            let step: LibraryScanStep = subtype == .albumCloudShared ? .sharedAlbums : .localPhotos
            let fetchResult = PHAssetCollection.fetchAssetCollections(with: .album, subtype: subtype, options: nil)
            collectionFetches.append(fetchResult)
            fetchResult.enumerateObjects { collection, _, _ in
                let assets = PHAsset.fetchAssets(in: collection, options: Self.imageOnlyOptions)
                passes.append((assets, collection, step))
            }
        }

        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
        fetchOptions.predicate = Self.imageOnlyOptions.predicate
        passes.append((PHAsset.fetchAssets(with: .image, options: fetchOptions), nil, .localPhotos))

        return (passes, collectionFetches)
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
                PHAssetChangeRequest.deleteAssets(requestedAssets)
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
