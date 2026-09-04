//
//  DeDuPApp.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

@main
struct DeDuPApp: App {
    @StateObject private var viewModel = PhotosViewModel()

    var body: some Scene {
        WindowGroup {
            ContentView(viewModel: viewModel)
        }
    }
}
