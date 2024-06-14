//
//  DuplicatesProvider.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import Foundation
import Photos

import Foundation
import Photos
import CoreLocation
import UIKit
import CryptoKit
import CocoaImageHashing

class AssetsGroup: Equatable, Comparable, Identifiable {
    
    let id: UUID
    var assets: [Asset]
    var creationDate: ClosedRange<Date>?
    
    init(asset: Asset) {
        self.assets = [asset]
        self.id = UUID()
        self.creationDate = creationDateOfAssets()
    }
    
    init(assets: [Asset]) {
        self.assets = assets
        self.id = UUID()
        self.creationDate = creationDateOfAssets()
    }
    
    func addAsset(_ asset: Asset) {
        self.assets.append(asset)
        self.creationDate = creationDateOfAssets()
    }
    
    private func creationDateOfAssets() -> ClosedRange<Date>? {
        let dates = assets.compactMap(\.creationDate)
        guard let minDate = dates.min(), let maxDate = dates.max() else { return nil }
        return minDate...maxDate
    }
    
    func maxDistance(to pHash: OSHashType) -> OSHashDistanceType? {
        return assets
            .first
            .map { asset in
//            .compactMap { asset in
                OSImageHashing.sharedInstance().hashDistance(asset.pHash, to: pHash, with: .pHash)
            }
//            .max()
    }
    
    static func < (lhs: AssetsGroup, rhs: AssetsGroup) -> Bool {
        guard let ldate = lhs.creationDate, let rdate = rhs.creationDate else { return lhs.id < rhs.id }
        return ldate.lowerBound < rdate.lowerBound
    }
    
    static func == (lhs: AssetsGroup, rhs: AssetsGroup) -> Bool {
        return lhs.id == rhs.id
    }
    
    func comparedAssets() -> [(Asset, Meta)] {
        return Array(
            zip(
                assets,
                assets.map(\.meta).compared()
            )
        )
    }
}

extension Array where Element == AssetsGroup {
    
    func nearestGroup(to pHash: OSHashType) -> (group: AssetsGroup, distance: OSHashDistanceType)? {
        let nearestElement = map { assetsGroup in
            assetsGroup.maxDistance(to: pHash) ?? OSHashType.max
        }
        .enumerated()
        .min { lhs, rhs in
            lhs.element < rhs.element
        }
        guard let element = nearestElement else { return nil }
        return (self[element.offset], element.element)
    }
    
}

struct AssetHashFactory {
    private static let requestOptions = {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        // Does not work with timeout
        // But it completes with low quality preview. Has to do something with completion or filtering lowe quality result
//        options.isSynchronous = true
        return options
    }()
    
    private static let emptyDataError = NSError(domain: "photokit.data.empty", code: -1)
    private static let unsupportedMediaError = NSError(domain: "photokit.media.unsupported", code: -2)
    private static let timeoutError = NSError(domain: "photokit.data.timout", code: -3)
    
    private static let ph = PHCachingImageManager()
    private static let timeout = DispatchTimeInterval.seconds(5)
    private static let imageSize = CGSizeMake(50, 50)
    
    func calculateHash(for asset: PHAsset) async throws -> OSHashType {
        return try await withCheckedThrowingContinuation { continuation in
            guard asset.mediaType == .image else { print("unsupportedMediaError"); continuation.resume(throwing: Self.unsupportedMediaError); return }
            var timeouted = false
            let timeoutTask = DispatchWorkItem {
                print("Timeout")
                timeouted = true
                continuation.resume(throwing: Self.timeoutError)
            }
            
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timeoutTask)
            
            Self.ph.requestImage(for: asset, targetSize: Self.imageSize, contentMode: .aspectFit, options: Self.requestOptions) { image, info in
                guard !timeouted else { return }
                guard info?[PHImageResultIsDegradedKey] as? NSNumber != 1 else { return }
                
                timeoutTask.cancel()
        
                if let error = info?[PHImageErrorKey] as? NSError {
                    print("Failed to obtain asset data: \(error)")
                    continuation.resume(throwing: error)
                } else if let image = image, let data = image.pngData() {
                    print("Received image data")
                    continuation.resume(returning: OSImageHashing.sharedInstance().hashImageData(data, with: .pHash))
                } else {
                    print("Obtained asset data is empty")
                    continuation.resume(throwing: Self.emptyDataError)
                }
            }
        }
    }
}

