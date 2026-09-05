//
//  PhotosViewModelStateTests.swift
//  DeDuPTests
//

import Combine
@testable import DeDuP
import Photos
import XCTest

/// Stage 5: what the screen state says (W-38), and when scanning starts and stops (W-40, W-41).
/// What a threshold or filter change is allowed to cost (W-39) lives in `PhotosRegroupTests`.
@MainActor
final class PhotosViewModelStateTests: XCTestCase {
    // MARK: - W-38 / W-40: nothing happens until the view asks for it

    func testStartsIdleAndDoesNoWorkOnInit() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)

        XCTAssertEqual(viewModel.state, .idle, "creating the view model must not start a scan (W-40)")
        let callCount = await hashing.hashCallCount
        XCTAssertEqual(callCount, 0)
    }

    func testRefusedAuthorizationEndsInDeniedState() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.authorizationStatus = .denied
        photoLibrary.libraryAssets = [makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()

        XCTAssertEqual(viewModel.state, .authorizationDenied)
        let callCount = await hashing.hashCallCount
        XCTAssertEqual(callCount, 0, "a refused library must not be hashed")
    }

    /// W-41: a refresh re-checks the permission on its way in, and every state it passes through
    /// on an already-authorized library has to keep carrying the groups. Blanking the list out
    /// costs the scroll position and closes an open details sheet, whose binding resolves the
    /// selected group against the published result (B-14).
    func testRefreshKeepsTheGroupsVisibleWhileReauthorizing() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x1234)

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()
        XCTAssertEqual(viewModel.state.groups.count, 1, "two identical hashes belong to one group")

        var published: [PhotosScreenState] = []
        let subscription = viewModel.$state.sink { published.append($0) }
        defer { subscription.cancel() }
        published.removeAll()

        await viewModel.fetch()

        XCTAssertFalse(published.isEmpty, "a refresh should publish the states it moves through")
        XCTAssertTrue(
            published.allSatisfy { !$0.groups.isEmpty },
            "the list must stay on screen for the whole refresh, blanked out in \(published.map(\.phase))"
        )
    }

    /// The distinction W-38 exists for: an empty library ends in a *finished* state, not in one
    /// the UI can't tell apart from a scan still in progress.
    func testEmptyLibraryEndsInReadyWithNoGroups() async {
        let viewModel = makePhotosViewModel()

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

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
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

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()

        // W-43: three photos in the library, all hashed, nothing skipped.
        XCTAssertEqual(viewModel.processingCounts.libraryTotal, 3)
        XCTAssertEqual(viewModel.processingCounts.computed, 3)
        XCTAssertEqual(viewModel.processingCounts.unprocessed, 0)
    }

    // MARK: - W-19: the iCloud retry is a single pass, however often it is asked for

    /// Two taps on "Fetch" in a row: the second must join the pass already running instead of
    /// starting a second one that hashes the same photos again and adds a second `Asset` for
    /// each of them — which grouping, keyed by identifier, cannot represent.
    func testConcurrentCloudRetriesHashEachPhotoOnce() async {
        let photoLibrary = PhotoLibraryServiceMock()
        photoLibrary.libraryAssets = [makeLibraryAsset(), makeLibraryAsset()]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .cloudOnly

        let viewModel = makePhotosViewModel(photoLibrary: photoLibrary, hashing: hashing)
        await viewModel.fetch()
        XCTAssertEqual(viewModel.processingCounts.cloudOnly, 2)

        let callsBeforeRetry = await hashing.hashCallCount
        hashing.outcomeToReturn = .computed(0x4242)
        hashing.delay = .milliseconds(300)

        async let firstTap: Void = viewModel.retryCloudOnlyAssets()
        async let secondTap: Void = viewModel.retryCloudOnlyAssets()
        _ = await(firstTap, secondTap)

        let callsAfterRetry = await hashing.hashCallCount
        XCTAssertEqual(callsAfterRetry - callsBeforeRetry, 2, "two photos should be hashed once each, not once per tap")
        XCTAssertEqual(viewModel.processingCounts.cloudOnly, 0)
        XCTAssertEqual(viewModel.processingCounts.computed, 2)

        // Grouping builds a dictionary keyed by identifier, so a duplicated asset traps here.
        await viewModel.rebuildGroups()
        XCTAssertEqual(viewModel.state.groups.first?.assets.count, 2, "both photos belong to one group, once each")
    }
}
