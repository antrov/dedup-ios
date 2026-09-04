//
//  PhotosViewModelStateTests.swift
//  DeDuPTests
//

@testable import DeDuP
import Photos
import XCTest

/// Stage 5: what the screen state says (W-38), when scanning starts and stops (W-40, W-41), and
/// what a threshold or filter change is allowed to cost (W-39).
@MainActor
final class PhotosViewModelStateTests: XCTestCase {
    private func makeViewModel(
        photoLibrary: PhotoLibraryServiceMock = PhotoLibraryServiceMock(),
        hashing: ImageHashingServiceMock = ImageHashingServiceMock(),
        hashStore: HashStoreMock = HashStoreMock(),
        pairFinder: PairFinder = BruteForcePairFinder()
    ) -> PhotosViewModel {
        PhotosViewModel(
            photoLibrary: photoLibrary,
            hashing: hashing,
            hashStore: hashStore,
            groupingEngine: GroupingEngine(pairFinder: pairFinder)
        )
    }

    // MARK: - W-38 / W-40: nothing happens until the view asks for it

    func testStartsIdleAndDoesNoWorkOnInit() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing)

        XCTAssertEqual(viewModel.state, .idle, "creating the view model must not start a scan (W-40)")
        let callCount = await hashing.hashCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testRefusedAuthorizationEndsInDeniedState() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.authorizationStatus = .denied
        photoLibrary.libraryAssets = [makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()

        XCTAssertEqual(viewModel.state, .authorizationDenied)
        let callCount = await hashing.hashCallCount
        XCTAssertEqual(callCount, 0, "a refused library must not be hashed")
    }

    /// The distinction W-38 exists for: an empty library ends in a *finished* state, not in one
    /// the UI can't tell apart from a scan still in progress.
    func testEmptyLibraryEndsInReadyWithNoGroups() async {
        let viewModel = makeViewModel()

        await viewModel.fetch()

        XCTAssertEqual(viewModel.state, .ready(groups: []))
    }

    /// W-41 / B-13: the refresh gesture awaits `fetch()` directly, so it must not return while
    /// the scan is still running.
    func testFetchReturnsOnlyAfterTheScanFinished() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()

        XCTAssertNil(viewModel.state.phase, "no phase should still be in progress once fetch() has returned")
        guard case let .ready(groups) = viewModel.state else {
            return XCTFail("expected a finished state, got \(viewModel.state)")
        }
        XCTAssertEqual(groups.count, 1, "two identical hashes belong to one group")
        XCTAssertEqual(groups.first?.assets.count, 2)
    }

    func testProcessingCountsReportTheWholeLibrary() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()

        // W-43: three photos in the library, all hashed, nothing skipped.
        XCTAssertEqual(viewModel.processingCounts.libraryTotal, 3)
        XCTAssertEqual(viewModel.processingCounts.computed, 3)
        XCTAssertEqual(viewModel.processingCounts.unprocessed, 0)
    }

    // MARK: - W-39: a threshold change re-groups, it never re-hashes

    func testThresholdChangeRegroupsWithoutRehashing() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
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
    /// pixel of movement (W-39).
    func testRapidThresholdChangesCollapseIntoOneRegroup() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
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

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
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
    /// over from the scan (W-38, W-39).
    func testThresholdChangeDuringScanWaitsForIt() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        hashing.delay = .seconds(1)

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing)
        let scan = Task { await viewModel.fetch() }
        await waitUntil({ Self.isHashing(viewModel.state) }, message: "the scan should reach its hashing phase")

        viewModel.distanceThreshold = 9
        try? await Task.sleep(for: .milliseconds(500))
        XCTAssertTrue(
            Self.isHashing(viewModel.state),
            "the scan should still own the phase while it hashes, got \(viewModel.state)"
        )

        await scan.value
        await waitUntil({ Self.isReady(viewModel.state) }, message: "the deferred re-group should publish a result")
    }

    private static func isHashing(_ state: PhotosScreenState) -> Bool {
        if case .hashingImages = state.phase {
            return true
        }
        return false
    }

    private static func isReady(_ state: PhotosScreenState) -> Bool {
        if case .ready = state {
            return true
        }
        return false
    }

    /// W-31 / B-14: the sort direction only reorders the published result, it doesn't re-group.
    func testSortingTogglesOrderWithoutRegrouping() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)
        let pairFinder = CountingPairFinder()

        let viewModel = makeViewModel(photoLibrary: photoLibrary, hashing: hashing, pairFinder: pairFinder)
        await viewModel.fetch()

        let groupingsAfterScan = pairFinder.callCount
        let groupsBefore = viewModel.state.groups

        viewModel.sorting.toggle()

        XCTAssertEqual(pairFinder.callCount, groupingsAfterScan, "re-sorting must not re-group")
        XCTAssertEqual(viewModel.state.groups, groupsBefore.reversed())
    }
}
