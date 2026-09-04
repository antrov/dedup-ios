//
//  PhotosViewModel.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos

/// Orchestrates the flow — library fetch, hashing, grouping — and owns the screen's state.
/// Bound to the main actor (W-37): every published mutation happens here, on the main actor,
/// while the expensive work runs inside the services and `GroupingEngine`, which are called from
/// here but execute off it (W-34). Nothing mutates this object from a detached task any more,
/// so the state SwiftUI reads is no longer raced against (B-11).
@MainActor
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

    @Published private(set) var state: PhotosScreenState = .idle
    @Published private(set) var processingCounts = ProcessingCounts()

    /// Hamming distance at or below which two photos count as similar (W-03). Changing it only
    /// re-groups the hashes already in memory (W-39): hashes don't depend on the threshold, so
    /// nothing is ever re-hashed because of a slider move.
    @Published var distanceThreshold = 4 {
        didSet {
            guard distanceThreshold != oldValue else { return }
            scheduleRegroup()
        }
    }

    /// Applied when building the arrays handed to grouping (W-35), never inside the grouping
    /// loop, so a filtered-out photo doesn't cost a single comparison.
    @Published var filters: AssetsFilter = [.iCloudIncluded] {
        didSet {
            guard filters != oldValue else { return }
            scheduleRegroup()
        }
    }

    /// Display order only: `groups` is kept in one canonical order (W-31) and reversed for
    /// display, so flipping this never re-groups anything.
    @Published var sorting = GroupsSorting.oldestToNewest {
        didSet {
            guard sorting != oldValue else { return }
            republishGroups()
        }
    }

    private let photoLibrary: PhotoLibraryServiceProtocol
    private let hashStore: HashStore
    private let groupingEngine: GroupingEngine
    private let hashingPipeline: AssetHashingPipeline

    /// Debounce for threshold and filter changes (W-39): a slider drag emits a value per pixel,
    /// and without this each one would start its own full re-group, all of them publishing their
    /// result whenever they happened to finish.
    private static let regroupDebounce = Duration.milliseconds(250)

    private var libraryAssets = Set<LibraryAsset>()
    private var assets = [Asset]()
    /// Canonical, ascending order (W-31); `sorting` only decides which way it's shown.
    private var groups = [AssetsGroup]()
    private var scanTask: Task<Void, Never>?
    private var regroupTask: Task<Void, Never>?

    /// Real services by default; pass fakes conforming to the same protocols for previews/tests.
    /// Deliberately starts no work: scanning is driven by the view's lifecycle (W-40), so
    /// creating this object — in a preview, in a test, or in a view body that gets re-evaluated —
    /// never asks for photo permissions or kicks off a scan on its own.
    init(
        photoLibrary: PhotoLibraryServiceProtocol = PhotoLibraryService(),
        hashing: ImageHashingServiceProtocol = ImageHashingService(),
        hashStore: HashStore = SQLiteHashStore(database: .openOnDiskOrInMemory()),
        groupingEngine: GroupingEngine = GroupingEngine()
    ) {
        self.photoLibrary = photoLibrary
        self.hashStore = hashStore
        self.groupingEngine = groupingEngine
        hashingPipeline = AssetHashingPipeline(hashing: hashing, hashStore: hashStore)
    }

    /// Runs a full scan — or joins the one already in flight — and returns only once it has
    /// actually finished (W-41), which is what lets the pull-to-refresh gesture keep its spinner
    /// up for as long as the work lasts (B-13). Cancelling the caller cancels the scan itself,
    /// so the view disappearing stops the work (W-40).
    func fetch() async {
        let task = scanTask ?? makeScanTask()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if scanTask == task {
            scanTask = nil
        }
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

        enterPhase(.hashingImages(PhaseProgress(completed: 0, total: targets.count)))
        let orderedTargets = Array(targets)
        let freshRecords = await hashingPipeline.recomputeRecords(
            for: orderedTargets,
            allowsNetworkAccess: true,
            onProgress: hashingProgressHandler()
        )
        assets.append(contentsOf: Self.makeAssets(from: freshRecords, for: orderedTargets, photoLibrary: photoLibrary))
        await refreshProcessingCounts()

        await rebuildGroups()
    }

    /// Rebuilds `groups` from the hashes already in memory via `GroupingEngine` (W-26…W-36): no
    /// library access and no hashing, which is why a threshold change goes straight here (W-39).
    /// The filter is applied to the input set before grouping rather than inside it (W-35), and
    /// the pairing and connected-component work happens off the main actor on flat
    /// identifier/hash arrays (W-34).
    func rebuildGroups() async {
        let filteredAssets = assets.filter { Self.isIncluded(asset: $0.libraryAsset, filters: filters) }
        let identifiers = filteredAssets.map(\.id)
        let hashes = filteredAssets.map(\.pHash)
        let threshold = distanceThreshold
        let assetsByID = Dictionary(uniqueKeysWithValues: filteredAssets.map { ($0.id, $0) })

        enterPhase(.grouping)

        let domainGroups: [GroupingEngine.Group]
        do {
            domainGroups = try await makeGroupsOffMainActor(identifiers: identifiers, hashes: hashes, threshold: threshold)
        } catch is CancellationError {
            // A fresher re-group superseded this one, or the view went away: leave the groups and
            // their persisted group_id assignments untouched. Turning "the engine didn't finish"
            // into an empty result here would write `nil` group_id for every considered
            // identifier below, wiping out the last valid assignment on every cancelled regroup.
            return
        } catch {
            state = .failed(message: error.localizedDescription)
            return
        }

        // The assignment is a cache (W-14): failing to write it costs the "show the last known
        // result on launch" shortcut, never correctness.
        try? await hashStore.saveGroupAssignments(Self.groupAssignments(for: identifiers, in: domainGroups))

        groups = domainGroups
            .map { AssetsGroup(assets: $0.memberIdentifiers.compactMap { assetsByID[$0] }) }
            .sorted()
        state = .ready(groups: orderedGroups())
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
}

