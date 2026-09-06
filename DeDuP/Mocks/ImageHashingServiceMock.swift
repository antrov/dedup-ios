//
//  ImageHashingServiceMock.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

#if DEBUG

    import Foundation

    final class ImageHashingServiceMock: ImageHashingServiceProtocol {
        /// Isolates the call log so concurrent `hash(for:allowsNetworkAccess:)` calls from a
        /// bounded-concurrency task group (W-15) can record themselves without a data race.
        private actor CallLog {
            private(set) var hashCallCount = 0
            private(set) var networkAccessRequests: [Bool] = []

            func record(allowsNetworkAccess: Bool) {
                hashCallCount += 1
                networkAccessRequests.append(allowsNetworkAccess)
            }
        }

        var outcomeToReturn: HashOutcome = .computed(0)
        /// Makes hashing take measurable time, so a test can act while a scan is still running.
        var delay: Duration?

        private let callLog = CallLog()

        var hashCallCount: Int {
            get async { await callLog.hashCallCount }
        }

        var networkAccessRequests: [Bool] {
            get async { await callLog.networkAccessRequests }
        }

        func hash(for _: LibraryAsset, allowsNetworkAccess: Bool) async -> HashOutcome {
            await callLog.record(allowsNetworkAccess: allowsNetworkAccess)
            if let delay {
                // Detached, so cancelling the scan doesn't cut the wait short. The real hasher
                // has no cancellation handling: a PhotoKit request already in flight runs to its
                // result or its timeout (W-18), which is why a cancelled scan takes as long to
                // unwind as its outstanding requests. A plain `Task.sleep` here would return the
                // instant a scan was cancelled, making unwinding look free in tests alone.
                await Task.detached { try? await Task.sleep(for: delay) }.value
            }
            return outcomeToReturn
        }
    }

#endif
