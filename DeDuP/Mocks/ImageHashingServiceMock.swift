//
//  ImageHashingServiceMock.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

#if DEBUG

    import CocoaImageHashing
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
        var distanceToReturn: OSHashDistanceType = 0

        private let callLog = CallLog()

        var hashCallCount: Int {
            get async { await callLog.hashCallCount }
        }

        var networkAccessRequests: [Bool] {
            get async { await callLog.networkAccessRequests }
        }

        func hash(for _: LibraryAsset, allowsNetworkAccess: Bool) async -> HashOutcome {
            await callLog.record(allowsNetworkAccess: allowsNetworkAccess)
            return outcomeToReturn
        }

        func distance(_: OSHashType, _: OSHashType) -> OSHashDistanceType {
            distanceToReturn
        }
    }

#endif
