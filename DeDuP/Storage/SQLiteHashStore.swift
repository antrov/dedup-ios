//
//  SQLiteHashStore.swift
//  DeDuP
//

import Foundation
import GRDB

/// GRDB-backed `HashStore` (W-07). Every operation is one query or one write transaction —
/// never one per row (W-12).
final class SQLiteHashStore: HashStore {
    private let database: AppDatabase

    init(database: AppDatabase) {
        self.database = database
    }

    func load(identifiers: [String]) async throws -> [HashRecord] {
        guard !identifiers.isEmpty else { return [] }
        return try await database.dbQueue.read { db in
            try HashRecord.fetchAll(db, keys: identifiers)
        }
    }

    func loadAll() async throws -> [HashRecord] {
        try await database.dbQueue.read { db in
            try HashRecord.fetchAll(db)
        }
    }

    func save(_ records: [HashRecord]) async throws {
        guard !records.isEmpty else { return }
        try await database.dbQueue.write { db in
            for record in records {
                try record.save(db)
            }
        }
    }

    func delete(identifiers: [String]) async throws {
        guard !identifiers.isEmpty else { return }
        try await database.dbQueue.write { db in
            _ = try HashRecord.deleteAll(db, keys: identifiers)
        }
    }

    func deleteRecords(notIn identifiers: Set<String>) async throws {
        try await database.dbQueue.write { db in
            let existing = try Set(String.fetchAll(db, sql: "SELECT local_identifier FROM asset_hashes"))
            let orphaned = Array(existing.subtracting(identifiers))
            guard !orphaned.isEmpty else { return }
            _ = try HashRecord.deleteAll(db, keys: orphaned)
        }
    }

    func groupAssignments() async throws -> [String: String] {
        try await database.dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT local_identifier, group_id FROM asset_hashes WHERE group_id IS NOT NULL")
            let pairs: [(String, String)] = rows.map { row in (row["local_identifier"], row["group_id"]) }
            return Dictionary(uniqueKeysWithValues: pairs)
        }
    }

    func saveGroupAssignments(_ assignments: [String: String?]) async throws {
        guard !assignments.isEmpty else { return }
        let now = Date()
        try await database.dbQueue.write { db in
            for (identifier, groupID) in assignments {
                try db.execute(
                    sql: "UPDATE asset_hashes SET group_id = ?, updated_at = ? WHERE local_identifier = ?",
                    arguments: [groupID, now, identifier]
                )
            }
        }
    }
}

// MARK: - GRDB record mapping

extension HashRecord: FetchableRecord {
    init(row: Row) throws {
        localIdentifier = row["local_identifier"]
        // Stored as its Int64 bit pattern: SQLite integers are signed 64-bit, and
        // CocoaImageHashing's OSHashType can legitimately have its top bit set (W-08).
        phash = (row["phash"] as Int64?).map(UInt64.init(bitPattern:))
        hashVersion = row["hash_version"]
        modificationDate = row["modification_date"]
        creationDate = row["creation_date"]
        state = State(rawValue: row["state"]) ?? .failed
        failureReason = row["failure_reason"]
        groupID = row["group_id"]
        updatedAt = row["updated_at"]
        collectionIdentifiers = ((row["collection_identifiers"] as String?) ?? "")
            .split(separator: ",")
            .map(String.init)
    }
}

extension HashRecord: PersistableRecord {
    static let databaseTableName = "asset_hashes"

    func encode(to container: inout PersistenceContainer) {
        container["local_identifier"] = localIdentifier
        container["phash"] = phash.map { Int64(bitPattern: $0) }
        container["hash_version"] = hashVersion
        container["modification_date"] = modificationDate
        container["creation_date"] = creationDate
        container["state"] = state.rawValue
        container["failure_reason"] = failureReason
        container["group_id"] = groupID
        container["updated_at"] = updatedAt
        container["collection_identifiers"] = collectionIdentifiers.isEmpty ? nil : collectionIdentifiers.joined(separator: ",")
    }
}
