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

    /// W-49: the finder must match a naive double loop as a set — including pairs that would
    /// be easy to miss if a filter or a parallel split dropped "known-close" neighbours.
    func testMatchesNaiveDoubleLoopOnRandomDataWithForcedClosePairs() {
        var hashes: [UInt64] = (0 ..< 200).map { _ in UInt64.random(in: .min ... .max) }
        hashes[0] = PHash.informativeBitsMask
        hashes[1] = PHash.informativeBitsMask
        hashes[2] = PHash.informativeBitsMask ^ (UInt64(1) << 9)
        hashes[3] = PHash.informativeBitsMask ^ (UInt64(1) << 9) ^ (UInt64(1) << 17)
        hashes[50] = 0
        hashes[199] = 0
        let threshold = 4

        var expected = Set<HashPair>()
        for lowerIndex in hashes.indices {
            for upperIndex in (lowerIndex + 1) ..< hashes.count {
                guard PHash.distance(hashes[lowerIndex], hashes[upperIndex]) <= threshold else { continue }
                expected.insert(HashPair(lowerIndex: lowerIndex, upperIndex: upperIndex))
            }
        }

        let pairs = findPairs(hashes: hashes, threshold: threshold)
        XCTAssertTrue(pairs.allSatisfy { $0.lowerIndex != $0.upperIndex })
        XCTAssertEqual(Set(pairs).count, pairs.count, "no pair should be reported twice")
        XCTAssertEqual(Set(pairs), expected)
        XCTAssertTrue(expected.contains(HashPair(lowerIndex: 0, upperIndex: 1)))
        XCTAssertTrue(expected.contains(HashPair(lowerIndex: 0, upperIndex: 2)))
        XCTAssertTrue(expected.contains(HashPair(lowerIndex: 50, upperIndex: 199)))
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
