//
//  ContentView.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

struct BadgeView: View {
    var number: Int
    var backgroundColor: Color = .gray
    var textColor: Color = .white
    var fontSize: CGFloat = 10
    var body: some View {
        Text("\(number)")
            .font(.system(size: fontSize))
            .foregroundColor(textColor)
            .padding(8)  // Padding to create the circular shape around the number
            .background(backgroundColor)
            .clipShape(Circle())  // This makes the background a circle
    }
}

struct AsyncThumbnail: View {
    var thumbnail: UIImage?
    
    var body: some View {
        Group {
            if let thumbnail = self.thumbnail {
                Image(uiImage: thumbnail)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 100, height: 100)
                
            } else {
                Rectangle()
                    .fill(Color.gray)
            }
        }
        .clipped()
        .cornerRadius(5)
    }
}

struct AssetPreview: View {
    @StateObject var assetInfo: Asset
    var onAssetDelete: (() -> ())
    
    private static let previewDimension = 100.0
    private static let previewSize = CGSize(width: previewDimension, height: previewDimension)
    
    var body: some View {
        VStack {
            ZStack(alignment: .topTrailing) {
                AsyncThumbnail(thumbnail: assetInfo.thumbnail)
                Button(action: onAssetDelete) {
                    Image(systemName: "trash")  // Using SF Symbols for the trash icon
                        .resizable()
                        .scaledToFit()
                        .frame(width: 12, height: 12)  // Set the icon size smaller
                        .foregroundColor(.black)  // Set the icon color to black
                        .padding(6)  // Padding around the icon to increase the button's touch area
                        .background(Color.white)  // Set the background color of the button to white
                        .clipShape(RoundedRectangle(cornerRadius: 3))  // Make the background rounded
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

extension ClosedRange<Date> {
    
    var formatted: String {
        let lowerFormatted = lowerBound.formatted(.iso8601)
        guard lowerBound != upperBound else { return lowerFormatted }
        return "\(lowerFormatted) - \(upperBound.formatted(.iso8601))"
    }
    
}

struct ContentView: View {
    @ObservedObject var photosProvider = PhotosProviderImpl()
    @State private var showingFilters = true
    @State private var detailsGroups: AssetsGroup?
    @State var detentHeight: CGFloat = 0
    
    let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]
    
    var body: some View {
        NavigationView {
            List(photosProvider.assetsGroups) { assetsGroup in
                Section(header: HStack {
                    Text("\(assetsGroup.creationDate?.formatted ?? "Unknown")")
                    Spacer()
                    Button(action: {
                        detailsGroups = assetsGroup
                    }) {
                        Image(systemName: "info.circle")  // Using SF Symbols for the trash icon
                            .resizable()
                            .scaledToFit()
                            .frame(width: 12, height: 12)
                            .foregroundColor(.secondary)
                    }
                }) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(assetsGroup.assets) { asset in
                            AssetPreview(assetInfo: asset) {
                                Task {
                                    await photosProvider.deleteAsset(asset)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
                
            }
            .navigationTitle("DeDuP")
            .toolbar {
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        photosProvider.sorting.toggle()
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(
                                photosProvider.sorting == .newestToOldest ? .primary : .secondary,
                                photosProvider.sorting == .newestToOldest ? .secondary : .primary
                            )
                    }

                    Button(action: {
                        showingFilters.toggle()
                    }) {
                        Image(systemName: "gear")
                    }
                }
            }
            .refreshable {
                Task {
                    await photosProvider.fetch()
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            VStack {
                ProgressView("Progress", value: $photosProvider.progress.wrappedValue)
                Slider(value: $photosProvider.distanceThreshold, in: 0...30, step: 1) { editing in
                    guard !editing else { return }
                    self.photosProvider.rebuildGroups()
                }
                Toggle(isOn: Binding<Bool>(
                    get: {
                        photosProvider.filters.contains(.iCloudIncluded)
                    }, set: { newValue in
                        if newValue {
                            photosProvider.filters.insert(.iCloudIncluded)
                        } else {
                            photosProvider.filters.remove(.iCloudIncluded)
                        }
                    }
                )) { Text("Include iCloud Shared Albums") }
            }
            .contentMargins(8)
            .padding(.top)
            .presentationDragIndicator(.visible)
                .readHeight()
                .onPreferenceChange(HeightPreferenceKey.self) { height in
                    if let height {
                        self.detentHeight = height
                    }
                }
                .presentationDetents([.height(self.detentHeight)])
        }
        .sheet(item: $detailsGroups) { group in
            DetailsView(assetsGroup: group)
        }
    }
}

struct HeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat?

    static func reduce(value: inout CGFloat?, nextValue: () -> CGFloat?) {
        guard let nextValue = nextValue() else { return }
        value = nextValue
    }
}

private struct ReadHeightModifier: ViewModifier {
    private var sizeView: some View {
        GeometryReader { geometry in
            Color.clear.preference(key: HeightPreferenceKey.self, value: geometry.size.height)
        }
    }

    func body(content: Content) -> some View {
        content.background(sizeView)
    }
}

extension View {
    func readHeight() -> some View {
        modifier(ReadHeightModifier())
    }
}

struct MetaField<T: Equatable>: View {
    let field: Field<T>
    
    private func format(_ value: T) -> String? {
        switch value {
        case is Date: return (value as! Date).formatted(.dateTime.year().month().day().hour().minute().second().secondFraction(.milliseconds(3)).timeZone())
        case is CustomStringConvertible: return (value as! CustomStringConvertible).description
        default: return value as? String
        }
    }
    
    var body: some View {
        Group {
            if case let .some(value) = field.value as Optional<T> {
                Text(format(value) ?? "Unable to format")
            } else {
                Text("empty")
                    .foregroundStyle(.gray.opacity(0.3))
            }
        }
//        .background(field.difference == DifferenceResult.different ? Color.red : Color.clear)
    }
}

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
