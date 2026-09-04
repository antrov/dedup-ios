//
//  PairFinder.swift
//  DeDuP
//

import Foundation

/// A pair of indices into a hash array, always ordered `i < j` so a pair, its reverse, and a
/// self-pair are never counted as different results.
struct HashPair: Hashable, Sendable {
    let i: Int
    let j: Int
}

/// Finds every pair of hashes within `threshold` Hamming distance of each other (W-26).
///
/// An implementation's result must be complete (no qualifying pair is ever missed), free of
/// duplicates and self-pairs, and independent of the order `hashes` is given in. This is the one
/// seam `GroupingEngine` depends on, so a faster or approximate implementation (e.g. the
/// popcount prefilter in W-28) can be swapped in later without changing what a "pair" means.
///
/// `isCancelled` is polled periodically during the search (W-32): an implementation working
/// through a large search should check it every so often and return early — with whatever
/// partial, incomplete result it has so far — once it reports `true`. The caller never treats a
/// result produced this way as final (see `GroupingEngine`), so an incomplete result is safe.
protocol PairFinder: Sendable {
    func findPairs(hashes: [UInt64], threshold: Int, isCancelled: @Sendable () -> Bool) -> [HashPair]
}
