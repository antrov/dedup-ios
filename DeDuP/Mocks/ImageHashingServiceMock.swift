//
//  ImageHashingServiceMock.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

#if DEBUG

import Foundation
import CocoaImageHashing

final class ImageHashingServiceMock: ImageHashingServiceProtocol {

    var hashToReturn: OSHashType = 0
    var distanceToReturn: OSHashDistanceType = 0

    func hash(for asset: LibraryAsset) async throws -> OSHashType {
        hashToReturn
    }

    func distance(_ lhs: OSHashType, _ rhs: OSHashType) -> OSHashDistanceType {
        distanceToReturn
    }
}

#endif
