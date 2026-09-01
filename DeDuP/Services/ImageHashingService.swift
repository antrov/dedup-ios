//
//  ImageHashingService.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import CocoaImageHashing
import Foundation
import Photos
import UIKit

/// Version of the hashing pipeline (W-23): bump whenever a change to the image request
/// parameters below, the image conversion, or the hashing algorithm would change the resulting
/// hash for the same asset. It's the only mechanism that invalidates cached hashes (W-11) computed
/// by a since-changed pipeline.
enum HashingPipeline {
    static let version = 1
}

/// Result of one hashing attempt (W-19, W-22): either a valid hash, or the specific reason one
/// couldn't be produced. Maps directly onto `HashRecord.State`, so a failure is always recorded
/// instead of silently dropping the asset (B-09).
enum HashOutcome: Equatable, Sendable {
    case computed(UInt64)
    case cloudOnly
    case unsupportedType
    case failed(reason: String)
}

/// Perceptual-hash computation, behind a protocol so the (slow, PhotoKit-backed) real
/// implementation can be swapped for a fake in previews and tests.
protocol ImageHashingServiceProtocol {
    /// Computes a pHash for `asset`. `allowsNetworkAccess` gates whether PhotoKit may download
    /// the asset from iCloud when it isn't stored locally (W-19) — regular scans always pass
    /// `false` (B-06); only the explicit "fetch missing" retry action passes `true`.
    func hash(for asset: LibraryAsset, allowsNetworkAccess: Bool) async -> HashOutcome
}

final class ImageHashingService: ImageHashingServiceProtocol {
    /// Guards a continuation so it resumes exactly once, no matter which of the competing
    /// PhotoKit result handler / timeout fires first (W-18). The earlier code raced on a plain
    /// `Bool` read and written from two threads, which could resume the same continuation twice
    /// and crash the process (B-08).
    private final class ResumeOnce: @unchecked Sendable {
        private let lock = NSLock()
        private var didRun = false

        func run(_ body: () -> Void) {
            lock.lock()
            let shouldRun = !didRun
            didRun = true
            lock.unlock()
            guard shouldRun else { return }
            body()
        }
    }

    /// Complete, deterministic thumbnail request parameters (W-17): a fixed target size and
    /// content mode, `resizeMode = .exact` so PhotoKit always resizes to that exact size instead
    /// of an approximate "fast" one, and `deliveryMode = .highQualityFormat` so the result handler
    /// fires exactly once with the best available image — never the two-stage (degraded, then
    /// final) sequence `.opportunistic` can produce. Changing any of these values changes what the
    /// hash is computed from, and requires bumping `HashingPipeline.version`.
    private static let imageSize = CGSize(width: 50, height: 50)
    private static let contentMode: PHImageContentMode = .aspectFit

    private static func requestOptions(allowsNetworkAccess: Bool) -> PHImageRequestOptions {
        let options = PHImageRequestOptions()
        options.resizeMode = .exact
        options.deliveryMode = .highQualityFormat
        options.isNetworkAccessAllowed = allowsNetworkAccess
        options.isSynchronous = false
        return options
    }

    /// Local-only requests should resolve almost instantly. Network requests are an explicit,
    /// user-initiated iCloud download (W-19) and are given much more room — the previous single
    /// 5s timeout applied even while a full-size image was being downloaded from iCloud, so cloud
    /// assets were reliably lost after paying the full download cost (B-07).
    private static let localTimeout = DispatchTimeInterval.seconds(5)
    private static let networkTimeout = DispatchTimeInterval.seconds(60)

    private let imageManager = PHCachingImageManager()

    func hash(for libraryAsset: LibraryAsset, allowsNetworkAccess: Bool) async -> HashOutcome {
        let asset = libraryAsset.asset
        guard asset.mediaType == .image else { return .unsupportedType }

        return await withCheckedContinuation { continuation in
            let resumeOnce = ResumeOnce()
            let options = Self.requestOptions(allowsNetworkAccess: allowsNetworkAccess)

            var requestID = PHInvalidImageRequestID
            requestID = imageManager.requestImage(
                for: asset,
                targetSize: Self.imageSize,
                contentMode: Self.contentMode,
                options: options
            ) { image, info in
                resumeOnce.run {
                    continuation.resume(returning: Self.outcome(image: image, info: info))
                }
            }

            let timeout = allowsNetworkAccess ? Self.networkTimeout : Self.localTimeout
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { [imageManager] in
                resumeOnce.run {
                    imageManager.cancelImageRequest(requestID)
                    continuation.resume(returning: .failed(reason: "timeout"))
                }
            }
        }
    }

    private static func outcome(image: UIImage?, info: [AnyHashable: Any]?) -> HashOutcome {
        if let error = info?[PHImageErrorKey] as? NSError {
            return .failed(reason: error.localizedDescription)
        }
        if info?[PHImageResultIsInCloudKey] as? Bool == true {
            return .cloudOnly
        }
        // W-25: `hashImageData:` is CocoaImageHashing's only entry point that doesn't require a
        // private header (see the requirements doc), so PNG round-tripping the thumbnail here is
        // unavoidable without vendoring the library. Measured (HashingConversionCostTests, 250
        // samples across 5 real photos, 50x50 thumbnails, this machine): `pngData()` is ~26% of
        // the combined pngData()+hashImageData() time (~3.9ms vs. ~11.1ms) — most of the cost is
        // in CocoaImageHashing's own decode-and-DCT step, which this call can't avoid either way.
        // Not worth optimizing on this evidence; re-measure before changing it.
        guard let image, let data = image.pngData() else {
            return .failed(reason: "empty image data")
        }

        let hashType = OSImageHashing.sharedInstance().hashImageData(data, with: .pHash)
        let hash = UInt64(bitPattern: hashType)
        guard PHash.isValid(hash) else {
            return .failed(reason: "invalid pHash bit pattern (W-05)")
        }
        return .computed(hash)
    }
}
