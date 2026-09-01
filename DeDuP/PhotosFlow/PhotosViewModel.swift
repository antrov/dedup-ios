//
//  PhotosViewModel.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos

final class PhotosViewModel: ObservableObject {
    enum GroupsSorting {
        case newestToOldest
        case oldestToNewest

        mutating func toggle() {
            self = self == .newestToOldest ? .oldestToNewest : .newestToOldest
        }
    }

    struct AssetsFilter: OptionSet {
        let rawValue: UInt

        static let iCloudIncluded = AssetsFilter(rawValue: 1 << 0)
    }

    /// Current phase of a scan (W-21), so progress can be reported per-phase instead of as one
    /// undifferentiated number that means something different depending on when you look at it.
    enum ScanPhase: Equatable {
        case idle
        case scanningLibrary
        case hashingImages
        case grouping
    }

    /// How many of the assets last seen in the library ended up in each processing state
    /// (W-19, W-22) — shown in the UI so "no duplicates found" can be told apart from "half the
    /// library hasn't been processed yet".
    struct ProcessingCounts: Equatable {
        var total = 0
        var computed = 0
        var cloudOnly = 0
        var failed = 0
        var unsupportedType = 0
    }

    @Published private(set) var assetsGroups = [AssetsGroup]()
    @Published var distanceThreshold: Int = 4
    @Published private(set) var progress: Double = 0.0
    @Published private(set) var scanPhase: ScanPhase = .idle
    @Published private(set) var processingCounts = ProcessingCounts()
    @Published var sorting = GroupsSorting.oldestToNewest {
        didSet { applySorting() }
    }

    @Published var filters: AssetsFilter = [.iCloudIncluded] {
        didSet { Task { await self.rebuildGroups() } }
    }

    private let photoLibrary: PhotoLibraryServiceProtocol
    private let hashing: ImageHashingServiceProtocol
    private let hashStore: HashStore
    private let groupingEngine: GroupingEngine

