//
//  ImageHashingService.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos
import CocoaImageHashing

/// Perceptual-hash computation and comparison, behind a protocol so the (slow, PhotoKit-backed)
/// real implementation can be swapped for a fake in previews and tests.
protocol ImageHashingServiceProtocol {
    func hash(for asset: LibraryAsset) async throws -> OSHashType
    func distance(_ lhs: OSHashType, _ rhs: OSHashType) -> OSHashDistanceType
}

final class ImageHashingService: ImageHashingServiceProtocol {

    private struct HashingError: Error {
        let reason: String
    }

    private static let requestOptions: PHImageRequestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        return options
    }()

    private let imageManager = PHCachingImageManager()
    private let timeout = DispatchTimeInterval.seconds(5)
    private let imageSize = CGSize(width: 50, height: 50)

    func hash(for libraryAsset: LibraryAsset) async throws -> OSHashType {
        let asset = libraryAsset.asset
        guard asset.mediaType == .image else { throw HashingError(reason: "unsupported media type") }

        return try await withCheckedThrowingContinuation { continuation in
            var timedOut = false
            let timeoutTask = DispatchWorkItem {
                timedOut = true
                continuation.resume(throwing: HashingError(reason: "timeout"))
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutTask)

            imageManager.requestImage(for: asset, targetSize: imageSize, contentMode: .aspectFit, options: Self.requestOptions) { image, info in
                guard !timedOut else { return }
                guard info?[PHImageResultIsDegradedKey] as? NSNumber != 1 else { return }
                timeoutTask.cancel()

                if let error = info?[PHImageErrorKey] as? NSError {
                    continuation.resume(throwing: error)
                } else if let image, let data = image.pngData() {
                    continuation.resume(returning: OSImageHashing.sharedInstance().hashImageData(data, with: .pHash))
                } else {
                    continuation.resume(throwing: HashingError(reason: "empty image data"))
                }
            }
        }
    }

    func distance(_ lhs: OSHashType, _ rhs: OSHashType) -> OSHashDistanceType {
        OSImageHashing.sharedInstance().hashDistance(lhs, to: rhs, with: .pHash)
    }
}