// MARK: - Scan and grouping orchestration (W-37…W-40)

private extension PhotosViewModel {
    func makeScanTask() -> Task<Void, Never> {
        let task = Task { [weak self] in
            guard let self else { return }
            await runScan()
        }
        scanTask = task
        return task
    }

    /// One pass over the library: fetch assets, resolve their hashes (cache-first), drop cache
    /// rows for photos that are gone (W-13), then group. Cancellation is checked between phases
    /// (W-24) — an interrupted scan leaves the cache and the last published groups intact.
    func runScan() async {
        guard !Task.isCancelled else { return }

        state = .requestingAuthorization
        let status = await photoLibrary.requestAuthorization()
        guard status == .authorized || status == .limited else {
            state = .authorizationDenied
            return
        }

        enterPhase(.scanningLibrary(PhaseProgress()))
        let fetchedAssets = await photoLibrary.fetchLibraryAssets { [weak self] completed, total in
            Task { @MainActor in
                self?.reportLibraryScanProgress(PhaseProgress(completed: completed, total: total))
            }
        }
        guard !Task.isCancelled else { return }
        libraryAssets = fetchedAssets

        enterPhase(.hashingImages(PhaseProgress(completed: 0, total: fetchedAssets.count)))
        let orderedAssets = Array(fetchedAssets)
        let records = await hashingPipeline.resolveRecords(
            for: orderedAssets,
            allowsNetworkAccess: false,
            onProgress: hashingProgressHandler()
        )
        assets = Self.makeAssets(from: records, for: orderedAssets, photoLibrary: photoLibrary)
        try? await hashStore.deleteRecords(notIn: Set(fetchedAssets.map(\.asset.localIdentifier)))
        await refreshProcessingCounts()
        guard !Task.isCancelled else { return }

        await rebuildGroups()
    }

    /// Re-groups after a debounce, cancelling whatever re-group was already pending or running
    /// (W-39): dragging the threshold slider must end in exactly one published result, the one
    /// for the value the finger stopped on.
    func scheduleRegroup() {
        regroupTask?.cancel()
        regroupTask = Task { [weak self] in
            try? await Task.sleep(for: Self.regroupDebounce)
            guard !Task.isCancelled, let self else { return }
            // A scan in flight is still filling in `assets` and reporting its own phase, so
            // re-grouping now would publish a result for part of the library and take the
            // progress display over from the scan. Wait for it instead — it ends with a
            // grouping pass anyway — and then group for whatever the threshold is by then.
            if let scanTask {
                await scanTask.value
                guard !Task.isCancelled else { return }
            }
            await rebuildGroups()
        }
    }

