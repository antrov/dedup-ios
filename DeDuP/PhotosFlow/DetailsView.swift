//
//  DetailsView.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

struct DetailsView: View {
    private static let itemsSpacing = 30.0
    let assetsGroup: AssetsGroup

    var body: some View {
        NavigationStack {
            GeometryReader { geo in
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack {
                        ForEach(assetsGroup.comparedAssets(), id: \.0.id) { (asset, meta) in
                            VStack {
                                //                            AsyncThumbnail(thumbnail: asset.thumbnail)
                                Image(uiImage: asset.thumbnail!)
                                    .resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width - Self.itemsSpacing * 2, height: geo.size.height / 2.0)
                                    .clipped()
                                    .cornerRadius(5)
                                //                    MetaField(meta.identifier)

//                                List {
//                                    Section {
                                        MetaField(field: meta.creationDate)
                                        MetaField(field: meta.modificationDate)
                                        MetaField(field: meta.typeName)
                                        MetaField(field: meta.subtypesName)
                                        MetaField(field: meta.dimensions)
                                        MetaField(field: meta.album)
                                        MetaField(field: meta.hasAdjustments)
//                                    }
//                                }
                                Spacer()
                            }
                            .background {
                                Color.blue.frame(maxWidth: .infinity)
                            }
                            .listStyle(.plain)
                            .frame(width: geo.size.width - Self.itemsSpacing * 2)
                            .clipped()
                        }
                    }
                    .scrollTargetLayout()

                }
                .frame(maxHeight: .infinity)
                .scrollTargetBehavior(.viewAligned)
                .safeAreaPadding(Self.itemsSpacing)
            }
            .toolbar {
                ToolbarItemGroup(placement: .bottomBar) {
                    Button {
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }

                    Button(action: {
                    }) {
                        Image(systemName: "trash")
                    }
                }
            }
        }
    }
}

#Preview {
    DetailsView(assetsGroup: .mock)
}
