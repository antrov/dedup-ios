//
//  MetaField.swift
//  DeDuP
//
//  Created by Hubert Andrzejewski on 20/05/2024.
//

import SwiftUI

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
