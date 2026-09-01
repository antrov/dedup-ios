//
//  DisjointSetTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class DisjointSetTests: XCTestCase {
    func testEachElementStartsInItsOwnSet() {
        var set = DisjointSet(count: 5)
        for element in 0 ..< 5 {
            XCTAssertEqual(set.find(element), element)
        }
    }

    func testUnionJoinsTwoElementsIntoOneSet() {
        var set = DisjointSet(count: 4)
        set.union(0, 1)
        XCTAssertEqual(set.find(0), set.find(1))
    }

    // MARK: - Section 2: single-linkage clustering / chain effect

    func testChainOfUnionsMergesEveryLinkIntoOneSet() {
        var set = DisjointSet(count: 4)
        set.union(0, 1)
        set.union(1, 2)
        set.union(2, 3)

        let root = set.find(0)
        XCTAssertEqual(set.find(1), root)
        XCTAssertEqual(set.find(2), root)
        XCTAssertEqual(set.find(3), root)
    }

    func testUnrelatedElementsStayInSeparateSets() {
        var set = DisjointSet(count: 4)
        set.union(0, 1)
        set.union(2, 3)

        XCTAssertEqual(set.find(0), set.find(1))
        XCTAssertEqual(set.find(2), set.find(3))
        XCTAssertNotEqual(set.find(0), set.find(2))
    }

    func testUnioningAlreadyMergedElementsIsANoOp() {
        var set = DisjointSet(count: 3)
        set.union(0, 1)
        let rootBefore = set.find(0)

        set.union(1, 0)

        XCTAssertEqual(set.find(0), rootBefore)
        XCTAssertEqual(set.find(1), rootBefore)
    }

    /// W-29: path compression must be iterative — a long chain is exactly what the chain effect
    /// (2.4) produces on a real library, and a recursive implementation could overflow the stack
    /// on one this long.
    func testLongChainDoesNotOverflowTheStack() {
        let count = 100_000
        var set = DisjointSet(count: count)
        for element in 1 ..< count {
            set.union(element - 1, element)
        }

        let root = set.find(0)
        XCTAssertEqual(set.find(count - 1), root)
    }
}
