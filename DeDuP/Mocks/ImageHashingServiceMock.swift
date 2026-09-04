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
                try? await Task.sleep(for: delay)
            }
            return outcomeToReturn
        }
    }

#endif