    /// Bounded concurrency window for hash computation (W-15): the number of PhotoKit image
    /// requests in flight at once, on the order of the core count and capped well below "one
    /// request per asset", which is what used to flood PhotoKit's queue (B-05).
    private static let hashingConcurrency = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), 12)
    /// Hashes are computed and saved in batches (W-24), so an interrupted scan (app killed,
    /// backgrounded, cancelled) leaves the cache further ahead than it found it, instead of an
    /// all-or-nothing run that loses everything when interrupted.
    private static let hashingBatchSize = 500
    private static let progressUpdateInterval: TimeInterval = 0.1
    private static let progressUpdateMinDelta = 0.01

    private var libraryAssets = Set<LibraryAsset>()
    private var assets = [Asset]()
    private var groups = [AssetsGroup]()

    /// Real services by default; pass fakes conforming to the same protocols for previews/tests.
    init(
        photoLibrary: PhotoLibraryServiceProtocol = PhotoLibraryService(),
        hashing: ImageHashingServiceProtocol = ImageHashingService(),
        hashStore: HashStore = SQLiteHashStore(database: .openOnDiskOrInMemory()),
        groupingEngine: GroupingEngine = GroupingEngine()
    ) {
        self.photoLibrary = photoLibrary
        self.hashing = hashing
        self.hashStore = hashStore
        self.groupingEngine = groupingEngine
        Task.detached {
            await self.fetch()
        }
    }

    func fetch() async {
        guard await photoLibrary.requestAuthorization() == .authorized else { return }

        await setScanPhase(.scanningLibrary)
        let fetchedAssets = await photoLibrary.fetchLibraryAssets()
        libraryAssets = fetchedAssets

        await setScanPhase(.hashingImages)
        await setProgress(0)
        assets = await hashAssets(fetchedAssets, allowsNetworkAccess: false)
        try? await hashStore.deleteRecords(notIn: Set(fetchedAssets.map(\.asset.localIdentifier)))
        await refreshProcessingCounts()

        await setScanPhase(.grouping)
        await rebuildGroups()
        await setScanPhase(.idle)
    }

    /// Explicit, user-initiated retry for assets that were skipped because they're only stored in
    /// iCloud (W-19) — the only place a hashing request is allowed to hit the network (B-06). A
    /// regular scan never retries these on its own, since a cloud-only cache entry is otherwise
    /// still valid per W-11 and would just be skipped again.
    func retryCloudOnlyAssets() async {
        let cached = (try? await hashStore.loadAll()) ?? []
        let cloudOnlyIDs = Set(cached.filter { $0.state == .cloudOnly }.map(\.localIdentifier))
        let targets = libraryAssets.filter { cloudOnlyIDs.contains($0.asset.localIdentifier) }
        guard !targets.isEmpty else { return }

        await setScanPhase(.hashingImages)
        await setProgress(0)
        let freshRecords = await computeHashes(for: Array(targets), allowsNetworkAccess: true)
        try? await hashStore.save(freshRecords)

        let byIdentifier = Dictionary(uniqueKeysWithValues: targets.map { ($0.asset.localIdentifier, $0) })
        let newAssets = freshRecords.compactMap { record -> Asset? in
            guard record.state == .computed, let phash = record.phash,
                  let libraryAsset = byIdentifier[record.localIdentifier] else { return nil }
            return Asset(libraryAsset: libraryAsset, pHash: phash, photoLibrary: photoLibrary)
        }
        assets.append(contentsOf: newAssets)
        await refreshProcessingCounts()

        await setScanPhase(.grouping)
        await rebuildGroups()
        await setScanPhase(.idle)
    }

    /// Rebuilds `groups` from the currently loaded `assets` via `GroupingEngine` (W-26…W-36):
    /// the filter is applied to the input set before grouping rather than inside it (W-35), the
    /// actual pairing and connected-component work happens off the main actor on flat
    /// identifier/hash arrays (W-34), and only the finished result is mapped back onto
    /// `Asset`/`AssetsGroup` here.
    func rebuildGroups() async {
        let filteredAssets = assets.filter { Self.isIncluded(asset: $0.libraryAsset, filters: filters) }
        let identifiers = filteredAssets.map(\.id)
        let hashes = filteredAssets.map(\.pHash)
        let threshold = distanceThreshold
        let assetsByID = Dictionary(uniqueKeysWithValues: filteredAssets.map { ($0.id, $0) })

        let domainGroups = (try? await Task.detached(priority: .userInitiated) { [groupingEngine] in
            try await groupingEngine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: threshold)
        }.value) ?? []

        try? await hashStore.saveGroupAssignments(Self.groupAssignments(for: identifiers, in: domainGroups))

        groups = domainGroups
            .map { AssetsGroup(assets: $0.memberIdentifiers.compactMap { assetsByID[$0] }) }
            .sorted()
        applySorting()
    }

    /// Every considered identifier mapped to its new group id, or `nil` if it didn't end up in
    /// any group (W-36) — written back in the same single batched call so an identifier dropped
    /// from a group doesn't keep pointing at one that no longer contains it.
    private static func groupAssignments(
        for identifiers: [String],
        in domainGroups: [GroupingEngine.Group]
    ) -> [String: String?] {
        var groupIDByIdentifier: [String: String] = [:]
        for domainGroup in domainGroups {
            for identifier in domainGroup.memberIdentifiers {
                groupIDByIdentifier[identifier] = domainGroup.id
            }
        }
        return Dictionary(uniqueKeysWithValues: identifiers.map { ($0, groupIDByIdentifier[$0]) })
    }

    func deleteAsset(_ asset: Asset) async {
        do {
            try await photoLibrary.delete(asset.libraryAsset)
        } catch {
            print(error)
        }
        assets.removeAll { $0 == asset }
        await rebuildGroups()
    }

    private func applySorting() {
        DispatchQueue.main.async {
            self.assetsGroups = self.sorting == .oldestToNewest ? self.groups : self.groups.reversed()
        }
    }

    private static func isIncluded(asset: LibraryAsset, filters: AssetsFilter) -> Bool {
        filters.contains(.iCloudIncluded) || asset.asset.sourceType != .typeCloudShared
    }
}

// MARK: - Hashing pipeline (W-15…W-25)

