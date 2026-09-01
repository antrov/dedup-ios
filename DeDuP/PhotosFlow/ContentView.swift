//
//  ContentView.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel: PhotosViewModel
    @State private var showingFilters = true
    @State private var selectedGroup: AssetsGroup?
    @State private var detentHeight: CGFloat = 0

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    init(viewModel: PhotosViewModel = PhotosViewModel()) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            List(viewModel.assetsGroups) { assetsGroup in
                Section(header: header(for: assetsGroup)) {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(assetsGroup.assets) { asset in
                            AssetPreview(assetInfo: asset) {
                                Task {
                                    await viewModel.deleteAsset(asset)
                                }
                            }
                        }
                    }
                }
                .buttonStyle(PlainButtonStyle())
            }
            .navigationTitle("DeDuP")
            .toolbar { toolbarContent }
            .refreshable {
                Task {
                    await viewModel.fetch()
                }
            }
        }
        .sheet(isPresented: $showingFilters) {
            FiltersView(
                distanceThreshold: $viewModel.distanceThreshold,
                iCloudIncluded: iCloudIncludedBinding,
                progress: viewModel.progress,
                cloudOnlyCount: viewModel.processingCounts.cloudOnly,
                onThresholdCommitted: {
                    Task {
                        await viewModel.rebuildGroups()
                    }
                },
                onFetchCloudOnlyRequested: {
                    Task {
                        await viewModel.retryCloudOnlyAssets()
                    }
                }
            )
            .presentationDragIndicator(.visible)
            .readHeight()
            .onPreferenceChange(HeightPreferenceKey.self) { height in
                if let height {
                    detentHeight = height
                }
            }
            .presentationDetents([.height(detentHeight)])
        }
        .sheet(item: $selectedGroup) { group in
            DetailsView(assetsGroup: group)
        }
    }

    private func header(for assetsGroup: AssetsGroup) -> some View {
        HStack {
            Text("\(assetsGroup.creationDate?.formatted ?? "Unknown")")
            Spacer()
            Button {
                selectedGroup = assetsGroup
            } label: {
                Image(systemName: "info.circle")
                    .resizable()
                    .scaledToFit()
                    .frame(width: 12, height: 12)
                    .foregroundColor(.secondary)
            }
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigationBarTrailing) {
            Button {
                viewModel.sorting.toggle()
            } label: {
                Image(systemName: "arrow.up.arrow.down")
                    .symbolRenderingMode(.palette)
                    .foregroundStyle(
                        viewModel.sorting == .newestToOldest ? .primary : .secondary,
                        viewModel.sorting == .newestToOldest ? .secondary : .primary
                    )
            }

            Button {
                showingFilters.toggle()
            } label: {
                Image(systemName: "gear")
            }
        }
    }

    /// Narrows `viewModel.filters` (an OptionSet) down to a plain Bool binding for FiltersView.
    private var iCloudIncludedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.filters.contains(.iCloudIncluded) },
            set: { newValue in
                if newValue {
                    viewModel.filters.insert(.iCloudIncluded)
                } else {
                    viewModel.filters.remove(.iCloudIncluded)
                }
            }
        )
    }
}

#Preview("With mocked data") {
    ContentView(viewModel: PhotosViewModel(
        photoLibrary: PhotoLibraryServiceMock(),
        hashing: ImageHashingServiceMock(),
        hashStore: HashStoreMock()
    ))
}
