//
//  HashStoreTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class HashStoreTests: XCTestCase {
    private var store: SQLiteHashStore!

    override func setUpWithError() throws {
        store = try SQLiteHashStore(database: AppDatabase.openInMemory())
    }

    private func makeRecord(
        id: String,
        phash: UInt64? = 0x1234_5678_9ABC_DEF0,
        hashVersion: Int = 1,
        state: HashRecord.State = .computed,
        groupID: String? = nil
    ) -> HashRecord {
        HashRecord(
            localIdentifier: id,
            phash: phash,
            hashVersion: hashVersion,
            modificationDate: Date(timeIntervalSince1970: 1000),
            creationDate: Date(timeIntervalSince1970: 500),
            state: state,
            failureReason: nil,
            groupID: groupID,
            updatedAt: Date(timeIntervalSince1970: 1500)
        )
    }

    func testMigrationOnFreshDatabaseCreatesUsableTable() async throws {
        let all = try await store.loadAll()
        XCTAssertTrue(all.isEmpty)
    }

    func testSaveAndLoadRoundTrip() async throws {
        let record = makeRecord(id: "A")
        try await store.save([record])

        let loaded = try await store.load(identifiers: ["A"])
        XCTAssertEqual(loaded, [record])
    }

    func testLoadOnlyReturnsRequestedIdentifiers() async throws {
        try await store.save([makeRecord(id: "A"), makeRecord(id: "B"), makeRecord(id: "C")])

        let loaded = try await store.load(identifiers: ["A", "C", "missing"])
        XCTAssertEqual(Set(loaded.map(\.localIdentifier)), ["A", "C"])
    }

    func testLoadAllReturnsEveryRecord() async throws {
        try await store.save([makeRecord(id: "A"), makeRecord(id: "B")])

        let all = try await store.loadAll()
        XCTAssertEqual(Set(all.map(\.localIdentifier)), ["A", "B"])
    }

    func testSaveUpsertsExistingRecord() async throws {
        try await store.save([makeRecord(id: "A", phash: 1)])
        try await store.save([makeRecord(id: "A", phash: 2)])

        let loaded = try await store.load(identifiers: ["A"])
        XCTAssertEqual(loaded.count, 1)
        XCTAssertEqual(loaded.first?.phash, 2)
    }

    func testPHashRoundTripsFullBitRangeIncludingTopBit() async throws {
        // Bit 63 is set here — as UInt64 this exceeds Int64.max, exercising the bit-pattern
        // conversion the storage layer uses to fit the hash into SQLite's signed INTEGER (W-08).
        let record = makeRecord(id: "A", phash: PHash.informativeBitsMask)
        try await store.save([record])

        let loaded = try await store.load(identifiers: ["A"])
        XCTAssertEqual(loaded.first?.phash, PHash.informativeBitsMask)
    }

    func testNilPHashRoundTrips() async throws {
        let record = makeRecord(id: "A", phash: nil, state: .failed)
        try await store.save([record])

        let loaded = try await store.load(identifiers: ["A"])
        XCTAssertNil(loaded.first?.phash)
        XCTAssertEqual(loaded.first?.state, .failed)
    }

    func testDeleteRemovesOnlyGivenIdentifiers() async throws {
        try await store.save([makeRecord(id: "A"), makeRecord(id: "B")])
        try await store.delete(identifiers: ["A"])

        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.localIdentifier), ["B"])
    }

    func testDeleteRecordsNotInRemovesOrphans() async throws {
        try await store.save([makeRecord(id: "A"), makeRecord(id: "B"), makeRecord(id: "C")])
        try await store.deleteRecords(notIn: ["B"])

        let all = try await store.loadAll()
        XCTAssertEqual(all.map(\.localIdentifier), ["B"])
    }

    func testDeleteRecordsNotInKeepsEverythingWhenAllCurrent() async throws {
        try await store.save([makeRecord(id: "A"), makeRecord(id: "B")])
        try await store.deleteRecords(notIn: ["A", "B"])

        let all = try await store.loadAll()
        XCTAssertEqual(Set(all.map(\.localIdentifier)), ["A", "B"])
    }

    func testGroupAssignmentsOnlyReturnsGroupedRecords() async throws {
        try await store.save([
            makeRecord(id: "A", groupID: "group-1"),
            makeRecord(id: "B", groupID: nil)
        ])

        let assignments = try await store.groupAssignments()
        XCTAssertEqual(assignments, ["A": "group-1"])
    }

    func testSaveGroupAssignmentsWritesAndClearsGroupIDs() async throws {
        try await store.save([makeRecord(id: "A", groupID: "old-group"), makeRecord(id: "B")])

        try await store.saveGroupAssignments(["A": nil, "B": "new-group"])

        let assignments = try await store.groupAssignments()
        XCTAssertEqual(assignments, ["B": "new-group"])
    }

    func testEmptyBatchesAreNoOps() async throws {
        try await store.save([])
        try await store.delete(identifiers: [])
        let loaded = try await store.load(identifiers: [])
        XCTAssertTrue(loaded.isEmpty)
    }
}
