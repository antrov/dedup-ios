//
//  HashStore.swift
//  DeDuP
//

import Foundation

/// Persistent cache of computed pHashes (W-06…W-14), behind a protocol so the GRDB-backed
/// implementation can be swapped for an in-memory fake in previews and tests. The database is
/// only a cache (W-14): every operation here must be safe to lose and rebuild from the photo
/// library.
protocol HashStore {
    /// Batched cache lookup for a specific set of assets (W-16): one query, not one per identifier.
    func load(identifiers: [String]) async throws -> [HashRecord]

    /// Every cached record, e.g. to feed grouping or restore the last known result on launch.
    func loadAll() async throws -> [HashRecord]

    /// Batched upsert (W-12): the whole array is written in a single transaction.
    func save(_ records: [HashRecord]) async throws

    /// Deletes specific records, e.g. after a photo is deleted from the library (W-44).
    func delete(identifiers: [String]) async throws

    /// Deletes every record whose identifier is not in `identifiers` (W-13): orphan cleanup
    /// after a full library scan.
    func deleteRecords(notIn identifiers: Set<String>) async throws

    /// Last known group assignment, keyed by local identifier (W-30, W-36).
    func groupAssignments() async throws -> [String: String]

    /// Overwrites group assignment for the given identifiers; `nil` clears it (W-36).
    func saveGroupAssignments(_ assignments: [String: String?]) async throws
}
