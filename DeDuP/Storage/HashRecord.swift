//
//  HashRecord.swift
//  DeDuP
//

import Foundation

/// One row of the `asset_hashes` cache table (W-08): the last known pHash for a `PHAsset`,
/// the pipeline version and source modification date it was computed from (W-11), its
/// processing state (W-05, W-19, W-22), and its last known group assignment (W-30, W-36).
struct HashRecord: Equatable {
    enum State: Int, Equatable {
        /// A valid hash was computed successfully.
        case computed = 0
        /// The asset isn't available locally; hashing was skipped rather than fetching from iCloud (W-19).
        case cloudOnly = 1
        /// Hashing was attempted and failed; see `failureReason`.
        case failed = 2
        /// The asset isn't a supported media type (e.g. video).
        case unsupportedType = 3
    }

    let localIdentifier: String
    let phash: UInt64?
    let hashVersion: Int
    let modificationDate: Date?
    let creationDate: Date?
    let state: State
    let failureReason: String?
    var groupID: String?
    let updatedAt: Date
}
