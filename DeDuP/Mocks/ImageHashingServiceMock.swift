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
        var hashToReturn: OSHashType = 0
        var distanceToReturn: OSHashDistanceType = 0

        func hash(for _: LibraryAsset) async throws -> OSHashType {
            hashToReturn
        }

        func distance(_: OSHashType, _: OSHashType) -> OSHashDistanceType {
            distanceToReturn
        }
    }

#endif
