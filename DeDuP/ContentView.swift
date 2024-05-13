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

//#Preview("AsyncThumbnail") {
//    VStack {
//        AsyncThumbnail(thumbnail: nil)
//            .frame(width: 100, height: 100)
//        AsyncThumbnail(thumbnail: UIImage(named: "StockPhoto"))
//            .frame(width: 100, height: 100)
//    }
//}

struct ThumbnailToolbar: View {
    var isCloudAlbum: Bool
    var onDelete: (() -> ())
    
    var body: some View {
        HStack {
            if isCloudAlbum {
                Image(systemName: "cloud")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .padding(6)
                    .foregroundColor(.white)
                    .shadow(radius: 1)
            }
            Spacer()
            Button(action: onDelete) {
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
        }.padding(3)
    }
}

//#Preview("ThumbnailToolbar") {
//    ZStack {
//        Color(.gray)
//        ZStack(alignment: .top) {
//            Color(.yellow)
//            ThumbnailToolbar(isCloudAlbum: true, onDelete: {})
//        }
//        .frame(width: 100, height: 100)
//    }
//}

struct AssetPreview: View {
    @StateObject var assetInfo: Asset
    var onAssetDelete: (() -> ())
    
    private static let previewDimension = 100.0
    private static let previewSize = CGSize(width: previewDimension, height: previewDimension)
    
    var body: some View {
        VStack {
            ZStack(alignment: .top) {
                AsyncThumbnail(thumbnail: assetInfo.thumbnail)
                ThumbnailToolbar(isCloudAlbum: assetInfo.isCloud, onDelete: onAssetDelete)
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

//#Preview("AssetPreview") {
//    ZStack {
//        Color(.gray)
//        AssetPreview(assetInfo: .preview)
//    }
//}

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
                    BadgeView(number: assetsGroup.assets.count)
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
                Text("Hello")
                ProgressView("Progress", value: $photosProvider.progress.wrappedValue)
                Slider(value: $photosProvider.distanceThreshold, in: 0...30, step: 1) { editing in
                    guard !editing else { return }
                    Task { await self.photosProvider.rebuildGroups() }
                }
            }
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
    }
}

//struct BottomView: View {
//    var body: some View {
//        VStack {
//            Text("Hello")
//            Slider(value: $photosProvider.distanceThreshold, in: 0...30, step: 1)
//        }
//        .padding(.top)
//    }
//}

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
        self
            .modifier(ReadHeightModifier())
    }
}
