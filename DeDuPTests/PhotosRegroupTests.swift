//
//  PhotosRegroupTests.swift
//  DeDuPTests
//

import Combine
@testable import DeDuP
import Photos
import XCTest

/// W-39: what a threshold or filter change is allowed to cost, and which pass is allowed to
/// publish the result. Hashes don't depend on either, so a change re-groups what is already in
/// memory — exactly once, for the value the finger stopped on, and never over a fresher pass.
@MainActor
final class PhotosRegroupTests: XCTestCase {
    func testThresholdChangeRegroupsWithoutRehashing() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
        await viewModel.fetch()

        let hashCallsAfterScan = await hashing.hashCallCount
        let groupingsAfterScan = pairFinder.callCount

        viewModel.distanceThreshold = 8
        await waitUntil(
            { pairFinder.callCount > groupingsAfterScan },
            message: "a threshold change should trigger a re-group"
        )

        let hashCallsAfterThresholdChange = await hashing.hashCallCount
        XCTAssertEqual(hashCallsAfterThresholdChange, hashCallsAfterScan, "hashes don't depend on the threshold")
    }

    /// The debounce is what keeps a slider drag from starting — and publishing — one re-group per
    /// pixel of movement.
    func testRapidThresholdChangesCollapseIntoOneRegroup() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
        await viewModel.fetch()
        let groupingsAfterScan = pairFinder.callCount

        for threshold in 5 ... 12 {
            viewModel.distanceThreshold = threshold
        }
        await waitUntil(
            { pairFinder.callCount > groupingsAfterScan },
            message: "the last threshold value should still be grouped"
        )
        // Give any (wrongly) surviving debounced re-group time to land before counting.
        try? await Task.sleep(for: .milliseconds(600))

        XCTAssertEqual(
            pairFinder.callCount - groupingsAfterScan,
            1,
            "eight threshold values in a row should produce exactly one re-group, for the last one"
        )
    }

    func testFilterChangeRegroupsWithoutRehashing() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
        await viewModel.fetch()

        let hashCallsAfterScan = await hashing.hashCallCount
        let groupingsAfterScan = pairFinder.callCount

        viewModel.filters = []
        await waitUntil(
            { pairFinder.callCount > groupingsAfterScan },
            message: "a filter change should trigger a re-group"
        )

        let hashCallsAfterFilterChange = await hashing.hashCallCount
        XCTAssertEqual(hashCallsAfterFilterChange, hashCallsAfterScan, "hashes don't depend on the filters")
    }

    /// A threshold change while the scan is still hashing must not publish a result built from
    /// the part of the library that happens to be hashed already, nor take the progress display
    /// over from the scan (W-38).
    func testThresholdChangeDuringScanWaitsForIt() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        hashing.delay = .seconds(1)

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
        let scan = Task { await viewModel.fetch() }
        await waitUntil({ isHashing(viewModel.state) }, message: "the scan should reach its hashing phase")

        viewModel.distanceThreshold = 9
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(
            isHashing(viewModel.state),
            "the scan should still own the phase while it hashes, got \(viewModel.state)"
        )

        await scan.value
        await waitUntil({ isReady(viewModel.state) }, message: "the deferred re-group should publish a result")
    }

    /// The debounce cancels the pass it supersedes, but cancellation can also arrive *after* the
    /// engine returned, while the group assignment is being written. Such a pass holds the
    /// previous threshold's result and nothing orders it before the fresher one, so it must
    /// publish nothing rather than briefly — or, if the write is slow enough, lastingly — put an
    /// obsolete grouping on screen.
    func testRegroupCancelledWhilePersistingDoesNotPublish() async {
        let first = makeLibraryAsset()
        let second = makeLibraryAsset()
        let hashStore = HashStoreMock()
        // Six bits apart: one group at a threshold of 6, none at 5 or at the default of 4.
        hashStore.records = [
            first.asset.localIdentifier: makeHashRecord(identifier: first.asset.localIdentifier, phash: 0),
            second.asset.localIdentifier: makeHashRecord(identifier: second.asset.localIdentifier, phash: 0b111111)
        ]
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [first, second]

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashStore: hashStore)
        await viewModel.fetch()
        XCTAssertTrue(viewModel.state.groups.isEmpty, "six bits apart is beyond the default threshold")

        var readyPublishes = 0
        let subscription = viewModel.$state.sink { state in
            if case .ready = state {
                readyPublishes += 1
            }
        }
        defer { subscription.cancel() }
        readyPublishes = 0

        hashStore.saveGroupAssignmentsDelay = .seconds(1)
        viewModel.distanceThreshold = 5
        // Past the debounce and into the persistence await of the pass for 5, then supersede it.
        try? await Task.sleep(for: .milliseconds(500))
        viewModel.distanceThreshold = 6

        await waitUntil(
            { !viewModel.state.groups.isEmpty },
            message: "the re-group for the threshold the finger stopped on should publish its result"
        )
        XCTAssertEqual(readyPublishes, 1, "a superseded pass must not publish the previous threshold's grouping")
    }

    /// The gear button has no condition on the state, so the filters sheet — and its slider — is
    /// reachable after a refused permission. Grouping the library that was never read would
    /// answer "no duplicates found", which is not a weaker answer than "no access to photos" but
    /// a false one.
    func testThresholdChangeAfterRefusedAccessKeepsExplainingTheRefusal() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.authorizationStatus = .denied
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary)
        await viewModel.fetch()
        XCTAssertEqual(viewModel.state, .authorizationDenied)

        viewModel.distanceThreshold = 9
        // Well past the debounce, so a re-group that was going to run has run by now.
        try? await Task.sleep(for: .milliseconds(700))

        XCTAssertEqual(viewModel.state, .authorizationDenied, "a refused library must not report a scan result")
    }

    /// A scan replaces `assets` wholesale, so a re-group already in flight is grouping a snapshot
    /// that is about to stop being true. Left running, it publishes its pre-refresh result — and
    /// if its own persistence outlasts the scan, that result is what stays on screen.
    func testScanSupersedesARegroupAlreadyInFlight() async {
        let staying = makeLibraryAsset()
        let removed = makeLibraryAsset()
        let hashStore = HashStoreMock()
        hashStore.records = [
            staying.asset.localIdentifier: makeHashRecord(identifier: staying.asset.localIdentifier, phash: 0),
            removed.asset.localIdentifier: makeHashRecord(identifier: removed.asset.localIdentifier, phash: 0b111111)
        ]
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [staying, removed]

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashStore: hashStore)
        await viewModel.fetch()
        XCTAssertTrue(viewModel.state.groups.isEmpty)

        var readyPublishes = 0
        let subscription = viewModel.$state.sink { state in
            if case .ready = state {
                readyPublishes += 1
            }
        }
        defer { subscription.cancel() }
        readyPublishes = 0

        // Park the re-group for 6 inside its persistence await, holding the group it found for
        // the two photos that were in the library when it started.
        hashStore.saveGroupAssignmentsDelay = .seconds(2)
        viewModel.distanceThreshold = 6
        try? await Task.sleep(for: .milliseconds(500))

        // One of them is gone by the time the user pulls to refresh, so the scan's own result —
        // a single photo, no group — differs from what the parked pass is holding.
        photoLibrary.libraryAssets = [staying]
        hashStore.saveGroupAssignmentsDelay = nil
        await viewModel.fetch()

        XCTAssertTrue(viewModel.state.groups.isEmpty, "the scan's own result should stand")
        // Long enough for the parked pass to wake up and publish, if it still could.
        try? await Task.sleep(for: .seconds(2))

        XCTAssertTrue(
            viewModel.state.groups.isEmpty,
            "a superseded pass must not put a group built from the pre-refresh library back on screen"
        )
        XCTAssertEqual(readyPublishes, 1, "only the scan may publish a result here")
    }

    /// W-31 / B-14: the sort direction only reorders the published result, it doesn't re-group.
    func testSortingTogglesOrderWithoutRegrouping() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
        await viewModel.fetch()

        let groupingsAfterScan = pairFinder.callCount
        let groupsBefore = viewModel.state.groups

        viewModel.sorting.toggle()

        XCTAssertEqual(pairFinder.callCount, groupingsAfterScan, "re-sorting must not re-group")
        XCTAssertEqual(viewModel.state.groups, groupsBefore.reversed())
    }

    /// A scan and the iCloud retry both end with a grouping pass of their own, and that pass took
    /// the threshold when it started. Moving the slider while it is finishing only supersedes
    /// *re-groups*, so the pass still publishes the grouping for the value the user has already
    /// left, and the re-group scheduled behind it undoes that a moment later — one drag, two
    /// answers, the first of them for a setting no longer on screen (W-39).
    func testThresholdChangedWhileAScanWasGroupingPublishesOnce() async {
        let first = makeLibraryAsset()
        let second = makeLibraryAsset()
        let hashStore = HashStoreMock()
        // Six bits apart: one group at a threshold of 6, none at 4.
        hashStore.records = [
            first.asset.localIdentifier: makeHashRecord(identifier: first.asset.localIdentifier, phash: 0),
            second.asset.localIdentifier: makeHashRecord(identifier: second.asset.localIdentifier, phash: 0b111111)
        ]
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [first, second]

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashStore: hashStore)
        viewModel.distanceThreshold = 6

        var readyPublishes = 0
        let subscription = viewModel.$state.sink { state in
            if case .ready = state {
                readyPublishes += 1
            }
        }
        defer { subscription.cancel() }

        // Parks the scan's own grouping in its persistence await, holding the group it found at 6.
        hashStore.saveGroupAssignmentsDelay = .seconds(1)
        let scan = Task { await viewModel.fetch() }
        await waitUntil({ isGrouping(viewModel.state) }, message: "the scan should reach its grouping pass")
        try? await Task.sleep(for: .milliseconds(100))

        viewModel.distanceThreshold = 4
        hashStore.saveGroupAssignmentsDelay = nil
        await scan.value

        await waitUntil({ isReady(viewModel.state) }, message: "the re-group for 4 should publish")
        XCTAssertTrue(viewModel.state.groups.isEmpty, "four bits apart is below the threshold the user landed on")
        XCTAssertEqual(readyPublishes, 1, "the pass must not publish the grouping for the threshold already left")
    }

    /// Only the *input* to the engine is filtered (W-35); what is recorded of the outcome is not.
    /// A photo the filter excluded is a photo in no group, so leaving its row pointing at the
    /// group it was in before contradicts the grouping that was just computed — and the stored
    /// assignment is what a later launch is meant to show before any scan runs (W-14, W-30).
    func testFilteringOutSharedPhotosClearsTheirStoredGroup() async {
        let local = makeLibraryAsset()
        let shared = makeLibraryAsset(sourceType: .typeCloudShared)
        let hashStore = HashStoreMock()
        hashStore.records = [
            local.asset.localIdentifier: makeHashRecord(identifier: local.asset.localIdentifier, phash: 0),
            shared.asset.localIdentifier: makeHashRecord(identifier: shared.asset.localIdentifier, phash: 0)
        ]
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [local, shared]

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashStore: hashStore)
        await viewModel.fetch()
        XCTAssertEqual(viewModel.state.groups.first?.assets.count, 2, "the two identical photos start out grouped")
        XCTAssertNotNil(hashStore.records[shared.asset.localIdentifier]?.groupID)

        viewModel.filters = []
        await waitUntil(
            { viewModel.state.groups.isEmpty },
            message: "excluding the shared photo should leave the local one on its own"
        )

        XCTAssertNil(
            hashStore.records[shared.asset.localIdentifier]?.groupID,
            "an excluded photo should stop pointing at a group that no longer holds it"
        )
    }
}
