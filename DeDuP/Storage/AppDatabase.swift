//
//  AppDatabase.swift
//  DeDuP
//

import Foundation
import GRDB

/// Owns the on-disk SQLite database: its location (W-10), connection, and migrations (W-09).
/// The database is a rebuildable cache (W-14): deleting the file, or hitting a failed
/// migration, is always recovered by starting over from scratch — never a fatal error.
final class AppDatabase {
    let dbQueue: DatabaseQueue

    private init(dbQueue: DatabaseQueue) throws {
        self.dbQueue = dbQueue
        try Self.migrator.migrate(dbQueue)
    }

    /// Opens (creating if needed) the on-disk cache database in Application Support, in a
    /// dedicated subdirectory excluded from iCloud/iTunes backup (W-10). If opening or
    /// migrating an existing file fails, the file is deleted and recreated from scratch (W-14).
    static func openOnDisk() throws -> AppDatabase {
        let dbURL = try cacheDirectoryURL().appendingPathComponent("hashes.sqlite")

        do {
            return try AppDatabase(dbQueue: DatabaseQueue(path: dbURL.path))
        } catch {
            try? FileManager.default.removeItem(at: dbURL)
            return try AppDatabase(dbQueue: DatabaseQueue(path: dbURL.path))
        }
    }

    /// In-memory database with the same schema, for previews and tests (W-52).
    static func openInMemory() throws -> AppDatabase {
        try AppDatabase(dbQueue: DatabaseQueue())
    }

    private static func cacheDirectoryURL() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        var directoryURL = applicationSupport.appendingPathComponent("DeDuP", isDirectory: true)
        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        try? directoryURL.setResourceValues(resourceValues)

        return directoryURL
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        // Migrations are named and, once released, never modified — only new ones appended.
        migrator.registerMigration("createAssetHashes") { db in
            try db.create(table: "asset_hashes") { table in
                table.column("local_identifier", .text).notNull().primaryKey()
                table.column("phash", .integer)
                table.column("hash_version", .integer).notNull()
                table.column("modification_date", .datetime)
                table.column("creation_date", .datetime)
                table.column("state", .integer).notNull()
                table.column("failure_reason", .text)
                table.column("group_id", .text)
                table.column("updated_at", .datetime).notNull()
            }
            try db.create(index: "asset_hashes_on_creation_date", on: "asset_hashes", columns: ["creation_date"])
            try db.create(index: "asset_hashes_on_group_id", on: "asset_hashes", columns: ["group_id"])
        }

        return migrator
    }
}
