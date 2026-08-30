//
//  Meta.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 20/05/2024.
//

import Foundation
import Photos

enum DifferenceResult: CaseIterable {
    case notCompared
    case equal
    case different
}

struct Field<T: Equatable>: Equatable, CustomStringConvertible {
    let value: T
    let difference: DifferenceResult

    static func == (lhs: Field<T>, rhs: Field<T>) -> Bool {
        guard let ld = lhs.value as? Date, let rd = rhs.value as? Date else { return lhs.value == rhs.value }
        return abs(ld.timeIntervalSince(rd)) < 1.0
    }

    var description: String {
        return "\(value) \(difference == .different ? " !" : "")"
    }
}

private extension Array {
    func areEqual<T>() -> Bool where Element == Field<T> {
        guard let lhs = first else { return false }
        return reduce(true) { partialResult, rhs in
            partialResult && lhs == rhs
        }
    }

    func compared<T>() -> [Element] where Element == Field<T> {
        let difference: DifferenceResult = areEqual() ? .equal : .different
        return map { field in
            Field(value: field.value, difference: difference)
        }
    }
}

struct Meta {
    let identifier: String
    let dimensions: Field<String>
    let creationDate: Field<Date?>
    let modificationDate: Field<Date?>
    let typeName: Field<String>
    let subtypesName: Field<String>
    let album: Field<AlbumType>
    let hasAdjustments: Field<Bool>

    static func create(from asset: PHAsset, collection: PHAssetCollection?) -> Meta {
        let collectionName = collection?.localizedTitle ?? "Unknown"
        let albumType = AlbumType.create(sourceType: asset.sourceType, name: collectionName) ?? .userLibrary(collectionName)
        return Meta(
            identifier: asset.localIdentifier,
            dimensions: Field(value: "\(asset.pixelWidth) x \(asset.pixelHeight)", difference: .notCompared),
            creationDate: Field(value: asset.creationDate, difference: .notCompared),
            modificationDate: Field(value: asset.modificationDate, difference: .notCompared),
            typeName: Field(value: asset.mediaType.name, difference: .notCompared),
            subtypesName: Field(value: asset.mediaSubtypes.names.joined(separator: ", "), difference: .notCompared),
            album: Field(value: albumType, difference: .notCompared),
            hasAdjustments: Field(value: asset.hasAdjustments, difference: .notCompared)
        )
    }
}

extension Array where Element == Meta {
    func compared() -> [Meta] {
        let dimensions = map(\.dimensions).compared()
        let creationDates = map(\.creationDate).compared()
        let modificationDates = map(\.modificationDate).compared()
        let typeNames = map(\.typeName).compared()
        let subtypesNames = map(\.subtypesName).compared()
        let albums = map(\.album).compared()
        let hasAdjustments = map(\.hasAdjustments).compared()

        return enumerated().map { index, meta in
            Meta(
                identifier: meta.identifier,
                dimensions: dimensions[index],
                creationDate: creationDates[index],
                modificationDate: modificationDates[index],
                typeName: typeNames[index],
                subtypesName: subtypesNames[index],
                album: albums[index],
                hasAdjustments: hasAdjustments[index]
            )
        }
    }
}

enum AlbumType: Equatable, CustomStringConvertible {
    case cloudShared(String)
    case userLibrary(String?)
    case iTunesSynced(String)

    var albumName: String? {
        switch self {
        case let .cloudShared(name): return name
        case let .userLibrary(name): return name
        case let .iTunesSynced(name): return name
        }
    }

    fileprivate static func create(sourceType: PHAssetSourceType, name: String?) -> AlbumType? {
        switch sourceType {
        case .typeCloudShared:
            guard let name = name else { fallthrough }
            return .cloudShared(name)

        case .typeUserLibrary:
            return .userLibrary(name)

        case .typeiTunesSynced:
            guard let name = name else { fallthrough }
            return .iTunesSynced(name)

        default:
            return nil
        }
    }

    var description: String {
        switch self {
        case let .cloudShared(name): return "cloudShared \(name)"
        case let .userLibrary(name): return "userLibrary \(name ?? "")"
        case let .iTunesSynced(name): return "iTunesSync \(name)"
        }
    }
}

private extension PHAssetMediaType {
    var name: String {
        switch self {
        case .image: return "image"
        case .audio: return "audio"
        case .video: return "video"
        case .unknown: fallthrough
        @unknown default:
            return "unknown"
        }
    }
}

private extension PHAssetMediaSubtype {
    var names: [String] {
        var subtypes: [String] = []

        if contains(.photoPanorama) {
            subtypes.append("Photo Panorama")
        }
        if contains(.photoHDR) {
            subtypes.append("Photo HDR")
        }
        if #available(iOS 9.0, *), contains(.photoScreenshot) {
            subtypes.append("Photo Screenshot")
        }
        if #available(iOS 9.1, *), contains(.photoLive) {
            subtypes.append("Photo Live")
        }
        if #available(iOS 10.2, *), contains(.photoDepthEffect) {
            subtypes.append("Photo Depth Effect")
        }
        if contains(.videoStreamed) {
            subtypes.append("Video Streamed")
        }
        if contains(.videoHighFrameRate) {
            subtypes.append("Video High Frame Rate")
        }
        if contains(.videoTimelapse) {
            subtypes.append("Video Timelapse")
        }
        if #available(iOS 15.0, *), contains(.videoCinematic) {
            subtypes.append("Video Cinematic")
        }
        if subtypes.isEmpty {
            subtypes.append("None")
        }

        return subtypes
    }
}
