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

/// The whole state of the photos screen as a single value (W-38), replacing the loose
/// `progress` / `scanPhase` / `assetsGroups` fields `PhotosViewModel` used to publish. Those
/// couldn't express the difference between "still scanning" and "finished and found nothing" —
/// both were an empty list — and allowed combinations that mean nothing, such as a half-finished
/// progress next to a final result.
enum PhotosScreenState: Equatable {
    /// Nothing has started yet; the view's own task is what leaves this state (W-40).
    case idle
    /// Waiting on the system permission prompt.
    case requestingAuthorization
    /// Access was refused: nothing to scan, and nothing to report as an error either.
    case authorizationDenied
    /// Work in progress, carrying the groups that stay on screen while it runs — a refresh
    /// (W-41) or a threshold change (W-39) must not blank the list out, and lose its scroll
    /// position, for as long as a new result takes to arrive (B-14).
    case working(phase: Phase, groups: [AssetsGroup])
    case ready(groups: [AssetsGroup])
    case failed(message: String)

    /// The piece of work being done, in the order the pipeline performs them.
    enum Phase: Equatable {
        case scanningLibrary(PhaseProgress)
        case hashingImages(PhaseProgress)
        case grouping

        /// `nil` for work that has no countable unit to report progress against.
        var progress: PhaseProgress? {
            switch self {
            case let .scanningLibrary(progress), let .hashingImages(progress):
                return progress
            case .grouping:
                return nil
            }
        }
    }

    /// Groups to display: the finished ones, or the ones currently being replaced.
    var groups: [AssetsGroup] {
        switch self {
        case let .working(_, groups), let .ready(groups):
            return groups
        case .idle, .requestingAuthorization, .authorizationDenied, .failed:
            return []
        }
    }

    var phase: Phase? {
        switch self {
        case let .working(phase, _):
            return phase
        case .idle, .requestingAuthorization, .authorizationDenied, .ready, .failed:
            return nil
        }
    }
}
