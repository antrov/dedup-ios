//
//  PairFinderTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class PairFinderTests: XCTestCase {
    private let finder = BruteForcePairFinder()

    /// Most tests below don't care about cancellation — this keeps them from having to repeat
    /// `isCancelled: { false }` at every call site.
    private func findPairs(hashes: [UInt64], threshold: Int) -> [HashPair] {
        finder.findPairs(hashes: hashes, threshold: threshold, isCancelled: { false })
    }

    func testFindsPairWithinThreshold() {
        let hashes: [UInt64] = [0b0000, 0b0001]
        let pairs = findPairs(hashes: hashes, threshold: 1)
        XCTAssertEqual(pairs, [HashPair(lowerIndex: 0, upperIndex: 1)])
    }

    func testExcludesPairAboveThreshold() {
        let hashes: [UInt64] = [0b0000, 0b0111]
        XCTAssertTrue(findPairs(hashes: hashes, threshold: 1).isEmpty)
    }

    func testPairsAreOrderedWithLowerIndexFirst() {
        let hashes: [UInt64] = [0, 0]
        let pairs = findPairs(hashes: hashes, threshold: 0)
        XCTAssertEqual(pairs, [HashPair(lowerIndex: 0, upperIndex: 1)])
    }

    // MARK: - W-26 contract: complete, no duplicates, no self-pairs

    func testNoSelfPairsOrDuplicatesAmongIdenticalHashes() {
        let hashes: [UInt64] = Array(repeating: 0, count: 20)
        let pairs = findPairs(hashes: hashes, threshold: 0)

        XCTAssertTrue(pairs.allSatisfy { $0.lowerIndex != $0.upperIndex })
        XCTAssertEqual(Set(pairs).count, pairs.count, "no pair should be reported twice")
        XCTAssertEqual(pairs.count, 20 * 19 / 2, "every one of the C(20, 2) pairs should be found")
    }

    func testMatchesNaiveDoubleLoopOnRandomData() {
        let hashes: [UInt64] = (0 ..< 200).map { _ in UInt64.random(in: .min ... .max) }
        let threshold = 20

        var expected = Set<HashPair>()
        for lowerIndex in hashes.indices {
            for upperIndex in (lowerIndex + 1) ..< hashes.count {
                guard PHash.distance(hashes[lowerIndex], hashes[upperIndex]) <= threshold else { continue }
                expected.insert(HashPair(lowerIndex: lowerIndex, upperIndex: upperIndex))
            }
        }

        let actual = Set(findPairs(hashes: hashes, threshold: threshold))
        XCTAssertEqual(actual, expected)
    }

    func testEmptyAndSingleElementInputsProduceNoPairs() {
        XCTAssertTrue(findPairs(hashes: [], threshold: 10).isEmpty)
        XCTAssertTrue(findPairs(hashes: [42], threshold: 10).isEmpty)
    }

    // MARK: - W-32: cancellation is observed inside the search, not just around it

    func testAlreadyCancelledSearchReturnsBeforeCompletingEveryPair() {
        let hashes: [UInt64] = Array(repeating: 0, count: 5000)
        let pairs = finder.findPairs(hashes: hashes, threshold: 0, isCancelled: { true })
        XCTAssertTrue(pairs.isEmpty, "a search cancelled from the start shouldn't report any pairs")
    }
}
