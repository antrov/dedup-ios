//
//  AssetHashingPipelineTests.swift
//  DeDuPTests
//

@testable import DeDuP
import Foundation
import XCTest

/// What the pipeline reports while it works (W-21). The progress bar renders these numbers
/// directly, so they have to hold for the whole phase rather than per batch of work.
final class AssetHashingPipelineTests: XCTestCase {
    private final class ProgressLog: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [(completed: Int, total: Int)] = []

        var reports: [(completed: Int, total: Int)] {
            lock.lock()
            defer { lock.unlock() }
            return storage
        }

        func record(completed: Int, total: Int) {
            lock.lock()
            storage.append((completed, total))
            lock.unlock()
        }
    }

    /// A partially warm cache is what used to move the denominator mid-phase: only the misses
    /// reach the computing step, so three photos with two valid cache entries reported "1 / 1"
    /// right after the view model had published "0 / 3", sending the bar to full.
    func testProgressCountsTheWholeInputNotJustTheCacheMisses() async {
        let cached = makeLibraryAsset()
        let alsoCached = makeLibraryAsset()
        let stale = makeLibraryAsset()
        let hashStore = HashStoreMock()
        hashStore.records = [
            cached.asset.localIdentifier: makeHashRecord(identifier: cached.asset.localIdentifier, phash: 1),
            alsoCached.asset.localIdentifier: makeHashRecord(identifier: alsoCached.asset.localIdentifier, phash: 2)
        ]
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(3)
        let pipeline = AssetHashingPipeline(hashing: hashing, hashStore: hashStore)
        let log = ProgressLog()

        let records = await pipeline.resolveRecords(
            for: [cached, alsoCached, stale],
            allowsNetworkAccess: false,
            onProgress: { completed, total in log.record(completed: completed, total: total) }
        )

        XCTAssertEqual(records.count, 3)
        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 1, "the two valid cache entries must not be hashed again")

        let reports = log.reports
        XCTAssertFalse(reports.isEmpty, "a phase with work to do should report progress")
        XCTAssertTrue(reports.allSatisfy { $0.total == 3 }, "every report should count the whole input, got \(reports)")
        XCTAssertEqual(reports.first?.completed, 2, "a cache hit is work already done, not work still pending")
        XCTAssertEqual(reports.last?.completed, 3)
    }

    /// A fully warm cache has nothing to compute, so nothing used to report anything and the bar
    /// stayed at zero for the whole phase.
    func testFullyCachedInputReportsItsWorkAsDone() async {
        let libraryAsset = makeLibraryAsset()
        let hashStore = HashStoreMock()
        hashStore.records = [
            libraryAsset.asset.localIdentifier: makeHashRecord(identifier: libraryAsset.asset.localIdentifier)
        ]
        let hashing = ImageHashingServiceMock()
        let log = ProgressLog()

        _ = await AssetHashingPipeline(hashing: hashing, hashStore: hashStore).resolveRecords(
            for: [libraryAsset],
            allowsNetworkAccess: false,
            onProgress: { completed, total in log.record(completed: completed, total: total) }
        )

        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 0)
        XCTAssertEqual(log.reports.last?.completed, 1, "nothing left to do should read as finished, not as untouched")
        XCTAssertEqual(log.reports.last?.total, 1)
    }

    // MARK: - W-52: cache validity on an in-memory SQLite store (W-11)

    func testValidSQLiteRecordMatchingVersionAndDateIsNotRecomputed() async throws {
        let date = Date(timeIntervalSince1970: 1000)
        let libraryAsset = makeLibraryAsset(modificationDate: date)
        let store = try SQLiteHashStore(database: AppDatabase.openInMemory())
        try await store.save([
            makeHashRecord(identifier: libraryAsset.asset.localIdentifier, phash: 0x1111, modificationDate: date)
        ])
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x2222)

        let records = await AssetHashingPipeline(hashing: hashing, hashStore: store).resolveRecords(
            for: [libraryAsset],
            allowsNetworkAccess: false,
            onProgress: { _, _ in }
        )

        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 0)
        XCTAssertEqual(records.first?.phash, 0x1111)
    }

    func testNilModificationDatesCountAsEqualOnSQLite() async throws {
        let libraryAsset = makeLibraryAsset(modificationDate: nil)
        let store = try SQLiteHashStore(database: AppDatabase.openInMemory())
        try await store.save([
            makeHashRecord(identifier: libraryAsset.asset.localIdentifier, phash: 0x1111, modificationDate: nil)
        ])
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x2222)

        _ = await AssetHashingPipeline(hashing: hashing, hashStore: store).resolveRecords(
            for: [libraryAsset],
            allowsNetworkAccess: false,
            onProgress: { _, _ in }
        )

        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 0, "two nil modification dates are equal (W-11)")
    }

    func testStaleModificationDateOnSQLiteIsRecomputed() async throws {
        let libraryAsset = makeLibraryAsset(modificationDate: Date(timeIntervalSince1970: 2000))
        let store = try SQLiteHashStore(database: AppDatabase.openInMemory())
        try await store.save([
            makeHashRecord(
                identifier: libraryAsset.asset.localIdentifier,
                phash: 0x1111,
                modificationDate: Date(timeIntervalSince1970: 1000)
            )
        ])
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x2222)

        let records = await AssetHashingPipeline(hashing: hashing, hashStore: store).resolveRecords(
            for: [libraryAsset],
            allowsNetworkAccess: false,
            onProgress: { _, _ in }
        )

        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 1, "an edited photo must not keep the hash computed from the old pixels")
        XCTAssertEqual(records.first?.phash, 0x2222)
        let reloaded = try await store.load(identifiers: [libraryAsset.asset.localIdentifier])
        XCTAssertEqual(reloaded.first?.phash, 0x2222)
        XCTAssertEqual(reloaded.first?.modificationDate, Date(timeIntervalSince1970: 2000))
    }

    func testStalePipelineVersionOnSQLiteIsRecomputed() async throws {
        let date = Date(timeIntervalSince1970: 1000)
        let libraryAsset = makeLibraryAsset(modificationDate: date)
        let store = try SQLiteHashStore(database: AppDatabase.openInMemory())
        try await store.save([
            makeHashRecord(
                identifier: libraryAsset.asset.localIdentifier,
                phash: 0x1111,
                hashVersion: HashingPipeline.version - 1,
                modificationDate: date
            )
        ])
        let hashing = ImageHashingServiceMock()
        hashing.outcomeToReturn = .computed(0x2222)

        let records = await AssetHashingPipeline(hashing: hashing, hashStore: store).resolveRecords(
            for: [libraryAsset],
            allowsNetworkAccess: false,
            onProgress: { _, _ in }
        )

        let hashCalls = await hashing.hashCallCount
        XCTAssertEqual(hashCalls, 1, "a cache entry from an older hashing pipeline must be replaced")
        XCTAssertEqual(records.first?.phash, 0x2222)
        let reloaded = try await store.load(identifiers: [libraryAsset.asset.localIdentifier])
        XCTAssertEqual(reloaded.first?.hashVersion, HashingPipeline.version)
    }
}
