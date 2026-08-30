//
//  AssetPreview.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

/// A single grid cell. Owns the `Asset` model directly (which loads its own thumbnail via its
/// injected `PhotoLibraryServiceProtocol`), so it only needs a delete callback from its parent.
struct AssetPreview: View {
    @StateObject var assetInfo: Asset
    var onAssetDelete: () -> Void

    private static let previewDimension = 100.0

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
        .onAppear {
            assetInfo.requestThumbnail(CGSize(width: 200.0, height: 200.0))
        }
    }
}
