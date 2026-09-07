//
//  GroupingPerformanceTests.swift
//  DeDuPTests
//

import Darwin
@testable import DeDuP
import XCTest

/// W-53: all-pairs grouping on synthetic hashes (no PhotoKit) at the sizes the
/// requirements doc budgets for. Times are printed so W-28's optional popcount
/// prefilter can be decided from a number rather than a guess — this file does
/// not implement that prefilter.
///
/// The documented 0.4 s / 100k figure is a Release, 8-core pair-search. Debug
/// builds here also carry coverage instrumentation and were measured at ~3 s /
/// 10k, ~57 s / 50k, ~300 s / 100k — so the 50k and 100k budgets only apply
/// in Release; Debug still always gates 10k, which is enough to catch an
/// order-of-magnitude regression without making every `xcodebuild test` wait
/// five minutes.
final class GroupingPerformanceTests: XCTestCase {
    private let finder = BruteForcePairFinder()
    private let threshold = 4

    func testPairSearchTenThousandHashesStaysWithinBudget() {
        measurePairSearch(count: 10000, timeBudget: debugTimeBudget(release: 2, debug: 15))
    }

    func testPairSearchFiftyThousandHashesStaysWithinBudget() throws {
        try skipUnlessRelease()
        measurePairSearch(count: 50000, timeBudget: 8)
    }

    func testPairSearchOneHundredThousandHashesStaysWithinBudget() throws {
        try skipUnlessRelease()
        measurePairSearch(count: 100_000, timeBudget: 20)
    }

    /// Low threshold on random 64-bit values yields almost no pairs, so this
    /// measures the all-pairs scan, not the cost of storing a dense graph.
    private func measurePairSearch(count: Int, timeBudget: TimeInterval) {
        let hashes = (0 ..< count).map { _ in UInt64.random(in: .min ... .max) }
        let peakBefore = peakResidentMemoryBytes()

        let started = CFAbsoluteTimeGetCurrent()
        let pairs = finder.findPairs(hashes: hashes, threshold: threshold, isCancelled: { false })
        let elapsed = CFAbsoluteTimeGetCurrent() - started
        let peakAfter = peakResidentMemoryBytes()
        let peakDelta = peakAfter > peakBefore ? peakAfter - peakBefore : 0

        let report = """
        [W-53] pair search \(count) hashes, threshold \(threshold):
          wall time:     \(String(format: "%.3f", elapsed)) s (budget \(String(format: "%.0f", timeBudget)) s)
          pairs:         \(pairs.count)
          peak RSS before: \(peakBefore / 1_048_576) MiB
          peak RSS after:  \(peakAfter / 1_048_576) MiB
          peak RSS delta:  \(peakDelta / 1_048_576) MiB
        """
        print(report)

        XCTAssertLessThan(
            elapsed,
            timeBudget,
            "pair search of \(count) hashes took \(elapsed)s, budget is \(timeBudget)s"
        )
        // A dense pair list would allocate gigabytes; this only catches that class of leak.
        // `ru_maxrss` is the kernel high-water mark, so a spike that is freed before
        // `findPairs` returns still shows up in the delta.
        XCTAssertLessThan(peakDelta, 512 * 1_048_576, "peak RSS growth for \(count) hashes exceeded 512 MiB")
    }

    private func debugTimeBudget(release: TimeInterval, debug: TimeInterval) -> TimeInterval {
        #if DEBUG
            return debug
        #else
            return release
        #endif
    }

    private func skipUnlessRelease() throws {
        #if DEBUG
            throw XCTSkip(
                "50k/100k budgets are the Release figures from W-53; Debug+coverage is ~50–100× slower. " +
                    "Run: xcodebuild test -scheme DeDuP -configuration Release " +
                    "-only-testing:DeDuPTests/GroupingPerformanceTests"
            )
        #endif
    }

    /// Darwin `ru_maxrss` is the process high-water mark in bytes — not a post-return snapshot
    /// of current RSS — so a temporary buffer freed before `findPairs` returns still counts.
    private func peakResidentMemoryBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(usage.ru_maxrss)
    }
}
