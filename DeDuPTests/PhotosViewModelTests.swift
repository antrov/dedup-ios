//
//  PhotosViewModelTests.swift
//  DeDuPTests
//

@testable import DeDuP
import Photos
import XCTest

final class PhotosViewModelTests: XCTestCase {
    private func makeLibraryAsset() -> LibraryAsset {
        LibraryAsset(asset: PHAsset(), collection: nil)
    }

    // MARK: - W-16: cache-first, single bulk lookup

    func testValidCachedRecordIsNotRecomputed() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        let libraryAsset = makeLibraryAsset()
        let identifier = libraryAsset.asset.localIdentifier
        photoLibrary.libraryAssets = [libraryAsset]
        hashStore.records[identifier] = HashRecord(
            localIdentifier: identifier,
            phash: 0x1111,
            hashVersion: HashingPipeline.version,
            modificationDate: libraryAsset.asset.modificationDate,
            creationDate: libraryAsset.asset.creationDate,
            state: .computed,
            failureReason: nil,
            groupID: nil,
            updatedAt: Date()
        )

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()

        let callCount = await hashing.hashCallCount
        XCTAssertEqual(callCount, 0, "a cache entry matching version and modification date should be reused")
        XCTAssertEqual(hashStore.records[identifier]?.phash, 0x1111)
    }

    func testCachedRecordWithStalePipelineVersionIsRecomputed() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        let libraryAsset = makeLibraryAsset()
        let identifier = libraryAsset.asset.localIdentifier
        photoLibrary.libraryAssets = [libraryAsset]
        hashStore.records[identifier] = HashRecord(
            localIdentifier: identifier,
            phash: 0x1111,
            hashVersion: HashingPipeline.version - 1,
            modificationDate: libraryAsset.asset.modificationDate,
            creationDate: libraryAsset.asset.creationDate,
            state: .computed,
            failureReason: nil,
            groupID: nil,
            updatedAt: Date()
        )
        hashing.outcomeToReturn = .computed(0x2222)

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()

        let callCount = await hashing.hashCallCount
        XCTAssertGreaterThanOrEqual(callCount, 1, "a stale pipeline version should force recomputation")
        XCTAssertEqual(hashStore.records[identifier]?.phash, 0x2222)
        XCTAssertEqual(hashStore.records[identifier]?.hashVersion, HashingPipeline.version)
    }

    func testSecondFetchReusesCacheBuiltByFirstFetch() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        photoLibrary.libraryAssets = [makeLibraryAsset()]
        hashing.outcomeToReturn = .computed(0x3333)

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)

        await viewModel.fetch()
        let countAfterFirst = await hashing.hashCallCount
        XCTAssertGreaterThanOrEqual(countAfterFirst, 1)

        await viewModel.fetch()
        let countAfterSecond = await hashing.hashCallCount
        XCTAssertEqual(countAfterSecond, countAfterFirst, "a second scan should not recompute an already-valid hash")
    }

    // MARK: - W-13: orphan cleanup after a full scan

    func testFetchDeletesOrphanedCacheRecordsNotInLibrary() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        hashStore.records["orphan-id"] = HashRecord(
            localIdentifier: "orphan-id",
            phash: 1,
            hashVersion: HashingPipeline.version,
            modificationDate: nil,
            creationDate: nil,
            state: .computed,
            failureReason: nil,
            groupID: nil,
            updatedAt: Date()
        )
        photoLibrary.libraryAssets = []

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()

        XCTAssertNil(hashStore.records["orphan-id"])
    }

    // MARK: - W-19 / B-06: cloud-only assets are recorded, not retried, and network access defaults to off

    func testCloudOnlyOutcomeIsRecordedAndNotRetriedOnNextScan() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        let libraryAsset = makeLibraryAsset()
        let identifier = libraryAsset.asset.localIdentifier
        photoLibrary.libraryAssets = [libraryAsset]
        hashing.outcomeToReturn = .cloudOnly

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()

        XCTAssertEqual(hashStore.records[identifier]?.state, .cloudOnly)
        XCTAssertEqual(viewModel.processingCounts.cloudOnly, 1)
        let networkRequests = await hashing.networkAccessRequests
        XCTAssertEqual(networkRequests.first, false, "a regular scan must never allow network access")

        let countAfterFirstScan = await hashing.hashCallCount
        await viewModel.fetch()
        let countAfterSecondScan = await hashing.hashCallCount
        XCTAssertEqual(countAfterSecondScan, countAfterFirstScan, "a cloud-only asset must not be retried by a regular scan")
    }

    func testRetryCloudOnlyAssetsForcesRecomputationWithNetworkAccess() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        let libraryAsset = makeLibraryAsset()
        let identifier = libraryAsset.asset.localIdentifier
        photoLibrary.libraryAssets = [libraryAsset]
        hashing.outcomeToReturn = .cloudOnly

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()
        XCTAssertEqual(viewModel.processingCounts.cloudOnly, 1)

        let countBeforeRetry = await hashing.hashCallCount
        hashing.outcomeToReturn = .computed(0xABCD)
        await viewModel.retryCloudOnlyAssets()

        let countAfterRetry = await hashing.hashCallCount
        XCTAssertGreaterThan(countAfterRetry, countBeforeRetry, "the explicit retry should force recomputation")
        let networkRequests = await hashing.networkAccessRequests
        XCTAssertEqual(networkRequests.last, true, "the explicit retry should allow network access")
        XCTAssertEqual(hashStore.records[identifier]?.state, .computed)
        XCTAssertEqual(hashStore.records[identifier]?.phash, 0xABCD)
        XCTAssertEqual(viewModel.processingCounts.cloudOnly, 0)
    }

    // MARK: - W-22 / B-09: failures are recorded instead of silently dropped

    func testFailedOutcomeIsRecordedWithReason() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let hashing = ImageHashingServiceMock()
        let hashStore = HashStoreMock()

        let libraryAsset = makeLibraryAsset()
        let identifier = libraryAsset.asset.localIdentifier
        photoLibrary.libraryAssets = [libraryAsset]
        hashing.outcomeToReturn = .failed(reason: "boom")

        let viewModel = PhotosViewModel(photoLibrary: photoLibrary, hashing: hashing, hashStore: hashStore)
        await viewModel.fetch()

        XCTAssertEqual(hashStore.records[identifier]?.state, .failed)
        XCTAssertEqual(hashStore.records[identifier]?.failureReason, "boom")
        XCTAssertEqual(viewModel.processingCounts.failed, 1)
    }
}
