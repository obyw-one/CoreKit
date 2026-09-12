//
//  View+Extensions.swift
//  CoreKit
//
//  Extracted from WabiSabi — Created by Jeoffrey Thirot on 03/10/2022.
//

import SwiftUI

// From: https://www.avanderlee.com/swiftui/conditional-view-modifier/
public extension View {
    /// Applies the given transform if the given condition evaluates to `true`.
    /// - Parameters:
    ///   - condition: The condition to evaluate.
    ///   - transform: The transform to apply to the source `View`.
    /// - Returns: Either the original `View` or the modified `View` if the condition is `true`.
    @ViewBuilder func `if`(_ condition: Bool, transform: (Self) -> some View) -> some View {
        if condition {
            transform(self)
        } else {
            self
        }
    }

    /// Applies the given block.
    /// ```
    /// Button("Action") {
    ///     print("Plop")
    /// }
    /// .apply {
    ///     if #available(iOS 26.0, *) {
    ///         $0.glassEffect(.regular.interactive())
    ///     } else {
    ///         $0
    ///     }
    /// }
    /// ```
    ///
    /// - Parameters:
    ///   - transform: The transform to apply to the source `View`.
    /// - Returns: Apply the block on the original `View`.
    func apply<V: View>(@ViewBuilder _ block: (Self) -> V) -> V {
        block(self)
    }

    func asAnyView() -> AnyView {
        AnyView(self)
    }

    @discardableResult
    func Print(_ args: Any...) -> some View {
        args.forEach { print($0) }
        return EmptyView()
    }
}
