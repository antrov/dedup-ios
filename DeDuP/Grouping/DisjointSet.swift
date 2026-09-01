//
//  DisjointSet.swift
//  DeDuP
//

import Foundation

/// Disjoint-set (union-find) over the integers `0..<count` (W-29): union by rank with path
/// compression, both implemented iteratively rather than recursively so that a long chain of
/// unions — exactly what the chain effect (2.4) produces — can't recurse deep enough to overflow
/// the stack. Backed by plain index-addressed arrays rather than a dictionary keyed by
/// identifier, which would cost far more memory at the size a full photo library reaches.
struct DisjointSet {
    private var parent: [Int]
    private var rank: [Int]

    init(count: Int) {
        parent = Array(0 ..< count)
        rank = Array(repeating: 0, count: count)
    }

    /// The representative ("root") of the set containing `element`, compressing the path to it
    /// so future lookups through the same nodes are cheaper.
    mutating func find(_ element: Int) -> Int {
        var root = element
        while parent[root] != root {
            root = parent[root]
        }

        var current = element
        while parent[current] != root {
            let next = parent[current]
            parent[current] = root
            current = next
        }

        return root
    }

    /// Merges the sets containing `first` and `second`. A no-op if they're already the same set.
    mutating func union(_ first: Int, _ second: Int) {
        let firstRoot = find(first)
        let secondRoot = find(second)
        guard firstRoot != secondRoot else { return }

        if rank[firstRoot] < rank[secondRoot] {
            parent[firstRoot] = secondRoot
        } else if rank[firstRoot] > rank[secondRoot] {
            parent[secondRoot] = firstRoot
        } else {
            parent[secondRoot] = firstRoot
            rank[firstRoot] += 1
        }
    }
}
