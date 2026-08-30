//
//  AsyncThumbnail.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 09/05/2024.
//

import SwiftUI

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
