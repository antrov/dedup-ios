//
//  HashStoreMock.swift
//  DeDuP
//

#if DEBUG

    import Foundation

    final class HashStoreMock: HashStore {
        var records: [String: HashRecord] = [:]
        /// Makes persisting the group assignment take measurable time, so a test can cancel a
        /// grouping pass while it is in that await rather than during the engine run.
        var saveGroupAssignmentsDelay: Duration?

        func load(identifiers: [String]) async throws -> [HashRecord] {
            identifiers.compactMap { records[$0] }
        }

        func loadAll() async throws -> [HashRecord] {
            Array(records.values)
        }

        func save(_ newRecords: [HashRecord]) async throws {
            for record in newRecords {
                records[record.localIdentifier] = record
            }
        }

        func delete(identifiers: [String]) async throws {
            for identifier in identifiers {
                records.removeValue(forKey: identifier)
            }
        }

        func deleteRecords(notIn identifiers: Set<String>) async throws {
            records = records.filter { identifiers.contains($0.key) }
        }

        func groupAssignments() async throws -> [String: String] {
            records.compactMapValues(\.groupID)
        }

        func saveGroupAssignments(_ assignments: [String: String?]) async throws {
            if let saveGroupAssignmentsDelay {
                try await Task.sleep(for: saveGroupAssignmentsDelay)
            }
            for (identifier, groupID) in assignments {
                records[identifier]?.groupID = groupID
            }
        }
    }

#endif
