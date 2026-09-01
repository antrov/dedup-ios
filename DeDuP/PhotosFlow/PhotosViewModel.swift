//
//  PhotosViewModel.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import CocoaImageHashing
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
        didSet { Task.detached { self.rebuildGroups() } }
    }

    private let photoLibrary: PhotoLibraryServiceProtocol
    private let hashing: ImageHashingServiceProtocol
    private let hashStore: HashStore

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
        hashStore: HashStore = SQLiteHashStore(database: .openOnDiskOrInMemory())
    ) {
        self.photoLibrary = photoLibrary
        self.hashing = hashing
        self.hashStore = hashStore
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
        rebuildGroups()
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
            return Asset(libraryAsset: libraryAsset, pHash: OSHashType(bitPattern: phash), photoLibrary: photoLibrary)
        }
        assets.append(contentsOf: newAssets)
        await refreshProcessingCounts()

        await setScanPhase(.grouping)
        rebuildGroups()
        await setScanPhase(.idle)
    }

    func rebuildGroups() {
        groups = groupAssets(assets, by: distanceThreshold, filters: filters).sorted()
        applySorting()
    }

    func deleteAsset(_ asset: Asset) async {
        do {
            try await photoLibrary.delete(asset.libraryAsset)
        } catch {
            print(error)
        }
        assets.removeAll { $0 == asset }
        rebuildGroups()
    }

    private func applySorting() {
        DispatchQueue.main.async {
            self.assetsGroups = self.sorting == .oldestToNewest ? self.groups : self.groups.reversed()
        }
    }

    private func groupAssets(_ assets: [Asset], by maxDistance: Int, filters: AssetsFilter) -> [AssetsGroup] {
        let threshold = OSHashDistanceType(maxDistance)
        return assets
            .enumerated()
            .reduce([AssetsGroup]()) { groups, element in
                let asset = element.element
                let index = element.offset
                DispatchQueue.main.async {
                    self.progress = Double(index) / Double(assets.count)
                }

                guard Self.isIncluded(asset: asset.libraryAsset, filters: filters) else { return groups }
                var groups = groups
                if let nearest = groups.nearestGroup(to: asset.pHash, using: hashing), nearest.distance <= threshold {
                    nearest.group.addAsset(asset)
                } else {
                    groups.append(AssetsGroup(asset: asset))
                }
                return groups
            }
            .filter { $0.assets.count > 1 }
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
            return Asset(libraryAsset: libraryAsset, pHash: OSHashType(bitPattern: phash), photoLibrary: photoLibrary)
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

private extension Array where Element == AssetsGroup {
    func nearestGroup(
        to pHash: OSHashType,
        using hashing: ImageHashingServiceProtocol
    ) -> (group: AssetsGroup, distance: OSHashDistanceType)? {
        let distances = map { group in
            group.assets.first.map { hashing.distance($0.pHash, pHash) } ?? OSHashDistanceType.max
        }
        guard let offset = distances.indices.min(by: { distances[$0] < distances[$1] }) else { return nil }
        return (self[offset], distances[offset])
    }
}
