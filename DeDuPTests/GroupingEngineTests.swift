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

    /// W-50 / B-01 / B-02: the same hashes in a randomly shuffled order must produce the same
    /// groups, the same stable identifiers, and the same element order — not just for one
    /// hand-picked permutation.
    func testResultIsIndependentOfRandomShuffles() async throws {
        let identifiers = (0 ..< 40).map { String(format: "id-%02d", $0) }
        var hashes: [UInt64] = (0 ..< 40).map { _ in UInt64.random(in: .min ... .max) }
        // Forced chains so the shuffle has real groups to scramble, not only singletons.
        hashes[0] = 0
        hashes[1] = 1
        hashes[2] = 3
        hashes[10] = 0xFF00
        hashes[11] = 0xFF01
        hashes[20] = 0
        let threshold = 1

        let groups = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: threshold)

        for _ in 0 ..< 10 {
            let order = identifiers.indices.shuffled()
            let shuffledIdentifiers = order.map { identifiers[$0] }
            let shuffledHashes = order.map { hashes[$0] }
            let shuffledGroups = try await engine.makeGroups(
                identifiers: shuffledIdentifiers,
                hashes: shuffledHashes,
                threshold: threshold
            )
            XCTAssertEqual(shuffledGroups, groups)
        }
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

    /// W-51: the engine's connected components must match a naive single-linkage reference —
    /// all-pairs, then BFS components (not the production `DisjointSet`), then the same
    /// id / sort rules — on a set that includes forced chains (section 2).
    func testGroupsMatchNaiveConnectedComponentsOnForcedChains() async throws {
        var identifiers = (0 ..< 24).map { String(format: "n-%02d", $0) }
        var hashes: [UInt64] = (0 ..< 24).map { _ in UInt64.random(in: .min ... .max) }
        identifiers[0] = "chain-a"
        identifiers[1] = "chain-b"
        identifiers[2] = "chain-c"
        hashes[0] = 0b0000
        hashes[1] = 0b0001
        hashes[2] = 0b0011
        identifiers[8] = "other-x"
        identifiers[9] = "other-y"
        hashes[8] = 0xFF
        hashes[9] = 0xFE
        hashes[15] = 0xFFFF_FFFF

        let threshold = 1
        let expected = naiveGroups(identifiers: identifiers, hashes: hashes, threshold: threshold)
        let actual = try await engine.makeGroups(identifiers: identifiers, hashes: hashes, threshold: threshold)
        XCTAssertEqual(actual, expected)
    }
}

/// Single-linkage reference for W-51: a straightforward double loop plus BFS over the
/// similarity graph, then the same identifier / sort rules as `GroupingEngine`. Lives only
/// in the test target and deliberately avoids `DisjointSet`, so a shared union-find bug
/// cannot make both sides of the comparison wrong in the same way.
private func naiveGroups(identifiers: [String], hashes: [UInt64], threshold: Int) -> [GroupingEngine.Group] {
    var adjacency = Array(repeating: [Int](), count: identifiers.count)
    for lowerIndex in identifiers.indices {
        for upperIndex in (lowerIndex + 1) ..< identifiers.count {
            guard PHash.distance(hashes[lowerIndex], hashes[upperIndex]) <= threshold else { continue }
            adjacency[lowerIndex].append(upperIndex)
            adjacency[upperIndex].append(lowerIndex)
        }
    }

    var visited = Array(repeating: false, count: identifiers.count)
    var groups: [GroupingEngine.Group] = []
    for start in identifiers.indices {
        guard !visited[start] else { continue }

        var component: [Int] = []
        var queue = [start]
        visited[start] = true
        var queueIndex = 0
        while queueIndex < queue.count {
            let current = queue[queueIndex]
            queueIndex += 1
            component.append(current)
            for neighbor in adjacency[current] where !visited[neighbor] {
                visited[neighbor] = true
                queue.append(neighbor)
            }
        }

        guard component.count > 1 else { continue }
        let sortedIdentifiers = component.map { identifiers[$0] }.sorted()
        groups.append(
            GroupingEngine.Group(
                id: sortedIdentifiers.first ?? "",
                memberIdentifiers: sortedIdentifiers,
                diameter: PHash.diameter(of: component.map { hashes[$0] })
            )
        )
    }

    return groups.sorted { $0.id < $1.id }
}
