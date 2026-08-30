//
//  PHash.swift
//  DeDuP
//

import Foundation

/// Invariants and pure bit operations for the 64-bit pHash produced by CocoaImageHashing's
/// `OSImageHashingProviderPHash`. Deliberately free of Photos/UIKit/SwiftUI/CocoaImageHashing
/// imports so the domain layer stays testable without a device or photo library access.
enum PHash {
    /// Total number of bits in the hash code.
    static let bitCount = 64

    /// Number of bits that actually carry information. CocoaImageHashing's `INLINE_PHASH` macro
    /// (`OSFastGraphics.m`) only sets a bit when `row != 0 && col != 0` in the 8x8 DCT block, so
    /// row 0 and column 0 (15 bits) are always zero.
    static let informativeBitCount = 49

    /// Bits CocoaImageHashing never sets (row 0 and column 0 of the DCT block).
    static let alwaysZeroMask: UInt64 = 0x0101_0101_0101_01FF

    /// Complement of `alwaysZeroMask` within 64 bits: the bits that carry information.
    static let informativeBitsMask: UInt64 = 0xFEFE_FEFE_FEFE_FE00

    /// Largest possible distance between two valid hashes, equal to `informativeBitCount`.
    static let maxDistance = 49

    /// Hamming distance between two hashes: the number of bits by which they differ.
    static func distance(_ lhs: UInt64, _ rhs: UInt64) -> Int {
        (lhs ^ rhs).nonzeroBitCount
    }

    /// A hash is valid only if none of the always-zero bits are set. `OSHashTypeError` (`-1`,
    /// i.e. all 64 bits set) is rejected by this same check, since it necessarily sets every bit
    /// in `alwaysZeroMask` too — no separate case is needed for it.
    static func isValid(_ hash: UInt64) -> Bool {
        hash & alwaysZeroMask == 0
    }
}
