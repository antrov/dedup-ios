//
//  BoundedConcurrency.swift
//  DeDuP
//

import Foundation

/// Runs `operation` over `elements` with at most `maxConcurrency` tasks in flight at once (W-15):
/// `maxConcurrency` tasks are started up front, and each next one is only added once an in-flight
/// task finishes — instead of starting one task per element immediately, which floods whatever
/// `operation` calls into (B-05).
///
/// `onElementCompleted` fires once per finished element, called from the single loop that drains
/// the task group sequentially — never from a concurrently-running task — so it's free to mutate
/// state the caller captured by reference (e.g. a running progress count) without its own locking.
func mapWithBoundedConcurrency<Element, Result: Sendable>(
    _ elements: [Element],
    maxConcurrency: Int,
    onElementCompleted: (() async -> Void)? = nil,
    operation: @escaping @Sendable (Element) async -> Result
) async -> [Result] {
    guard maxConcurrency > 0, !elements.isEmpty else { return [] }

    return await withTaskGroup(of: Result.self, returning: [Result].self) { group in
        var iterator = elements.makeIterator()

        func addNext() {
            // A cancelled caller stops feeding the window rather than working the input out to
            // the end. The operations already in flight are left to finish — their results are
            // worth keeping, and they are bounded by `maxConcurrency` — but nothing behind them
            // starts. Without this, work stopped only where the caller happened to check between
            // calls, which for the hashing pipeline is once per 500 photos: long enough that a
            // screen the user had left kept the CPU busy for the rest of the batch.
            guard !Task.isCancelled, let element = iterator.next() else { return }
            group.addTask { await operation(element) }
        }

        for _ in 0 ..< min(maxConcurrency, elements.count) {
            addNext()
        }

        var results: [Result] = []
        results.reserveCapacity(elements.count)

        for await result in group {
            results.append(result)
            await onElementCompleted?()
            addNext()
        }

        return results
    }
}
