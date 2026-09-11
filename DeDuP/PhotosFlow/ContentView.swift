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
    @State private var selectedGroupID: AssetsGroup.ID?
    @State private var detentHeight: CGFloat = 0

    private let columns = [
        GridItem(.flexible()),
        GridItem(.flexible()),
        GridItem(.flexible())
    ]

    /// The view model is injected rather than defaulted: a default argument is evaluated in the
    /// caller's context, which for a `View` initializer isn't the main actor, and the model is
    /// bound to it (W-37).
    @MainActor
    init(viewModel: PhotosViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        NavigationStack {
            List(viewModel.state.groups) { assetsGroup in
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
            // The placeholder covers the list, so it must not swallow the pull-to-refresh
            // gesture aimed at what's underneath (W-41). Only the failure placeholder has
            // anything to tap.
            .overlay { placeholder.allowsHitTesting(isShowingFailure) }
            // `placeholder` only ever shows while the list has nothing in it yet (W-38, B-14) —
            // once a previous scan has found duplicates, that list stays on screen through every
            // later scan, and with it the *only* place the current step showed. This banner is
            // the other half: visible exactly when the centered placeholder isn't, so a returning
            // user — the common case once the app has run once — can still see which element of
            // the library (W-57) or pipeline phase a scan is currently working through, without
            // the list being blanked out from under them.
            .safeAreaInset(edge: .top) { scanStatusBanner }
            .navigationTitle("DeDuP")
            .toolbar { toolbarContent }
            // Awaits the scan itself, so the refresh indicator stays up until the work is
            // actually done instead of vanishing the moment the gesture ends (W-41, B-13). A
            // manual pull always asks for the exhaustive walk (W-56): the one user-reachable way
            // to force a from-scratch answer if the incremental one the app uses on its own is
            // ever wrong.
            .refreshable {
                await viewModel.fetch(forceFullScan: true)
            }
            // Scanning is driven by the view's lifecycle, not by the view model's initializer
            // (W-40): it starts when the screen appears and is cancelled when it goes away, so
            // previews and tests never trigger a scan just by creating the model.
            .task {
                await viewModel.fetch()
            }
        }
        .sheet(isPresented: $showingFilters) {
            FiltersView(
                distanceThreshold: $viewModel.distanceThreshold,
                iCloudIncluded: iCloudIncludedBinding,
                status: status,
                counts: viewModel.processingCounts,
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
        .sheet(item: selectedGroupBinding) { group in
            DetailsView(assetsGroup: group)
        }
    }

    /// Resolves the open details sheet against the *current* result instead of holding on to the
    /// group instance that was tapped (B-14): after a re-group the sheet shows that group's new
    /// members, and closes by itself if the group no longer exists.
    private var selectedGroupBinding: Binding<AssetsGroup?> {
        Binding(
            get: { viewModel.state.groups.first { $0.id == selectedGroupID } },
            set: { selectedGroupID = $0?.id }
        )
    }

    /// Turns the view model's phase into a label and progress, in one place so the filters sheet
    /// and the empty-list placeholder can't disagree about what the app is doing (W-38).
    private var status: FiltersView.Status? {
        switch viewModel.state.phase {
        case .requestingAuthorization:
            return .init(label: "Requesting access to photos", detail: nil, fraction: nil)
        case let .scanningLibrary(step, progress):
            // Bar only, no counts: the library walk visits a photo once per album it's in, so
            // its totals measure enumeration work rather than photos. The label names which
            // element of the library this is (W-57): shared albums are always walked in full, on
            // every scan, so — unlike the local-photos step — this can take a while even when the
            // rest of the scan is otherwise instant, and it's worth saying so rather than leaving
            // "scanning" looking stuck.
            return .init(label: Self.scanningLabel(for: step), detail: nil, fraction: progress.fraction)
        case let .hashingImages(progress):
            return .init(label: "Analysing photos", detail: Self.detail(for: progress), fraction: progress.fraction)
        case .grouping:
            return .init(label: "Grouping duplicates", detail: nil, fraction: nil)
        case nil:
            return nil
        }
    }

    private var isShowingFailure: Bool {
        if case .failed = viewModel.state {
            return true
        }
        return false
    }

    private static func detail(for progress: PhaseProgress) -> String? {
        guard progress.total > 0 else { return nil }
        return "\(progress.completed.formatted()) / \(progress.total.formatted())"
    }

    private static func scanningLabel(for step: LibraryScanStep) -> String {
        switch step {
        case .localPhotos: return "Scanning your photos"
        case .sharedAlbums: return "Scanning shared albums"
        }
    }

    /// What replaces the list when there is nothing to list. This is the whole point of the
    /// explicit state (W-38): work in progress, a refused permission, a failure and a genuinely
    /// duplicate-free library used to look identical — an empty list.
    @ViewBuilder
    private var placeholder: some View {
        if !viewModel.state.groups.isEmpty {
            EmptyView()
        } else {
            switch viewModel.state {
            case .idle:
                ProgressView()
            case .authorizationDenied:
                ContentUnavailableView {
                    Label("No access to photos", systemImage: "lock")
                } description: {
                    Text("DeDuP needs permission to read your photo library. You can grant it in Settings.")
                }
            case .working:
                workingPlaceholder
            case .ready:
                ContentUnavailableView {
                    Label("No duplicates found", systemImage: "checkmark.circle")
                } description: {
                    Text("Nothing in your library is within \(viewModel.distanceThreshold) bits of anything else.")
                }
            case let .failed(message, _):
                ContentUnavailableView {
                    Label("Scan failed", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(message)
                } actions: {
                    Button("Try again") {
                        Task { await viewModel.fetch(forceFullScan: true) }
                    }
                }
            }
        }
    }

    private var workingPlaceholder: some View {
        VStack(spacing: 8) {
            ProgressView()
            if let status {
                Text(status.label)
                    .font(.headline)
                if let detail = status.detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    /// The other half of `status`'s two audiences (W-57): shown only once the list already has
    /// something in it, which is exactly when `workingPlaceholder` — the centered spinner — is
    /// not, since that one only appears over an empty list (W-38). `EmptyView()` collapses to no
    /// inset at all, so this costs nothing on screen the rest of the time.
    @ViewBuilder
    private var scanStatusBanner: some View {
        if let status, !viewModel.state.groups.isEmpty {
            HStack(spacing: 8) {
                if let fraction = status.fraction {
                    ProgressView(value: fraction)
                        .frame(width: 28)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(status.label)
                        .font(.footnote)
                    if let detail = status.detail {
                        Text(detail)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal)
            .padding(.vertical, 6)
            .background(.bar)
        } else {
            EmptyView()
        }
    }

    private func header(for assetsGroup: AssetsGroup) -> some View {
        HStack {
            Text("\(assetsGroup.creationDate?.formatted ?? "Unknown")")
            Spacer()
            Button {
                selectedGroupID = assetsGroup.id
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
