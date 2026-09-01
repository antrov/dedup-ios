//
//  PairFinderTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class PairFinderTests: XCTestCase {
    private let finder = BruteForcePairFinder()

    func testFindsPairWithinThreshold() {
        let hashes: [UInt64] = [0b0000, 0b0001]
        let pairs = finder.findPairs(hashes: hashes, threshold: 1)
        XCTAssertEqual(pairs, [HashPair(i: 0, j: 1)])
    }

    func testExcludesPairAboveThreshold() {
        let hashes: [UInt64] = [0b0000, 0b0111]
        XCTAssertTrue(finder.findPairs(hashes: hashes, threshold: 1).isEmpty)
    }

    func testPairsAreOrderedWithLowerIndexFirst() {
        let hashes: [UInt64] = [0, 0]
        let pairs = finder.findPairs(hashes: hashes, threshold: 0)
        XCTAssertEqual(pairs, [HashPair(i: 0, j: 1)])
    }

    // MARK: - W-26 contract: complete, no duplicates, no self-pairs

    func testNoSelfPairsOrDuplicatesAmongIdenticalHashes() {
        let hashes: [UInt64] = Array(repeating: 0, count: 20)
        let pairs = finder.findPairs(hashes: hashes, threshold: 0)

        XCTAssertTrue(pairs.allSatisfy { $0.i != $0.j })
        XCTAssertEqual(Set(pairs).count, pairs.count, "no pair should be reported twice")
        XCTAssertEqual(pairs.count, 20 * 19 / 2, "every one of the C(20, 2) pairs should be found")
    }

    func testMatchesNaiveDoubleLoopOnRandomData() {
        let hashes: [UInt64] = (0 ..< 200).map { _ in UInt64.random(in: .min ... .max) }
        let threshold = 20

        var expected = Set<HashPair>()
        for i in hashes.indices {
            for j in (i + 1) ..< hashes.count where PHash.distance(hashes[i], hashes[j]) <= threshold {
                expected.insert(HashPair(i: i, j: j))
            }
        }

        let actual = Set(finder.findPairs(hashes: hashes, threshold: threshold))
        XCTAssertEqual(actual, expected)
    }

    func testEmptyAndSingleElementInputsProduceNoPairs() {
        XCTAssertTrue(finder.findPairs(hashes: [], threshold: 10).isEmpty)
        XCTAssertTrue(finder.findPairs(hashes: [42], threshold: 10).isEmpty)
    }
}
