//
//  PhotosTestSupport.swift
//  DeDuPTests
//

@testable import DeDuP
import Photos
import XCTest

/// `LibraryAsset` is identified — and de-duplicated inside the library set — by
/// `localIdentifier`, which a bare `PHAsset()` leaves empty for every instance. Any test that
/// needs more than one photo needs them to be distinguishable.
final class StubAsset: PHAsset, @unchecked Sendable {
    private let identifier: String
    private let source: PHAssetSourceType

    init(identifier: String, sourceType: PHAssetSourceType) {
        self.identifier = identifier
        source = sourceType
        super.init()
    }

    override var localIdentifier: String {
        identifier
    }

    /// What the `iCloudIncluded` filter looks at: `.typeCloudShared` is the one it excludes.
    override var sourceType: PHAssetSourceType {
        source
    }
}

func makeLibraryAsset(
    identifier: String = UUID().uuidString,
    sourceType: PHAssetSourceType = .typeUserLibrary
) -> LibraryAsset {
    LibraryAsset(asset: StubAsset(identifier: identifier, sourceType: sourceType), collection: nil)
}

func isHashing(_ state: PhotosScreenState) -> Bool {
    if case .hashingImages = state.phase {
        return true
    }
    return false
}

func isRequestingAuthorization(_ state: PhotosScreenState) -> Bool {
    if case .requestingAuthorization = state.phase {
        return true
    }
    return false
}

func isGrouping(_ state: PhotosScreenState) -> Bool {
    if case .grouping = state.phase {
        return true
    }
    return false
}

func isReady(_ state: PhotosScreenState) -> Bool {
    if case .ready = state {
        return true
    }
    return false
}

@MainActor
func makePhotosViewModel(
    photoLibrary: PhotoLibraryServiceMock = PhotoLibraryServiceMock(),
    hashing: ImageHashingServiceMock = ImageHashingServiceMock(),
    hashStore: HashStoreMock = HashStoreMock(),
    pairFinder: PairFinder = BruteForcePairFinder()
) -> PhotosViewModel {
    PhotosViewModel(
        photoLibrary: photoLibrary,
        hashing: hashing,
        hashStore: hashStore,
        groupingEngine: GroupingEngine(pairFinder: pairFinder)
    )
}

func makeHashRecord(
    identifier: String,
    phash: UInt64? = 1,
    hashVersion: Int = HashingPipeline.version,
    modificationDate: Date? = nil,
    state: HashRecord.State = .computed
) -> HashRecord {
    HashRecord(
        localIdentifier: identifier,
        phash: phash,
        hashVersion: hashVersion,
        modificationDate: modificationDate,
        creationDate: nil,
        state: state,
        failureReason: nil,
        groupID: nil,
        updatedAt: Date()
    )
}

/// Records how often the grouping engine was actually run, so a test can tell "re-grouped once"
/// apart from "re-grouped once per slider value" (W-39).
final class CountingPairFinder: PairFinder, @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func findPairs(hashes: [UInt64], threshold: Int, isCancelled: @Sendable () -> Bool) -> [HashPair] {
        lock.lock()
        calls += 1
        lock.unlock()
        return BruteForcePairFinder().findPairs(hashes: hashes, threshold: threshold, isCancelled: isCancelled)
    }
}

extension XCTestCase {
    /// Polls until `condition` holds, for asynchronous work with no completion to await — the
    /// debounced re-group (W-39) being the only such case here.
    func waitUntil(
        _ condition: () -> Bool,
        timeout: TimeInterval = 5,
        message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(condition(), message, file: file, line: line)
    }
}
