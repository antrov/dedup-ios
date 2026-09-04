//
//  BruteForcePairFinder.swift
//  DeDuP
//

import Foundation

/// Exact, parallelized all-pairs `PairFinder` (W-27): every pair `i < j` is compared, so the
/// result is exact rather than approximate. Reference measurement from the requirements doc:
/// 100k hashes is ~2.3s single-threaded and ~0.4s on 8 cores.
///
/// The index space of `i` is partitioned across threads **with a stride** (thread `k` takes
/// `i = k, k + threadCount, 2k + threadCount, …`) rather than contiguous blocks. Because the
/// inner loop only visits `j > i`, small values of `i` do far more work than large ones; a
/// contiguous split would leave whichever thread gets the smallest indices with much more work
/// than the rest, while striding spreads it evenly.
struct BruteForcePairFinder: PairFinder {
    func findPairs(hashes: [UInt64], threshold: Int, isCancelled: @Sendable () -> Bool) -> [HashPair] {
        let count = hashes.count
        guard count > 1, threshold >= 0 else { return [] }

        let threadCount = min(max(ProcessInfo.processInfo.activeProcessorCount, 1), count)
        var partials = [[HashPair]](repeating: [], count: threadCount)

        // Each thread only ever writes to its own index, so concurrent writes into
        // `partials` never touch the same memory and need no further synchronization.
        partials.withUnsafeMutableBufferPointer { buffer in
            DispatchQueue.concurrentPerform(iterations: threadCount) { thread in
                var found: [HashPair] = []
                var i = thread
                // Checked once per outer step rather than in the inner distance loop (W-32): this
                // runs entirely inside a GCD worker, with no Task of its own to read
                // `Task.isCancelled` from, so `isCancelled` is however `GroupingEngine` bridged
                // its own Task's cancellation in — a lock read on every outer step is cheap next
                // to the O(count - i) inner loop it guards, and checking it is still frequent
                // enough that a cancelled search stops promptly instead of running to completion.
                while i < count {
                    if isCancelled() { break }
                    let hashAtI = hashes[i]
                    for j in (i + 1) ..< count where PHash.distance(hashAtI, hashes[j]) <= threshold {
                        found.append(HashPair(i: i, j: j))
                    }
                    i += threadCount
                }
                buffer[thread] = found
            }
        }

        return partials.flatMap { $0 }
    }
}