private extension PhotosViewModel {
    /// Resolves hashes for `libraryAssets`: reuses valid cache entries (W-16), computes the rest
    /// with bounded concurrency (W-15), and returns only the ones that produced a usable hash.
    /// Cloud-only, unsupported, and failed entries stay recorded in the cache (W-19, W-22) but are
    /// excluded from the returned assets, so they never silently reach grouping.
    func hashAssets(_ libraryAssets: Set<LibraryAsset>, allowsNetworkAccess: Bool) async -> [Asset] {
        let orderedAssets = Array(libraryAssets)
        let identifiers = orderedAssets.map(\.asset.localIdentifier)
        let cached = (try? await hashStore.load(identifiers: identifiers)) ?? []
        let cachedByID = Dictionary(uniqueKeysWithValues: cached.map { ($0.localIdentifier, $0) })

        var recordsByID: [String: HashRecord] = [:]
        var needsHashing: [LibraryAsset] = []

        for libraryAsset in orderedAssets {
            let identifier = libraryAsset.asset.localIdentifier
            if let record = cachedByID[identifier], Self.isCacheValid(record, for: libraryAsset.asset) {
                recordsByID[identifier] = record
            } else {
                needsHashing.append(libraryAsset)
            }
        }

        let freshRecords = await computeHashes(for: needsHashing, allowsNetworkAccess: allowsNetworkAccess)
        for record in freshRecords {
            recordsByID[record.localIdentifier] = record
        }

        return orderedAssets.compactMap { libraryAsset in
            guard let record = recordsByID[libraryAsset.asset.localIdentifier],
                  record.state == .computed, let phash = record.phash else { return nil }
            return Asset(libraryAsset: libraryAsset, pHash: phash, photoLibrary: photoLibrary)
        }
    }

    /// A cache entry is only reused when it was computed by the current pipeline version, from
    /// the asset's current contents (W-11) — both are compared, with `nil` modification dates
    /// counted as equal, so an asset never seen before never matches by accident.
    static func isCacheValid(_ record: HashRecord, for asset: PHAsset) -> Bool {
        record.hashVersion == HashingPipeline.version && record.modificationDate == asset.modificationDate
    }

    /// Computes hashes for `libraryAssets` in fixed-size batches, saving each batch to the cache
    /// as soon as it finishes (W-24) and checking for cancellation between batches. Batches already
    /// saved before a cancellation stay saved, so an interrupted scan still leaves the cache
    /// further ahead than it found it.
    func computeHashes(for libraryAssets: [LibraryAsset], allowsNetworkAccess: Bool) async -> [HashRecord] {
        guard !libraryAssets.isEmpty else { return [] }

        let total = libraryAssets.count
        var completed = 0
        var lastUpdate = Date.distantPast
        var lastReportedFraction = -1.0
        var allRecords: [HashRecord] = []
        allRecords.reserveCapacity(total)

        for batchStart in stride(from: 0, to: total, by: Self.hashingBatchSize) {
            guard !Task.isCancelled else { break }
            let batchEnd = min(batchStart + Self.hashingBatchSize, total)
            let batch = Array(libraryAssets[batchStart ..< batchEnd])

            let batchRecords = await mapWithBoundedConcurrency(
                batch,
                maxConcurrency: Self.hashingConcurrency,
                onElementCompleted: { [self] in
                    completed += 1
                    let now = Date()
                    let fraction = Double(completed) / Double(total)
                    let elapsed = now.timeIntervalSince(lastUpdate)
                    guard completed == total
                        || elapsed >= Self.progressUpdateInterval
                        || fraction - lastReportedFraction >= Self.progressUpdateMinDelta
                    else { return }
                    lastUpdate = now
                    lastReportedFraction = fraction
                    await setProgress(fraction)
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

    func refreshProcessingCounts() async {
        let all = (try? await hashStore.loadAll()) ?? []
        var counts = ProcessingCounts(total: all.count)
        for record in all {
            switch record.state {
            case .computed: counts.computed += 1
            case .cloudOnly: counts.cloudOnly += 1
            case .failed: counts.failed += 1
            case .unsupportedType: counts.unsupportedType += 1
            }
        }
        await setProcessingCounts(counts)
    }

    @MainActor
    func setScanPhase(_ phase: ScanPhase) {
        scanPhase = phase
    }

    @MainActor
    func setProgress(_ value: Double) {
        progress = value
    }

    @MainActor
    func setProcessingCounts(_ counts: ProcessingCounts) {
        processingCounts = counts
    }
}
