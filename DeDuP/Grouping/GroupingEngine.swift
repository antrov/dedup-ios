//
//  GroupingEngine.swift
//  DeDuP
//

import Foundation

/// Turns hashes into groups (W-32): finds similar pairs via `PairFinder`, unions them into
/// connected components via `DisjointSet`, discards singletons, and returns a result that is
/// deterministic and independent of input order. Pure Swift — no Photos/UIKit/SwiftUI imports —
/// so it runs equally well off the main actor, on plain arrays (W-34).
struct GroupingEngine: Sendable {
    /// One connected component of the similarity graph (section 2): a set of asset identifiers
    /// that are, directly or through a chain of intermediaries, all within the grouping
    /// threshold of each other. Nested inside `GroupingEngine` rather than top-level so it can't
    /// collide with `SwiftUI.Group`. Pure domain result — `PhotosViewModel` maps
    /// `memberIdentifiers` back onto `Asset`s for display.
    struct Group: Equatable, Sendable {
        /// Stable across re-groupings of the same data (W-30): the lexicographically smallest
        /// member identifier, never a freshly generated UUID.
        let id: String
        /// Sorted by identifier (W-31), so the same input always produces the same order even
        /// with nothing but identifiers and hashes to sort by at this layer.
        let memberIdentifiers: [String]
        /// Largest Hamming distance between any two members (W-33) — evidence of the chain
        /// effect (2.4) when it's much larger than the threshold that produced the group.
        let diameter: Int
    }

    private let pairFinder: PairFinder

    init(pairFinder: PairFinder = BruteForcePairFinder()) {
        self.pairFinder = pairFinder
    }

    /// Groups `identifiers[i]` (paired with hash `hashes[i]`) under single-linkage clustering at
    /// `threshold` (section 2 of the requirements doc): two elements land in the same group if
    /// they're connected, directly or through a chain of intermediaries, by edges of at most
    /// `threshold` Hamming distance. Groups of one are discarded.
    ///
    /// Cooperatively cancellable (W-32): checked before the pair search and again before
    /// building components, the two points expensive enough on a large library to matter.
    func makeGroups(identifiers: [String], hashes: [UInt64], threshold: Int) async throws -> [Group] {
        precondition(identifiers.count == hashes.count, "identifiers and hashes must be parallel arrays")
        guard identifiers.count > 1 else { return [] }

        try Task.checkCancellation()
        let pairs = pairFinder.findPairs(hashes: hashes, threshold: threshold)
        guard !pairs.isEmpty else { return [] }

        try Task.checkCancellation()
        var disjointSet = DisjointSet(count: identifiers.count)
        for pair in pairs {
            disjointSet.union(pair.i, pair.j)
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in identifiers.indices {
            membersByRoot[disjointSet.find(index), default: []].append(index)
        }

        return membersByRoot.values
            .filter { $0.count > 1 }
            .map { members in
                let sortedIdentifiers = members.map { identifiers[$0] }.sorted()
                return Group(
                    id: sortedIdentifiers.first ?? "",
                    memberIdentifiers: sortedIdentifiers,
                    diameter: PHash.diameter(of: members.map { hashes[$0] })
                )
            }
            .sorted { $0.id < $1.id }
    }
}