struct LibraryAsset: Hashable, CustomStringConvertible {
    let asset: PHAsset
    let collection: PHAssetCollection?
    let idx: Int
    
    var description: String {
        return [asset.creationDate?.formatted(), collection?.localizedTitle].compactMap { $0 }.joined(separator: " - ")
    }
    
    func hash(into hasher: inout Hasher) {
        hasher.combine(asset.localIdentifier)
    }
    
    static func == (lhs: LibraryAsset, rhs: LibraryAsset) -> Bool {
        return lhs.asset.localIdentifier == rhs.asset.localIdentifier
    }
}


class Asset: Equatable, ObservableObject, Identifiable {
    
    @Published var thumbnail: UIImage?
    
    let pHash: Int64
    
    var id: String {
        return libraryAsset.asset.localIdentifier
    }
    var collectionName: String? {
        return libraryAsset.collection?.localizedTitle
    }
    var creationDate: Date? {
        return libraryAsset.asset.creationDate
    }
    lazy var meta = Meta.create(from: libraryAsset.asset, collection: libraryAsset.collection)
    
    fileprivate let libraryAsset: LibraryAsset
    
    init(asset: LibraryAsset, pHash: Int64) {
        self.libraryAsset = asset
        self.pHash = pHash
    }
    
    func requestThumbnail(_ size: CGSize) {
        PHCachingImageManager().requestImage(for: libraryAsset.asset, targetSize: size, contentMode: .aspectFill, options: nil) { [weak self] image, _ in
            DispatchQueue.main.async {
                self?.thumbnail = image
            }
        }
    }
    
    static func == (lhs: Asset, rhs: Asset) -> Bool {
        return lhs.id == rhs.id
    }
}

protocol PhotosProvider: ObservableObject {
    
    var assetsGroups: [AssetsGroup] { get }
    var distanceThreshold: Double { get set }
    
}

extension PhotosProvider {
    static var mock: any PhotosProvider {
        PhotosProviderMock()
    }
}

class PhotosProviderMock: PhotosProvider {
    
    var assetsGroups: [AssetsGroup] = []
    var distanceThreshold: Double = 4.0
    
}

class PhotosProviderImpl: PhotosProvider {
    
    enum GroupsSorting {
        case newestToOldest
        case oldestToNewest
        
        mutating func toggle() {
            switch self {
            case .newestToOldest:
                self = .oldestToNewest
            case .oldestToNewest:
                self = .newestToOldest
            }
        }
    }
    
    struct AssetsFilter: OptionSet {
        let rawValue: UInt
        
        static let iCloudIncluded = AssetsFilter(rawValue: 1 << 0)
    }
    
    @Published var assetsGroups = [AssetsGroup]()
    @Published var distanceThreshold: Double = 4.0 {
            didSet {
                Task.detached {
//                    await self.rebuildGroups()
                }
            }
        }
    @Published var progress: Double = 0.0
    @Published var sorting = GroupsSorting.oldestToNewest {
        didSet {
            self.updateGroupsWothSorting()
        }
    }
    @Published var filters: AssetsFilter = [.iCloudIncluded] {
        didSet {
            Task.detached {
                self.rebuildGroups()
            }
        }
    }
    
    private var assets = [Asset]()
    private var groups = [AssetsGroup]()
    private let imageManager = PHCachingImageManager()
    private let thumbnailSize = CGSize(width: 100, height: 100)

    init() {
        Task.detached {
            await self.fetch()
        }
    }
    
