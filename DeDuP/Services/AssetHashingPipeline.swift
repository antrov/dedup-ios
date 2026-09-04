//
//  AssetHashingPipeline.swift
//  DeDuP
//

import Foundation
import Photos

/// Turns library assets into `HashRecord`s: cache first (W-11, W-16), then bounded-concurrency
/// computation in batches that are saved as they finish (W-15, W-24), recording every outcome
/// including the failures (W-22).
///
/// Lives outside `PhotosViewModel` so the view model is left orchestrating rather than
/// computing (architecture rule 3): it has no isolation of its own, so its work runs off the
/// main actor even though the main-actor-bound view model is what calls it (W-37).
struct AssetHashingPipeline {
    /// Bounded concurrency window (W-15): the number of PhotoKit image requests in flight at
    /// once, on the order of the core count and capped well below "one request per asset", which
    /// is what used to flood PhotoKit's queue (B-05).
    private static let concurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 12)
    /// Hashes are computed and saved in batches (W-24), so an interrupted run (app killed,
    /// backgrounded, cancelled) leaves the cache further ahead than it found it, instead of an
    /// all-or-nothing pass that loses everything when interrupted.
    private static let batchSize = 500
    private static let progressUpdateInterval: TimeInterval = 0.1
    private static let progressUpdateMinDelta = 0.01

    private let hashing: ImageHashingServiceProtocol
    private let hashStore: HashStore

    init(hashing: ImageHashingServiceProtocol, hashStore: HashStore) {
        self.hashing = hashing
        self.hashStore = hashStore
    }

    /// A record for every asset in `libraryAssets`, in the same order: reused from the cache
    /// where it's still valid (W-11), computed and stored where it isn't (W-16). Assets whose
    /// hash couldn't be produced come back as records carrying the reason (W-19, W-22) rather
    /// than being quietly dropped (B-09).
    func resolveRecords(
        for libraryAssets: [LibraryAsset],
        allowsNetworkAccess: Bool,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [HashRecord] {
        let identifiers = libraryAssets.map(\.asset.localIdentifier)
        let cached = (try? await hashStore.load(identifiers: identifiers)) ?? []
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.localIdentifier, $0) })

        var recordsByID: [String: HashRecord] = [:]
        var needsHashing: [LibraryAsset] = []

        for libraryAsset in libraryAssets {
            let identifier = libraryAsset.asset.localIdentifier
            if let record = cachedByID[identifier], Self.isCacheValid(record, for: libraryAsset.asset) {
                recordsByID[identifier] = record
            } else {
                needsHashing.append(libraryAsset)
            }
        }

        let freshRecords = await computeAndSave(
            for: needsHashing,
            allowsNetworkAccess: allowsNetworkAccess,
            onProgress: onProgress
        )
        for record in freshRecords {
            recordsByID[record.localIdentifier] = record
        }

        return libraryAssets.compactMap { recordsByID[$0.asset.localIdentifier] }
    }

    /// Recomputes and stores hashes for `libraryAssets` whatever the cache already holds — the
    /// explicit "fetch what's only in iCloud" action (W-19), which is the only caller allowed to
    /// pass `allowsNetworkAccess: true` (B-06). A cloud-only entry is otherwise a perfectly valid
    /// cache entry, so a regular scan would keep skipping it.
    func recomputeRecords(
        for libraryAssets: [LibraryAsset],
        allowsNetworkAccess: Bool,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [HashRecord] {
        await computeAndSave(for: libraryAssets, allowsNetworkAccess: allowsNetworkAccess, onProgress: onProgress)
    }

    /// A cache entry is only reused when it was computed by the current pipeline version, from
    /// the asset's current contents (W-11) — both are compared, with `nil` modification dates
    /// counted as equal, so an asset never seen before never matches by accident.
    static func isCacheValid(_ record: HashRecord, for asset: PHAsset) -> Bool {
        record.hashVersion == HashingPipeline.version && record.modificationDate == asset.modificationDate
    }

    /// Computes hashes in fixed-size batches, saving each batch as soon as it finishes (W-24)
    /// and checking for cancellation between batches. Batches already saved before a cancellation
    /// stay saved, so an interrupted run still moves the work forward.
    private func computeAndSave(
        for libraryAssets: [LibraryAsset],
        allowsNetworkAccess: Bool,
        onProgress: @escaping @Sendable (Int, Int) -> Void
    ) async -> [HashRecord] {
        guard !libraryAssets.isEmpty else { return [] }

        let total = libraryAssets.count
        var completed = 0
        var lastUpdate = Date.distantPast
        var lastReportedFraction = -1.0
        var allRecords: [HashRecord] = []
        allRecords.reserveCapacity(total)

        for batchStart in stride(from: 0, to: total, by: Self.batchSize) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + Self.batchSize, total)
            let batch = Array(libraryAssets[batchStart ..< batchEnd])

            let batchRecords = await mapWithBoundedConcurrency(
                batch,
                maxConcurrency: Self.concurrency,
                onElementCompleted: {
                    completed += 1
                    // Rate-limited to ~1% of the work or ~100 ms, whichever comes first (W-21):
                    // one update per hashed photo used to be enough to keep the main thread
                    // busy doing nothing but redrawing a progress bar (B-04).
                    let now = Date()
                    let fraction = Double(completed) / Double(total)
                    let elapsed = now.timeIntervalSince(lastUpdate)
                    guard completed == total
                        || elapsed >= Self.progressUpdateInterval
                        || fraction - lastReportedFraction >= Self.progressUpdateMinDelta
                    else { return }
                    lastUpdate = now
                    lastReportedFraction = fraction
                    onProgress(completed, total)
                },
                operation: { [hashing] libraryAsset in
                    let outcome = await hashing.hash(for: libraryAsset, allowsNetworkAccess: allowsNetworkAccess)
                    return Self.makeRecord(for: libraryAsset, outcome: outcome)
                }
            )

            try? await hashStore.save(batchRecords)
            allRecords.append(contentsOf: batchRecords)
        }

        return allRecords
    }

    static func makeRecord(for libraryAsset: LibraryAsset, outcome: HashOutcome) -> HashRecord {
        let asset = libraryAsset.asset
        let state: HashRecord.State
        let phash: UInt64?
        let failureReason: String?

        switch outcome {
        case let .computed(hash):
            state = .computed
            phash = hash
            failureReason = nil
        case .cloudOnly:
            state = .cloudOnly
            phash = nil
            failureReason = nil
        case .unsupportedType:
            state = .unsupportedType
            phash = nil
            failureReason = nil
        case let .failed(reason):
            state = .failed
            phash = nil
            failureReason = reason
        }

        return HashRecord(
            localIdentifier: asset.localIdentifier,
            phash: phash,
            hashVersion: HashingPipeline.version,
            modificationDate: asset.modificationDate,
            creationDate: asset.creationDate,
            state: state,
            failureReason: failureReason,
            groupID: nil,
            updatedAt: Date()
        )
    }
}
