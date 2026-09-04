//
//  AssetTests.swift
//  DeDuPTests
//

@testable import DeDuP
import Photos
import XCTest

/// W-42 / B-15: the grid cell drives thumbnail loading from a cancellable task and must not
/// re-request an image the model already holds.
@MainActor
final class AssetTests: XCTestCase {
    private static let size = CGSize(width: 200, height: 200)

    private func makeAsset(photoLibrary: PhotoLibraryServiceMock) -> Asset {
        Asset(libraryAsset: makeLibraryAsset(), pHash: 0, photoLibrary: photoLibrary)
    }

    func testThumbnailIsLoadedOnce() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let asset = makeAsset(photoLibrary: photoLibrary)

        await asset.loadThumbnail(size: Self.size)

        XCTAssertEqual(photoLibrary.thumbnailRequestCount, 1)
        XCTAssertNotNil(asset.thumbnail)
    }

    func testAlreadyLoadedThumbnailIsNotRequestedAgain() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let asset = makeAsset(photoLibrary: photoLibrary)

        await asset.loadThumbnail(size: Self.size)
        await asset.loadThumbnail(size: Self.size)
        await asset.loadThumbnail(size: Self.size)

        XCTAssertEqual(
            photoLibrary.thumbnailRequestCount,
            1,
            "a cell scrolling back into view must reuse the thumbnail it already has"
        )
    }

    func testCancelledLoadDoesNotPublishAThumbnail() async {
        let photoLibrary = PhotoLibraryServiceMock()
        let asset = makeAsset(photoLibrary: photoLibrary)

        let task = Task { await asset.loadThumbnail(size: Self.size) }
        task.cancel()
        await task.value

        XCTAssertNil(asset.thumbnail, "a cell that disappeared mid-request must not be filled in afterwards")
    }
}