    /// Runs the grouping engine off the main actor (W-34) while keeping the caller's structured
    /// cancellation: `Task.detached` deliberately has no parent, so cancelling the surrounding
    /// task doesn't reach it on its own — and an un-cancelled engine would keep an obsolete
    /// re-group running to completion on every slider move.
    func makeGroupsOffMainActor(identifiers: [String], hashes: [UInt64], threshold: Int) async throws -> [GroupingEngine.Group] {
        let task = Task.detached(priority: .userInitiated) { [groupingEngine] in
            try await groupingEngine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: threshold)
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    /// Enters `phase` while keeping whatever is already on screen (W-38).
    func enterPhase(_ phase: PhotosScreenState.Phase) {
        state = .working(phase: phase, groups: state.groups)
    }

    /// Dropped once the scan has moved on: the library fetch reports its last pass shortly after
    /// hashing has already started, and re-entering the previous phase would rewind the bar.
    func reportLibraryScanProgress(_ progress: PhaseProgress) {
        guard case .working(.scanningLibrary, _) = state else { return }
        enterPhase(.scanningLibrary(progress))
    }

    func reportHashingProgress(_ progress: PhaseProgress) {
        guard case .working(.hashingImages, _) = state else { return }
        enterPhase(.hashingImages(progress))
    }

    /// Re-publishes the current groups in the current sort direction, without re-grouping.
    func republishGroups() {
        switch state {
        case .ready:
            state = .ready(groups: orderedGroups())
        case let .working(phase, _):
            state = .working(phase: phase, groups: orderedGroups())
        case .idle, .requestingAuthorization, .authorizationDenied, .failed:
            break
        }
    }

    func orderedGroups() -> [AssetsGroup] {
        sorting == .oldestToNewest ? groups : groups.reversed()
    }

    static func isIncluded(asset: LibraryAsset, filters: AssetsFilter) -> Bool {
        filters.contains(.iCloudIncluded) || asset.asset.sourceType != .typeCloudShared
    }

    /// Every considered identifier mapped to its new group id, or `nil` if it didn't end up in
    /// any group (W-36) — written back in the same single batched call so an identifier dropped
    /// from a group doesn't keep pointing at one that no longer contains it.
    static func groupAssignments(
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
}

// MARK: - Hashing results (W-21, W-22, W-43)

private extension PhotosViewModel {
    /// Bridges the pipeline's progress callbacks — raised from whichever thread finished a hash —
    /// back onto the main actor (W-21, W-37). Already rate-limited by the pipeline, so this hops
    /// on the order of a hundred times per scan, not once per photo (B-04).
    func hashingProgressHandler() -> @Sendable (Int, Int) -> Void {
        { [weak self] completed, total in
            Task { @MainActor in
                self?.reportHashingProgress(PhaseProgress(completed: completed, total: total))
            }
        }
    }

    /// Maps the pipeline's records onto the UI models, on the main actor (W-34). Only records
    /// that actually produced a hash become assets: cloud-only, unsupported and failed ones stay
    /// in the cache and are reported as counts (W-22, W-43) instead of silently reaching
    /// grouping as if they had been compared.
    static func makeAssets(
        from records: [HashRecord],
        for libraryAssets: [LibraryAsset],
        photoLibrary: PhotoLibraryServiceProtocol
    ) -> [Asset] {
        let assetsByID = Dictionary(uniqueKeysWithValues: libraryAssets.map { ($0.asset.localIdentifier, $0) })
        return records.compactMap { record in
            guard record.state == .computed, let phash = record.phash,
                  let libraryAsset = assetsByID[record.localIdentifier] else { return nil }
            return Asset(libraryAsset: libraryAsset, pHash: phash, photoLibrary: photoLibrary)
        }
    }

    func refreshProcessingCounts() async {
        let all = (try? await hashStore.loadAll()) ?? []
        var counts = ProcessingCounts(libraryTotal: libraryAssets.count)
        for record in all {
            switch record.state {
            case .computed: counts.computed += 1
            case .cloudOnly: counts.cloudOnly += 1
            case .failed: counts.failed += 1
            case .unsupportedType: counts.unsupportedType += 1
            }
        }
        processingCounts = counts
    }
}
