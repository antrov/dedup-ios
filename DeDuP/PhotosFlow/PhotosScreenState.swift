//
//  PhotosScreenState.swift
//  DeDuP
//

import Foundation

/// Progress of a phase as counts rather than a bare fraction, so the UI can show both a bar and
/// "1 234 / 50 000" without the view model publishing a second field for it.
struct PhaseProgress: Equatable {
    var completed = 0
    var total = 0

    var fraction: Double {
        guard total > 0 else { return 0 }
        return min(Double(completed) / Double(total), 1)
    }
}

/// How many of the photos the last scan saw ended up in each processing state (W-19, W-22,
/// W-43) — shown in the filters sheet so "no duplicates found" can be told apart from "half the
/// library hasn't been processed yet".
struct ProcessingCounts: Equatable {
    var libraryTotal = 0
    var computed = 0
    var cloudOnly = 0
    var failed = 0
    var unsupportedType = 0

    /// Photos that reached the pipeline but produced no usable hash, for whatever reason.
    var unprocessed: Int {
        cloudOnly + failed + unsupportedType
    }
}

/// In an extension so the memberwise initializer survives for previews and tests.
extension ProcessingCounts {
    /// Tallies the cache rows of the photos the last scan saw.
    init(libraryTotal: Int, records: [HashRecord]) {
        self.init(libraryTotal: libraryTotal)
        for record in records {
            switch record.state {
            case .computed: computed += 1
            case .cloudOnly: cloudOnly += 1
            case .failed: failed += 1
            case .unsupportedType: unsupportedType += 1
            }
        }
    }
}

/// The whole state of the photos screen as a single value (W-38), replacing the loose
/// `progress` / `scanPhase` / `assetsGroups` fields `PhotosViewModel` used to publish. Those
/// couldn't express the difference between "still scanning" and "finished and found nothing" —
/// both were an empty list — and allowed combinations that mean nothing, such as a half-finished
/// progress next to a final result.
enum PhotosScreenState: Equatable {
    /// Nothing has started yet; the view's own task is what leaves this state (W-40).
    case idle
    /// Access was refused: nothing to scan, and nothing to report as an error either.
    case authorizationDenied
    /// Work in progress, carrying the groups that stay on screen while it runs — a refresh
    /// (W-41) or a threshold change (W-39) must not blank the list out, and lose its scroll
    /// position, for as long as a new result takes to arrive (B-14).
    case working(phase: Phase, groups: [AssetsGroup])
    case ready(groups: [AssetsGroup])
    /// A failed pass carries the groups for the same reason `working` does: the last result is
    /// still a valid answer for the hashes in memory, and hiding it behind a full-screen error
    /// would cost the user a usable list over a step that may well succeed on the next attempt.
    case failed(message: String, groups: [AssetsGroup])

    /// The piece of work being done, in the order the pipeline performs them.
    enum Phase: Equatable {
        /// Waiting on the system permission prompt. A phase rather than a state of its own so it
        /// goes through `enterPhase` like every other step: a refresh of a library the user has
        /// already granted access to passes through here, and must not blank the list out on the
        /// way in just because the permission is being re-checked.
        case requestingAuthorization
        /// `step` is which element of the library the progress in `PhaseProgress` describes
        /// (W-57) — the two run one after another, never interleaved, so there's always exactly
        /// one current answer to "which one."
        case scanningLibrary(step: LibraryScanStep, progress: PhaseProgress)
        case hashingImages(PhaseProgress)
        case grouping
    }

    /// Groups to display: the finished ones, or the ones a pass in flight is replacing.
    var groups: [AssetsGroup] {
        switch self {
        case let .working(_, groups), let .ready(groups), let .failed(_, groups):
            return groups
        case .idle, .authorizationDenied:
            return []
        }
    }

    var phase: Phase? {
        switch self {
        case let .working(phase, _):
            return phase
        case .idle, .authorizationDenied, .ready, .failed:
            return nil
        }
    }
}
