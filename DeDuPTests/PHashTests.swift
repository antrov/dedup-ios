//
//  PHashTests.swift
//  DeDuPTests
//

@testable import DeDuP
import XCTest

final class PHashTests: XCTestCase {
    func testConstants() {
        XCTAssertEqual(PHash.bitCount, 64)
        XCTAssertEqual(PHash.informativeBitCount, 49)
        XCTAssertEqual(PHash.alwaysZeroMask, 0x0101_0101_0101_01FF)
        XCTAssertEqual(PHash.informativeBitsMask, 0xFEFE_FEFE_FEFE_FE00)
        XCTAssertEqual(PHash.maxDistance, 49)
    }

    func testMasksPartitionAllBits() {
        XCTAssertEqual(PHash.alwaysZeroMask & PHash.informativeBitsMask, 0)
        XCTAssertEqual(PHash.alwaysZeroMask | PHash.informativeBitsMask, .max)
        XCTAssertEqual(PHash.alwaysZeroMask.nonzeroBitCount, PHash.bitCount - PHash.informativeBitCount)
        XCTAssertEqual(PHash.informativeBitsMask.nonzeroBitCount, PHash.informativeBitCount)
    }

    func testDistanceIsZeroForIdenticalHashes() {
        XCTAssertEqual(PHash.distance(0, 0), 0)
        XCTAssertEqual(PHash.distance(.max, .max), 0)
        XCTAssertEqual(PHash.distance(0x1234_5678_9ABC_DEF0, 0x1234_5678_9ABC_DEF0), 0)
    }

    func testDistanceCountsDifferingBits() {
        XCTAssertEqual(PHash.distance(0, 1), 1)
        XCTAssertEqual(PHash.distance(0, 0b1011), 3)
        XCTAssertEqual(PHash.distance(0, .max), 64)
    }

    func testDistanceIsSymmetric() {
        let lhs: UInt64 = 0x0F0F_0F0F_0F0F_0F0F
        let rhs: UInt64 = 0x1234_5678_9ABC_DEF0
        XCTAssertEqual(PHash.distance(lhs, rhs), PHash.distance(rhs, lhs))
    }

    func testZeroHashAndInformativeMaskAreValid() {
        XCTAssertTrue(PHash.isValid(0))
        XCTAssertTrue(PHash.isValid(PHash.informativeBitsMask))
    }

    func testHashWithAnyAlwaysZeroBitSetIsInvalid() {
        for shift in 0 ..< PHash.bitCount {
            let bit = UInt64(1) << shift
            guard PHash.alwaysZeroMask & bit != 0 else { continue }
            XCTAssertFalse(PHash.isValid(bit), "bit \(shift) should be flagged invalid")
        }
    }

    func testOSHashTypeErrorBitPatternIsInvalid() {
        // OSHashTypeError is defined as `-1` (OSTypes.m); reinterpreted as UInt64 that's all bits set.
        XCTAssertFalse(PHash.isValid(UInt64(bitPattern: -1)))
    }
}
