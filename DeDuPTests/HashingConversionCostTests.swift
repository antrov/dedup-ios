//
//  HashingConversionCostTests.swift
//  DeDuPTests
//

import CocoaImageHashing
@testable import DeDuP
import UIKit
import XCTest

/// One-off measurement backing W-25: how much of the time to hash one asset is spent converting
/// the thumbnail to PNG data (`UIImage.pngData()`) versus CocoaImageHashing decoding it back and
/// running the actual pHash algorithm (`hashImageData(_:with:)`). Not a pass/fail regression gate
/// — timings vary by machine — its purpose is to print the measured split, so W-25's "don't
/// optimize without measuring" requirement has a real number behind it instead of a guess. See the
/// result documented on `ImageHashingService.outcome(image:info:)`.
final class HashingConversionCostTests: XCTestCase {
    func testMeasuresPNGConversionShareOfHashingTime() throws {
        // Same thumbnail size ImageHashingService actually requests from PhotoKit (W-17), so this
        // measures the conversion PhotoKit's result actually goes through, not an arbitrary size.
        let targetSize = CGSize(width: 50, height: 50)
        let imageNames = ["StockPhoto1", "StockPhoto2", "StockPhoto3", "StockPhoto4", "StockPhoto5"]
        let iterations = 50

        var totalConversion: TimeInterval = 0
        var totalHashing: TimeInterval = 0
        var measured = 0

        for name in imageNames {
            guard let original = UIImage(named: name), let thumbnail = original.resized(to: targetSize) else { continue }

            for _ in 0 ..< iterations {
                let conversionStart = CFAbsoluteTimeGetCurrent()
                let data = try XCTUnwrap(thumbnail.pngData())
                let conversionEnd = CFAbsoluteTimeGetCurrent()

                let hash = OSImageHashing.sharedInstance().hashImageData(data, with: .pHash)
                let hashingEnd = CFAbsoluteTimeGetCurrent()

                XCTAssertNotEqual(hash, OSHashTypeError)
                totalConversion += conversionEnd - conversionStart
                totalHashing += hashingEnd - conversionEnd
                measured += 1
            }
        }

        try XCTSkipIf(measured == 0, "no stock photo assets available to measure")

        let totalTime = totalConversion + totalHashing
        let conversionSharePercent = totalConversion / totalTime * 100
        let avgConversionMs = (totalConversion / Double(measured)) * 1000
        let avgHashingMs = (totalHashing / Double(measured)) * 1000

        let report = """
        [W-25] PNG conversion vs. hashing, \(measured) samples at \(Int(targetSize.width))x\(Int(targetSize.height)):
          avg pngData():        \(String(format: "%.3f", avgConversionMs)) ms
          avg hashImageData():  \(String(format: "%.3f", avgHashingMs)) ms
          conversion share:     \(String(format: "%.1f", conversionSharePercent))%
        """
        print(report)
    }
}

private extension UIImage {
    func resized(to size: CGSize) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: size))
        }
    }
}