    func requestPhotoLibraryAccess() async -> PHAuthorizationStatus {
        let currentStatus = PHPhotoLibrary.authorizationStatus()

        switch currentStatus {
        case .notDetermined:
            return await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization { newStatus in
                    continuation.resume(returning: newStatus)
                }
            }
        case .restricted, .denied, .authorized, .limited:
            return currentStatus
        @unknown default:
            return currentStatus
        }
    }
    
    func fetch() async {
        guard await requestPhotoLibraryAccess() == .authorized else { return }
        let libraryAssets = fetchLibraryAssets()
        assets = await processAssets(libraryAssets)
        rebuildGroups()
    }
    
    func rebuildGroups() {
        groups = groupAssets(assets, by: OSHashDistanceType(distanceThreshold), filters: filters).sorted()
        updateGroupsWothSorting()
    }
    
    func updateGroupsWothSorting() {
        DispatchQueue.main.async {
            self.assetsGroups = self.sorting == .oldestToNewest ? self.groups : self.groups.reversed()
        }
    }
    
    func deleteAsset(_ asset: Asset) async {
        let libraryAsset = asset.libraryAsset
        let requestedAssets = [libraryAsset.asset] as NSArray
        
        await withUnsafeContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                if let collection = libraryAsset.collection, let collectionRequest = PHAssetCollectionChangeRequest(for: collection) {
                    collectionRequest.removeAssets(requestedAssets)
                } else {
                    PHAssetChangeRequest.deleteAssets(requestedAssets)
                }
            } completionHandler: { _, error in
                if let error = error {
                    print(error)
                }
                continuation.resume()
            }
        }
        assets.removeAll { item in
            item == asset
        }
        rebuildGroups()
    }

     private func fetchLibraryAssets() -> Set<LibraryAsset> {
        var assets = Set<LibraryAsset>()
        let fetchOptions = PHFetchOptions()
        fetchOptions.includeAssetSourceTypes = [.typeUserLibrary, .typeiTunesSynced]
         var idx = 0
      
      var collections = [String]()

        PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumRegular, options: nil)
            .enumerateObjects { (collection, _, _) in
                collections.append(collection.localizedTitle ?? "unknown album title")
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    idx += 1
                    assets.insert(LibraryAsset(asset: asset, collection: collection, idx: idx))
                }
            }
        
        PHAssetCollection
            .fetchAssetCollections(with: .album, subtype: .albumCloudShared, options: nil)
            .enumerateObjects { (collection, _, _) in
//                guard collection.localizedTitle == "Test" else { return }
                collections.append(collection.localizedTitle ?? "unknown album title")
                PHAsset.fetchAssets(in: collection, options: nil).enumerateObjects { asset, _, _ in
                    guard asset.mediaType == .image else { return }
                    idx += 1
                    assets.insert(LibraryAsset(asset: asset, collection: collection, idx: idx))
                }
            }
         
         
         PHAsset.fetchAssets(with: .image, options: fetchOptions).enumerateObjects { asset, _, _ in
             idx += 1
             assets.insert(LibraryAsset(asset: asset, collection: nil, idx: idx))
         }
         
 //        PHAsset.fetchAssets(with: .video, options: fetchOptions).enumerateObjects { asset, _, _ in
 //            assets.insert(AssetInfo(asset: asset))
 //        }
 //
         print("------")
        print(collections)
         print("------")
         
         return assets
    }
    
    private func processAssets(_ libraryAssets: Set<LibraryAsset>) async -> [Asset] {
        let hashFactory = AssetHashFactory()
        
        return await withTaskGroup(of: (libraryAsset: LibraryAsset, pHash: OSHashType?).self) { group in
            for libraryAsset in libraryAssets {
                group.addTask {
                    (libraryAsset, try? await hashFactory.calculateHash(for: libraryAsset.asset))
                }
            }

            var assets: [Asset] = []
            
            for await task in group {
                guard let pHash = task.pHash else { print("Hash is empty for asset \(task.libraryAsset)"); continue }
                assets.append(Asset(asset: task.libraryAsset, pHash: pHash))
            }
            
            print("Got \(assets.count) assets from \(libraryAssets.count) library assets")
            
            return assets
        }
    }
    
    private func groupAssets(_ assets: [Asset], by maxDistance: OSHashDistanceType, filters: AssetsFilter) -> [AssetsGroup] {
        return assets
            .enumerated()
            .reduce([AssetsGroup]()) { groups, element in
                let asset = element.element
                let index = element.offset
                DispatchQueue.main.async {
                    self.progress = Double(index) / Double(assets.count)
                }
                
                guard Self.isIncluded(asset: asset.libraryAsset, filters: filters) else { return groups }
                var groups = groups
                if let nearest = groups.nearestGroup(to: asset.pHash), nearest.distance < maxDistance {
                    nearest.group.assets.append(asset)
                } else {
                    groups.append(AssetsGroup(asset: asset))
                }
                return groups
            }
            .filter { group in
                group.assets.count > 1
            }
    }
    
    private static func isIncluded(asset: LibraryAsset, filters: AssetsFilter) -> Bool {
        return filters.contains(.iCloudIncluded) || asset.asset.sourceType != .typeCloudShared
    }
}
