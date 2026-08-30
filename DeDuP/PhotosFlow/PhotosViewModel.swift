//
//  PhotosViewModel.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos
import CocoaImageHashing

final class PhotosViewModel: ObservableObject {

    enum GroupsSorting {
        case newestToOldest
        case oldestToNewest

        mutating func toggle() {
            self = self == .newestToOldest ? .oldestToNewest : .newestToOldest
        }
    }

    struct AssetsFilter: OptionSet {
        let rawValue: UInt

        static let iCloudIncluded = AssetsFilter(rawValue: 1 << 0)
    }

    @Published private(set) var assetsGroups = [AssetsGroup]()
    @Published var distanceThreshold: Double = 4.0
    @Published private(set) var progress: Double = 0.0
    @Published var sorting = GroupsSorting.oldestToNewest {
        didSet { applySorting() }
    }
    @Published var filters: AssetsFilter = [.iCloudIncluded] {
        didSet { Task.detached { self.rebuildGroups() } }
    }

    private let photoLibrary: PhotoLibraryServiceProtocol
    private let hashing: ImageHashingServiceProtocol

    private var assets = [Asset]()
    private var groups = [AssetsGroup]()

    /// Real services by default; pass fakes conforming to the same protocols for previews/tests.
    init(photoLibrary: PhotoLibraryServiceProtocol = PhotoLibraryService(),
         hashing: ImageHashingServiceProtocol = ImageHashingService()) {
        self.photoLibrary = photoLibrary
        self.hashing = hashing
        Task.detached {
            await self.fetch()
        }
    }

    func fetch() async {
        guard await photoLibrary.requestAuthorization() == .authorized else { return }
        let libraryAssets = await photoLibrary.fetchLibraryAssets()
        assets = await processAssets(libraryAssets)
        rebuildGroups()
    }

    func rebuildGroups() {
        groups = groupAssets(assets, by: OSHashDistanceType(distanceThreshold), filters: filters).sorted()
        applySorting()
    }

    func deleteAsset(_ asset: Asset) async {
        do {
            try await photoLibrary.delete(asset.libraryAsset)
        } catch {
            print(error)
        }
        assets.removeAll { $0 == asset }
        rebuildGroups()
    }

    private func applySorting() {
        DispatchQueue.main.async {
            self.assetsGroups = self.sorting == .oldestToNewest ? self.groups : self.groups.reversed()
        }
    }

    private func processAssets(_ libraryAssets: Set<LibraryAsset>) async -> [Asset] {
        await withTaskGroup(of: (libraryAsset: LibraryAsset, pHash: OSHashType?).self) { group in
            for libraryAsset in libraryAssets {
                group.addTask { [hashing] in
                    (libraryAsset, try? await hashing.hash(for: libraryAsset))
                }
            }

            var assets: [Asset] = []

            for await task in group {
                guard let pHash = task.pHash else { continue }
                assets.append(Asset(libraryAsset: task.libraryAsset, pHash: pHash, photoLibrary: photoLibrary))
            }

            return assets
        }
    }

    private func groupAssets(_ assets: [Asset], by maxDistance: OSHashDistanceType, filters: AssetsFilter) -> [AssetsGroup] {
        assets
            .enumerated()
            .reduce([AssetsGroup]()) { groups, element in
                let asset = element.element
                let index = element.offset
                DispatchQueue.main.async {
                    self.progress = Double(index) / Double(assets.count)
                }

                guard Self.isIncluded(asset: asset.libraryAsset, filters: filters) else { return groups }
                var groups = groups
                if let nearest = groups.nearestGroup(to: asset.pHash, using: hashing), nearest.distance < maxDistance {
                    nearest.group.addAsset(asset)
                } else {
                    groups.append(AssetsGroup(asset: asset))
                }
                return groups
            }
            .filter { $0.assets.count > 1 }
    }

    private static func isIncluded(asset: LibraryAsset, filters: AssetsFilter) -> Bool {
        filters.contains(.iCloudIncluded) || asset.asset.sourceType != .typeCloudShared
    }
}

private extension Array where Element == AssetsGroup {

    func nearestGroup(to pHash: OSHashType, using hashing: ImageHashingServiceProtocol) -> (group: AssetsGroup, distance: OSHashDistanceType)? {
        let nearestElement = map { group in
            group.assets.first.map { hashing.distance($0.pHash, pHash) } ?? OSHashDistanceType.max
        }
        .enumerated()
        .min { $0.element < $1.element }
        guard let element = nearestElement else { return nil }
        return (self[element.offset], element.element)
    }
}
