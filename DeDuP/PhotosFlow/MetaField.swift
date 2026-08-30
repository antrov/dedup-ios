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
        case let date as Date: return date
            .formatted(.dateTime.year().month().day().hour().minute().second().secondFraction(.milliseconds(3)).timeZone())
        case let describable as CustomStringConvertible: return describable.description
        default: return value as? String
        }
    }

    var body: some View {
        if case let .some(value) = field.value as T? {
            Text(format(value) ?? "Unable to format")
        } else {
            Text("empty")
                .foregroundStyle(.gray.opacity(0.3))
        }
//        .background(field.difference == DifferenceResult.different ? Color.red : Color.clear)
    }
}
