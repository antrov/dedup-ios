//
//  AssetPreview.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

/// A single grid cell. Observes — never owns — the `Asset` model handed down by its parent
/// (W-42): `@StateObject` latches onto the first instance it is given and ignores every later
/// one, so after a re-group a reused cell would keep showing the photo from the previous
/// layout (B-15). It only needs a delete callback on top of the model.
struct AssetPreview: View {
    @ObservedObject var assetInfo: Asset
    var onAssetDelete: () -> Void

    private static let previewDimension = 100.0
    private static let thumbnailSize = CGSize(width: 200.0, height: 200.0)

    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                AsyncThumbnail(thumbnail: assetInfo.thumbnail)
                Button(action: onAssetDelete) {
                    Image(systemName: "trash") // Using SF Symbols for the trash icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12) // Set the icon size smaller
                        .foregroundColor(.black) // Set the icon color to black
                        .padding(6) // Padding around the icon to increase the button's touch area
                        .background(Color.white) // Set the background color of the button to white
                        .clipShape(RoundedRectangle(cornerRadius: 3)) // Make the background rounded
                        .shadow(radius: 1)
                }
                .padding(3)
            }
            .frame(width: Self.previewDimension, height: Self.previewDimension)
            Text(assetInfo.collectionName ?? "No Album")
                .font(.caption)
        }
        // Keyed on the asset's identity so a recycled cell loads the photo it now represents,
        // and cancelled by SwiftUI when the cell scrolls away (W-42) — unlike `onAppear`, which
        // fired a fresh, uncancellable request every time the cell came back into view.
        .task(id: assetInfo.id) {
            await assetInfo.loadThumbnail(size: Self.thumbnailSize)
        }
    }
}
