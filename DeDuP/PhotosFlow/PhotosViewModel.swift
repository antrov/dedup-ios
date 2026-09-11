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

    /// What a grouping answers: the photo set it was built from and the settings it was built
    /// for. Grouping is the one expensive thing this screen does, and both ends of it turn on
    /// this comparison — a pass may only publish what answers the question currently on screen,
    /// and a re-group waiting behind a pass has nothing left to add when the answer on screen
    /// already matches the one it was going to produce (W-39).
    private struct Answer: Equatable {
        let assetsGeneration: Int
        let threshold: Int
        let filters: AssetsFilter
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
    private var assets = [Asset]() {
        didSet { assetsGeneration += 1 }
    }

    /// Bumped by every write to `assets` — scan, iCloud retry, deletion — so a grouping can be
    /// told apart from one built before the photo set changed under it. Counted from the property
    /// rather than from each writer so a new writer can't forget: an extra bump costs one
    /// re-group, a missed one leaves an answer on screen that no longer fits the library.
    private var assetsGeneration = 0
    /// What the grouping on screen was built from and for, or `nil` while nothing is published.
    private var publishedAnswer: Answer?
    /// Canonical, ascending order (W-31); `sorting` only decides which way it's shown.
    private var groups = [AssetsGroup]()
    private var scanTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var regroupTask: Task<Void, Never>?
    /// The most recently started scan or retry, whichever it was: the tail of the chain a new one
    /// queues behind. Kept apart from the two above, which are what a second caller joins.
    private var latestPass: Task<Void, Never>?
    private var changesTask: Task<Void, Never>?

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
        startListeningToChanges()
    }

    /// Runs a scan — or joins the one already in flight — and returns only once it has actually
    /// finished (W-41), which is what lets the pull-to-refresh gesture keep its spinner up for as
    /// long as the work lasts (B-13). Cancelling the caller cancels the scan itself, so the view
    /// disappearing stops the work (W-40).
    ///
    /// `forceFullScan` skips the incremental library walk (W-56) in favour of the exhaustive one:
    /// pull-to-refresh and the failure-screen retry both ask for it, so there's always a
    /// user-reachable way to get a from-scratch answer if the incremental one is ever wrong. A
    /// caller that joins a pass already in flight gets whatever that pass was already started
    /// with — this only decides how a *new* pass begins.
    func fetch(forceFullScan: Bool = false) async {
        let task = passToJoin(scanTask) ?? makeScanTask(forceFullScan: forceFullScan)
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
    ///
    /// Single-flight like `fetch()` (W-37): a download can take a while and nothing stops the
    /// user from tapping again, so a second call joins the pass already running instead of
    /// starting one that re-downloads the same photos and adds a second `Asset` for each of them.
    func retryCloudOnlyAssets() async {
        let task = passToJoin(retryTask) ?? makeRetryTask()
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        if retryTask == task {
            retryTask = nil
        }
    }

    /// Rebuilds `groups` from the hashes already in memory via `GroupingEngine` (W-26…W-36): no
    /// library access and no hashing, which is why a threshold change goes straight here (W-39).
    /// The filter is applied to the input set before grouping rather than inside it (W-35), and
    /// the pairing and connected-component work happens off the main actor on flat
    /// identifier/hash arrays (W-34).
    func rebuildGroups() async {
        let answer = wantedAnswer
        let filteredAssets = assets.filter { answer.filters.includes($0.libraryAsset) }
        let identifiers = filteredAssets.map(\.id)
        let hashes = filteredAssets.map(\.pHash)
        // The engine is only given what the filter let through (W-35), but what gets recorded of
        // the outcome covers every photo: one the filter excluded is one in no group, and leaving
        // its row pointing at the group it was in before makes the stored assignment contradict
        // the grouping that has just replaced it (W-36).
        let consideredIdentifiers = assets.map(\.id)
        // `uniqueKeysWithValues` would trap on a repeated identifier, taking the whole app down
        // for what is at worst a photo shown twice. `assets` is written by several paths — scan,
        // iCloud retry, deletion — and one of them slipping a duplicate through shouldn't be
        // fatal, so the first entry wins and grouping carries on.
        let assetsByID = Dictionary(filteredAssets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        enterPhase(.grouping)

        let domainGroups: [GroupingEngine.Group]
        do {
            domainGroups = try await makeGroupsOffMainActor(
                identifiers: identifiers,
                hashes: hashes,
                threshold: answer.threshold
            )
        } catch is CancellationError {
            // A fresher re-group superseded this one, or the view went away: leave the groups and
            // their persisted group_id assignments untouched. Turning "the engine didn't finish"
            // into an empty result here would write `nil` group_id for every considered
            // identifier below, wiping out the last valid assignment on every cancelled regroup.
            return
        } catch {
            state = .failed(message: error.localizedDescription, groups: state.groups)
            return
        }

        // The engine returned, but the question can have moved on since — while it ran, or while
        // the assignments below are written, which is a database round trip. Such a pass must
        // publish nothing and persist nothing: it holds the answer to the settings, or the photo
        // set, of a moment ago, and nothing orders it before the fresher pass' result (W-39).
        // Same reasoning as the `CancellationError` branch, for the cases cancellation doesn't
        // cover — a scan that started before the slider moved was never cancelled.
        guard !Task.isCancelled, answer == wantedAnswer else { return }

        // The assignment is a cache (W-14): failing to write it costs the "show the last known
        // result on launch" shortcut, never correctness.
        try? await hashStore.saveGroupAssignments(
            GroupingEngine.assignments(for: consideredIdentifiers, in: domainGroups)
        )
        guard !Task.isCancelled, answer == wantedAnswer else { return }

        groups = domainGroups
            .map { AssetsGroup(assets: $0.memberIdentifiers.compactMap { assetsByID[$0] }) }
            .sorted()
        publishedAnswer = answer
        state = .ready(groups: orderedGroups())
    }

    func deleteAsset(_ asset: Asset) async {
        do {
            try await photoLibrary.delete(asset.libraryAsset)
            // Synchronously remove the asset from the UI
            assets.removeAll { $0.id == asset.id }

            var modifiedGroupIndexes = [Int]()
            for (index, group) in groups.enumerated() where group.assets.contains(where: { $0.id == asset.id }) {
                modifiedGroupIndexes.append(index)
            }

            if !modifiedGroupIndexes.isEmpty {
                let answer = wantedAnswer
                var newDomainGroups = [GroupingEngine.Group]()
                var newConsideredIdentifiers = [String]()

                for index in modifiedGroupIndexes {
                    let oldGroup = groups[index]
                    let remainingAssets = oldGroup.assets.filter { $0.id != asset.id }

                    let filtered = remainingAssets.filter { answer.filters.includes($0.libraryAsset) }
                    let identifiers = filtered.map(\.id)
                    let hashes = filtered.map(\.pHash)

                    if let domainGroups = try? await makeGroupsOffMainActor(
                        identifiers: identifiers,
                        hashes: hashes,
                        threshold: answer.threshold
                    ) {
                        newDomainGroups.append(contentsOf: domainGroups)
                        newConsideredIdentifiers.append(contentsOf: remainingAssets.map(\.id))
                    }
                }

                for index in modifiedGroupIndexes.reversed() {
                    groups.remove(at: index)
                }

                let assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let addedGroups = newDomainGroups.map { domainGroup in
                    AssetsGroup(assets: domainGroup.memberIdentifiers.compactMap { assetsByID[$0] })
                }

                groups.append(contentsOf: addedGroups)
                groups.sort()

                try? await hashStore.saveGroupAssignments(
                    GroupingEngine.assignments(for: newConsideredIdentifiers, in: newDomainGroups)
                )
                republishGroups()
            }
        } catch {
            state = .failed(message: error.localizedDescription, groups: state.groups)
        }
    }

    private func startListeningToChanges() {
        changesTask = Task { [weak self] in
            guard let self else { return }
            for await _ in self.photoLibrary.libraryChanges {
                guard !Task.isCancelled else { break }
                // Debounce library changes
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled else { break }

                // Serialize with active scan/retry
                for ongoing in [scanTask, retryTask].compactMap({ $0 }) {
                    await ongoing.value
                }
                guard !Task.isCancelled else { break }

                await self.handleLibraryChange()
            }
        }
    }

    private func handleLibraryChange() async {
        let newLibraryAssets = await photoLibrary.fetchLibraryAssets { _, _, _ in }

        let oldAssetsByID = Dictionary(uniqueKeysWithValues: libraryAssets.map { ($0.asset.localIdentifier, $0) })
        let newAssetsByID = Dictionary(uniqueKeysWithValues: newLibraryAssets.map { ($0.asset.localIdentifier, $0) })

        let oldIDs = Set(oldAssetsByID.keys)
        let newIDs = Set(newAssetsByID.keys)

        let removedIDs = oldIDs.subtracting(newIDs)
        let insertedIDs = newIDs.subtracting(oldIDs)

        var modifiedIDs = Set<String>()
        for id in oldIDs.intersection(newIDs) {
            guard let oldAsset = oldAssetsByID[id], let newAsset = newAssetsByID[id] else { continue }
            if oldAsset.asset.modificationDate != newAsset.asset.modificationDate || oldAsset.collections != newAsset
                .collections
            {
                modifiedIDs.insert(id)
            }
        }

        libraryAssets = newLibraryAssets

        var shouldRebuild = false

        if !removedIDs.isEmpty {
            try? await hashStore.delete(identifiers: Array(removedIDs))

            var modifiedGroupIndexes = [Int]()
            for (index, group) in groups.enumerated() where group.assets.contains(where: { removedIDs.contains($0.id) }) {
                modifiedGroupIndexes.append(index)
            }

            assets.removeAll { removedIDs.contains($0.id) }

            if !modifiedGroupIndexes.isEmpty {
                let answer = wantedAnswer
                var newDomainGroups = [GroupingEngine.Group]()
                var newConsideredIdentifiers = [String]()

                for index in modifiedGroupIndexes {
                    let oldGroup = groups[index]
                    let remainingAssets = oldGroup.assets.filter { !removedIDs.contains($0.id) }

                    let filtered = remainingAssets.filter { answer.filters.includes($0.libraryAsset) }
                    let identifiers = filtered.map(\.id)
                    let hashes = filtered.map(\.pHash)

                    if let domainGroups = try? await makeGroupsOffMainActor(
                        identifiers: identifiers,
                        hashes: hashes,
                        threshold: answer.threshold
                    ) {
                        newDomainGroups.append(contentsOf: domainGroups)
                        // Include all remaining assets in considered identifiers to clear stale group_ids
                        newConsideredIdentifiers.append(contentsOf: remainingAssets.map(\.id))
                    }
                }

                for index in modifiedGroupIndexes.reversed() {
                    groups.remove(at: index)
                }

                let assetsByID = Dictionary(assets.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
                let addedGroups = newDomainGroups.map { domainGroup in
                    AssetsGroup(assets: domainGroup.memberIdentifiers.compactMap { assetsByID[$0] })
                }

                groups.append(contentsOf: addedGroups)
                groups.sort()

                try? await hashStore.saveGroupAssignments(
                    GroupingEngine.assignments(for: newConsideredIdentifiers, in: newDomainGroups)
                )
            }
            republishGroups()
        }

        if !insertedIDs.isEmpty || !modifiedIDs.isEmpty {
            let idsToProcess = insertedIDs.union(modifiedIDs)
            let assetsToProcess = newLibraryAssets.filter { idsToProcess.contains($0.asset.localIdentifier) }
            let orderedTargets = Array(assetsToProcess)

            if !modifiedIDs.isEmpty {
                try? await hashStore.delete(identifiers: Array(modifiedIDs))
                assets.removeAll { modifiedIDs.contains($0.id) }
            }

            let freshRecords = await hashingPipeline.resolveRecords(
                for: orderedTargets,
                allowsNetworkAccess: false,
                onProgress: { _, _ in }
            )

            let newAssetObjects = Asset.make(from: freshRecords, for: orderedTargets, photoLibrary: photoLibrary)
            assets.append(contentsOf: newAssetObjects)

            // For single-asset additions, we could do incremental grouping, but for now we'll just rebuild
            // to keep it simple and correct. A true incremental grouping would require GroupingEngine support.
            shouldRebuild = true
        }

        if shouldRebuild {
            await rebuildGroups()
        }

        await refreshProcessingCounts()
    }
}

// MARK: - Scan and grouping orchestration (W-37…W-40)

private extension PhotosViewModel {
    /// Starts one of the passes that own `assets` — a library scan or the iCloud retry — queued
    /// behind whichever pass was started last. Serializing them is what keeps a scan's wholesale
    /// `assets = …` from erasing what a retry merged in, and a retry's merge from being erased by
    /// a scan working off a cache snapshot taken before the download finished: which of the two
    /// happened to end last used to decide what the list contained. It also keeps them from
    /// reporting phases over each other.
    ///
    /// The pass to wait for is captured here, at creation time, rather than read inside the task.
    /// Two passes asked for at almost the same moment would otherwise each find the other already
    /// assigned by the time their bodies began, and wait for each other for good. Waiting on one
    /// chain instead of on a particular kind of pass is what makes this hold for three of them —
    /// a cancelled scan still unwinding, a retry queued behind it, and the scan that replaces it.
    ///
    /// A pending *re-group* is superseded outright instead of queued: it is grouping a snapshot
    /// this pass is about to change, and the cancellation checks in `rebuildGroups()` are what
    /// keep it from publishing or persisting anything on its way out (W-39).
    func makePass(running pass: @escaping @MainActor (PhotosViewModel) async -> Void) -> Task<Void, Never> {
        regroupTask?.cancel()

        let precedingPass = latestPass
        let task = Task { [weak self] in
            await precedingPass?.value
            guard let self, !Task.isCancelled else { return }
            await pass(self)
        }
        latestPass = task
        return task
    }

    /// The pass a caller may join, if there is one. A cancelled pass is not one: it publishes
    /// nothing on its way out, so joining it hands the caller back a scan that never ran. It
    /// stays in `scanTask` until it unwinds, and unwinding takes as long as the requests already
    /// in flight, so the lifecycle-bound caller (W-40) can easily land inside that window — a
    /// screen that goes away and comes straight back would otherwise sit on the previous visit's
    /// frozen progress until the user refreshed by hand.
    func passToJoin(_ pass: Task<Void, Never>?) -> Task<Void, Never>? {
        guard let pass, !pass.isCancelled else { return nil }
        return pass
    }

    func makeScanTask(forceFullScan: Bool) -> Task<Void, Never> {
        let task = makePass { await $0.runScan(forceFullScan: forceFullScan) }
        scanTask = task
        return task
    }

    /// One pass over the library: fetch assets, resolve their hashes (cache-first), drop cache
    /// rows for photos that are gone (W-13), then group. Cancellation is checked between phases
    /// (W-24) — an interrupted scan leaves the cache and the last published groups intact.
    func runScan(forceFullScan: Bool) async {
        guard !Task.isCancelled else { return }

        enterPhase(.requestingAuthorization)
        let status = await photoLibrary.requestAuthorization()
        guard status == .authorized || status == .limited else {
            state = .authorizationDenied
            return
        }
        // Asking for permission is the longest a scan sits still — the system prompt stays up
        // until the user answers it, and the screen can be left in the meantime. Walking the
        // whole library at that point does work nobody asked for any more, and the scan that
        // replaces this one waits behind it (W-40).
        guard !Task.isCancelled else { return }

        enterPhase(.scanningLibrary(step: .localPhotos, progress: PhaseProgress()))
        let fetchedAssets = await fetchLibraryAssets(forceFullScan: forceFullScan) { [weak self] step, completed, total in
            Task { @MainActor in
                self?.reportLibraryScanProgress(step: step, PhaseProgress(completed: completed, total: total))
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
        // A cancelled pass stopped part-way through the library, so `records` covers part of it.
        // Writing that to `assets` would leave a fraction of the library standing in for the
        // whole one, and every later answer — a threshold change, the iCloud retry — would be
        // drawn from it and presented as complete. What was hashed stays in the cache (W-24), so
        // the next scan resumes from there rather than starting over.
        guard !Task.isCancelled else { return }
        assets = Asset.make(from: records, for: orderedAssets, photoLibrary: photoLibrary)
        try? await hashStore.deleteRecords(notIn: Set(fetchedAssets.map(\.asset.localIdentifier)))
        await refreshProcessingCounts()
        guard !Task.isCancelled else { return }

        await rebuildGroups()
    }

    /// Seeds the incremental library walk from the hash cache's own inventory (W-55): every row
    /// in it already carries the identifier, and now the album membership, a previous scan last
    /// resolved for that photo, so there's nothing further to persist just for this. Falls back to
    /// the exhaustive walk outright when the cache is empty (first-ever scan, or one just cleared)
    /// or the caller demands it (pull-to-refresh, failure retry) — `PhotoLibraryService` itself
    /// also degrades to that whenever the snapshot it's handed is empty, so this mirrors rather
    /// than depends on that fallback.
    func fetchLibraryAssets(
        forceFullScan: Bool,
        onProgress: @escaping @Sendable (LibraryScanStep, Int, Int) -> Void
    ) async -> Set<LibraryAsset> {
        guard !forceFullScan else {
            return await photoLibrary.fetchLibraryAssets(onProgress: onProgress)
        }
        let previousSnapshot = ((try? await hashStore.loadAll()) ?? []).map {
            LibraryAssetSnapshot(localIdentifier: $0.localIdentifier, collectionIdentifiers: $0.collectionIdentifiers)
        }
        return await photoLibrary.fetchLibraryAssets(reusing: previousSnapshot, onProgress: onProgress)
    }

    func makeRetryTask() -> Task<Void, Never> {
        let task = makePass { await $0.runCloudOnlyRetry() }
        retryTask = task
        return task
    }

    /// One pass over the cloud-only leftovers: download and hash them with network access
    /// allowed, then add them to what is already grouped (W-19).
    func runCloudOnlyRetry() async {
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
        assets.mergeByIdentifier(Asset.make(from: freshRecords, for: orderedTargets, photoLibrary: photoLibrary))
        await refreshProcessingCounts()

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
            // A pass in flight — a scan or the iCloud retry — is still filling in `assets` and
            // reporting its own phase, so re-grouping now would publish a result for part of the
            // library and take the progress display over from it. Wait instead — both end with a
            // grouping pass anyway — and then group for whatever the threshold is by then.
            for ongoing in [scanTask, retryTask].compactMap({ $0 }) {
                await ongoing.value
            }
            guard !Task.isCancelled, hasSomethingToGroup else { return }
            // A pass that hadn't reached its own grouping yet when the change landed grouped for
            // these very settings and published the result, which leaves this one with the same
            // O(n²) search to run and the same answer to publish a second time. A pass that ended
            // without publishing — cancelled, superseded, refused, nothing to retry — leaves this
            // as the only thing that will answer the change, so the test is what was published,
            // not whether a pass happened to finish.
            guard publishedAnswer != wantedAnswer else { return }
            await rebuildGroups()
        }
    }

    /// What an answer would have to cover to be the one the screen is asking for right now.
    private var wantedAnswer: Answer {
        Answer(assetsGeneration: assetsGeneration, threshold: distanceThreshold, filters: filters)
    }

    /// Whether a re-group can produce an answer at all. The filters sheet stays reachable when
    /// access was refused, and grouping an empty library there would publish "no duplicates
    /// found" over the explanation that there was never any access — an answer to a question that
    /// was never asked. An empty *library* is a real result and still goes through (W-38), which
    /// is why this looks at the state rather than at `assets`.
    var hasSomethingToGroup: Bool {
        switch state {
        case .working, .ready, .failed:
            return true
        case .idle, .authorizationDenied:
            return false
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
    func reportLibraryScanProgress(step: LibraryScanStep, _ progress: PhaseProgress) {
        guard case .working(.scanningLibrary, _) = state else { return }
        enterPhase(.scanningLibrary(step: step, progress: progress))
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
        case let .failed(message, _):
            state = .failed(message: message, groups: orderedGroups())
        case .idle, .authorizationDenied:
            break
        }
    }

    func orderedGroups() -> [AssetsGroup] {
        sorting == .oldestToNewest ? groups : groups.reversed()
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

    func refreshProcessingCounts() async {
        let records = (try? await hashStore.loadAll()) ?? []
        processingCounts = ProcessingCounts(libraryTotal: libraryAssets.count, records: records)
    }
}
