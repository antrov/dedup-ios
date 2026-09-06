//
//  BoundedConcurrencyTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

private actor ConcurrencyTracker {
    private var current = 0
    private(set) var maxObserved = 0

    func enter() {
        current += 1
        maxObserved = max(maxObserved, current)
    }

    func exit() {
        current -= 1
    }
}

private actor CallCounter {
    private(set) var count = 0

    func increment() {
        count += 1
    }
}

final class BoundedConcurrencyTests: XCTestCase {
    func testNeverExceedsMaxConcurrency() async {
        let maxConcurrency = 4
        let tracker = ConcurrencyTracker()

        let results = await mapWithBoundedConcurrency(Array(0 ..< 40), maxConcurrency: maxConcurrency) { element in
            await tracker.enter()
            try? await Task.sleep(nanoseconds: 2_000_000)
            await tracker.exit()
            return element * 2
        }

        let observedMax = await tracker.maxObserved
        XCTAssertLessThanOrEqual(observedMax, maxConcurrency)
        XCTAssertEqual(Set(results), Set((0 ..< 40).map { $0 * 2 }))
    }

    func testProcessesEveryElementExactlyOnce() async {
        let results = await mapWithBoundedConcurrency(Array(0 ..< 37), maxConcurrency: 5) { $0 }
        XCTAssertEqual(results.sorted(), Array(0 ..< 37))
    }

    func testEmptyInputReturnsEmptyOutput() async {
        let results = await mapWithBoundedConcurrency([Int](), maxConcurrency: 4) { $0 }
        XCTAssertTrue(results.isEmpty)
    }

    func testZeroMaxConcurrencyReturnsEmptyOutput() async {
        let results = await mapWithBoundedConcurrency([1, 2, 3], maxConcurrency: 0) { $0 }
        XCTAssertTrue(results.isEmpty)
    }

    func testOnElementCompletedFiresOnceForEveryElement() async {
        let counter = CallCounter()

        _ = await mapWithBoundedConcurrency(
            Array(0 ..< 23),
            maxConcurrency: 3,
            onElementCompleted: { await counter.increment() },
            operation: { $0 }
        )

        let count = await counter.count
        XCTAssertEqual(count, 23)
    }

    /// The hashing pipeline checks for cancellation once per batch of 500 photos (W-24), so how
    /// promptly a scan actually stops — the screen going away stops the work (W-40) — is decided
    /// here. Feeding the window to the end of the input means a cancelled scan keeps hashing for
    /// a screen nobody is looking at, for as long as the rest of the batch takes.
    func testCancellationStopsFeedingNewWork() async {
        let maxConcurrency = 2
        let counter = CallCounter()
        let work = Task {
            await mapWithBoundedConcurrency(Array(0 ..< 500), maxConcurrency: maxConcurrency) { element in
                await counter.increment()
                try? await Task.sleep(nanoseconds: 5_000_000)
                return element
            }
        }

        // Cancel once the window is full, so the run is genuinely under way.
        let deadline = Date().addingTimeInterval(5)
        while await counter.count < maxConcurrency, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        work.cancel()
        let results = await work.value

        let started = await counter.count
        XCTAssertGreaterThan(started, 0, "the test should have cancelled a run that was under way")
        XCTAssertLessThan(started, 500, "a cancelled caller shouldn't work the input out to the end")
        XCTAssertEqual(results.count, started, "whatever had already started still comes back")
    }

    func testHandlesFewerElementsThanMaxConcurrency() async {
        let results = await mapWithBoundedConcurrency([1, 2], maxConcurrency: 10) { $0 * 10 }
        XCTAssertEqual(Set(results), [10, 20])
    }
}
