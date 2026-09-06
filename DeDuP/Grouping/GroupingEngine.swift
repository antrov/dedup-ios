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

    /// Bridges structured-concurrency cancellation into `PairFinder.findPairs`'s synchronous,
    /// `DispatchQueue.concurrentPerform`-parallelized search (W-32). Those worker closures run on
    /// GCD's thread pool with no Swift `Task` of their own, so they can't read `Task.isCancelled`
    /// directly; `withTaskCancellationHandler`'s `onCancel` is what actually observes
    /// cancellation — from whichever thread requested it — and flips this flag exactly once,
    /// which the workers can then poll safely from any thread.
    private final class CancellationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            lock.unlock()
        }
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
    /// Cooperatively cancellable (W-32): checked before the pair search, periodically *during*
    /// it via `CancellationFlag` (so a cancelled search on a large library stops promptly rather
    /// than running to completion), and again before building components.
    func makeGroups(identifiers: [String], hashes: [UInt64], threshold: Int) async throws -> [Group] {
        precondition(identifiers.count == hashes.count, "identifiers and hashes must be parallel arrays")
        guard identifiers.count > 1 else { return [] }

        try Task.checkCancellation()
        let cancellationFlag = CancellationFlag()
        let pairs = await withTaskCancellationHandler {
            pairFinder.findPairs(hashes: hashes, threshold: threshold, isCancelled: { cancellationFlag.isCancelled })
        } onCancel: {
            cancellationFlag.cancel()
        }
        try Task.checkCancellation()
        guard !pairs.isEmpty else { return [] }

        var disjointSet = DisjointSet(count: identifiers.count)
        for pair in pairs {
            disjointSet.union(pair.lowerIndex, pair.upperIndex)
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

    /// Every identifier that was considered mapped to the group it ended up in, or `nil` if it
    /// ended up in none (W-36) — the shape `HashStore.saveGroupAssignments` persists. Built for
    /// the whole input at once so an identifier that dropped out of a group doesn't keep
    /// pointing at one that no longer holds it.
    static func assignments(for identifiers: [String], in groups: [Group]) -> [String: String?] {
        var groupIDByIdentifier: [String: String] = [:]
        for group in groups {
            for identifier in group.memberIdentifiers {
                groupIDByIdentifier[identifier] = group.id
            }
        }
        // `uniqueKeysWithValues` would trap on a repeated identifier, which is the one thing the
        // caller already goes out of its way to survive: a photo listed twice is worth showing
        // twice, not worth taking the app down for. Both entries map to the same group anyway.
        return Dictionary(identifiers.map { ($0, groupIDByIdentifier[$0]) }, uniquingKeysWith: { first, _ in first })
    }
}
