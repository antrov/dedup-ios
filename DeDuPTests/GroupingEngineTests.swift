//
//  GroupingEngineTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class GroupingEngineTests: XCTestCase {
    private let engine = GroupingEngine()

    // MARK: - Section 2: single-linkage clustering / chain effect

    func testChainOfSimilarPairsFormsOneGroupEvenWhenTheEndsAreFar() async throws {
        // a-b and b-c are within threshold, a-c is not — single-linkage still joins all three (2.2).
        let identifiers = ["a", "b", "c"]
        let hashes: [UInt64] = [0b0000, 0b0001, 0b0011]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 1)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.memberIdentifiers, ["a", "b", "c"])
    }

    func testTwoDisjointChainsFormTwoGroups() async throws {
        let identifiers = ["a", "b", "x", "y"]
        let hashes: [UInt64] = [0, 1, 0xFF, 0xFE]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 1)

        XCTAssertEqual(Set(groups.map(\.memberIdentifiers)), [["a", "b"], ["x", "y"]])
    }

    func testElementWithoutNeighborsFormsNoGroup() async throws {
        let identifiers = ["a", "b", "lonely"]
        let hashes: [UInt64] = [0, 1, 0xFFFF_FFFF]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 1)

        XCTAssertEqual(groups.count, 1)
        XCTAssertFalse(groups.contains { $0.memberIdentifiers.contains("lonely") })
    }

    func testZeroThresholdOnlyGroupsIdenticalHashes() async throws {
        let identifiers = ["a", "b", "c"]
        let hashes: [UInt64] = [5, 5, 6]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 0)

        XCTAssertEqual(groups.count, 1)
        XCTAssertEqual(groups.first?.memberIdentifiers, ["a", "b"])
    }

    // MARK: - W-30: stable group identifier

    func testGroupIDIsLexicographicallySmallestMember() async throws {
        let identifiers = ["zebra", "apple", "mango"]
        let hashes: [UInt64] = [0, 0, 0]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 0)

        XCTAssertEqual(groups.first?.id, "apple")
    }

    // MARK: - W-31: deterministic, order-independent result

    func testResultIsIndependentOfInputOrder() async throws {
        let identifiers = ["c", "a", "b", "z"]
        let hashes: [UInt64] = [0, 0, 0, 0xFFFF]
        let shuffledIdentifiers = ["z", "b", "a", "c"]
        let shuffledHashes: [UInt64] = [0xFFFF, 0, 0, 0]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 0)
        let shuffledGroups = try await engine.makeGroups(
            identifiers: shuffledIdentifiers,
            hashes: shuffledHashes,
            threshold: 0
        )

        XCTAssertEqual(groups, shuffledGroups)
    }

    // MARK: - W-33: diameter

    func testDiameterIsTheLargestPairwiseDistanceInTheGroupNotJustTheThreshold() async throws {
        // a-b distance 1, b-c distance 1, a-c distance 2: chained into one group whose diameter
        // reflects the widest pair, not the threshold that produced it.
        let identifiers = ["a", "b", "c"]
        let hashes: [UInt64] = [0b00, 0b01, 0b11]

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 1)

        XCTAssertEqual(groups.first?.diameter, 2)
    }

    // MARK: - W-32: cancellable

    /// `rebuildGroups()` deliberately survives a photo that reached it twice rather than trapping
    /// on it, and hands the very same list here — so this has to survive it too, or the tolerance
    /// upstream buys nothing (W-36).
    func testAssignmentsToleratesAnIdentifierListedTwice() async throws {
        let groups = try await engine.makeGroups(identifiers: ["a", "b"], hashes: [0, 0], threshold: 0)

        let assignments = GroupingEngine.assignments(for: ["a", "a", "b", "lonely"], in: groups)

        XCTAssertEqual(assignments.count, 3)
        XCTAssertEqual(assignments["a"], groups.first?.id)
        XCTAssertEqual(assignments["b"], groups.first?.id)
        XCTAssertEqual(assignments["lonely"], String?.none, "an identifier in no group is recorded as being in none")
    }

    func testCancellationStopsGrouping() async {
        let identifiers = ["a", "b"]
        let hashes: [UInt64] = [0, 0]

        let task = Task {
            try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: 0)
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("expected CancellationError")
        } catch is CancellationError {
            // expected
        } catch {
            XCTFail("expected CancellationError, got \(error)")
        }
    }
}
