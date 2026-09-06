//
//  PreviewData.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 22/05/2024.
//

import Photos
import UIKit

private extension Field {
    static func mock(of values: [T]) -> Field<T> {
        return Field(
            value: values.randomElement() ?? values[0],
            difference: DifferenceResult.allCases.randomElement() ?? .notCompared
        )
    }
}

class AssetMock: Asset {
    override var id: String {
        return UUID().uuidString
    }

    override var collectionName: String? {
        return ["Family Photos", "Dog", "Vacations", "Undercover"].randomElement()
    }

    override var creationDate: Date? {
        return Date(timeIntervalSinceReferenceDate: TimeInterval.random(in: 0 ... Date.timeIntervalSinceReferenceDate))
    }

    override var meta: Meta {
        get { Meta(
            identifier: UUID().uuidString,
            dimensions: .mock(of: ["1024 x 768", "1920 x 1080"]),
            creationDate: .mock(of: [.distantFuture, .distantPast]),
            modificationDate: .mock(of: [.distantFuture, .distantPast]),
            typeName: .mock(of: ["image", "video"]),
            subtypesName: .mock(of: ["panorama", "photo depth"]),
            album: .mock(of: [.cloudShared("Shared"), .userLibrary("Local")]),
            hasAdjustments: .mock(of: [true, false])
        )
        }
        set { /* nop */ }
    }

    init() {
        super.init(
            libraryAsset: LibraryAsset(asset: PHAsset(), collections: []),
            pHash: 0,
            photoLibrary: PhotoLibraryServiceMock()
        )
        thumbnail = UIImage(named: "StockPhoto\(Int.random(in: 1 ... 5))")
    }
}

extension AssetsGroup {
    static let mock: AssetsGroup = .init(assets: (0 ... Int.random(in: 2 ... 5)).map { _ in AssetMock() })
}
