//
//  AnimatedTabView.swift
//  CoreKit
//
//  iOS-18+ TabView wrapper that drives SF Symbol effects on the active tab's
//  icon (bounce / wiggle / rotate / …). Lifted from the WabiSabi project where
//  it lived as a private screen-level helper, promoted here so any iOS app
//  consuming CoreKit can reuse it.
//
//  Origin: WabiSabi/Commons/Presentation/AnimatedTabbar/AnimatedTabView.swift
//  Reference video: https://www.youtube.com/watch?v=8YiYCzx7Cws
//
//  Usage:
//  ──────
//    enum MyTab: Int, AnimatedTabSelectionProtocol {
//        case home, search, settings
//        var title: String { … }
//        var symbolImage: String { … }
//    }
//
//    @State var selected = MyTab.home
//
//    AnimatedTabView(selectedTab: $selected) {
//        Tab(MyTab.home.title, systemImage: MyTab.home.symbolImage, value: .home) {
//            HomeView()
//        }
//        Tab(MyTab.search.title, systemImage: MyTab.search.symbolImage, value: .search) {
//            SearchView()
//        }
//    } effects: { tab in
//        switch tab as? MyTab {
//        case .home: [BounceSymbolEffect.bounce.up]
//        case .search: [RotateSymbolEffect.rotate]
//        default: []
//        }
//    }
//

#if canImport(UIKit)
    import SwiftUI
    import UIKit

    /// Conformance contract for the enum/struct that drives an `AnimatedTabView`.
    ///
    /// Each case is one tab. `title` and `symbolImage` are forwarded to SwiftUI's
    /// `Tab(_:systemImage:value:)` initializer. `symbolImage` must be a valid SF
    /// Symbol name — the `AnimatedTabView` matches it against the underlying
    /// `UITabBar`'s `UIImageView` descriptions to find the icon to animate.
    public protocol AnimatedTabSelectionProtocol: CaseIterable, Hashable, Sendable {
        var title: String { get }
        var symbolImage: String { get }
    }

    /// SwiftUI `TabView` wrapper that animates the active tab's SF Symbol via
    /// `addSymbolEffect`. iOS 18+ (uses the new `Tab` DSL + `TabContent`
    /// result builder). On iOS 26+ it also opts into
    /// `.tabBarMinimizeBehavior(.onScrollDown)` for the auto-hiding tab bar.
    @available(iOS 18.0, *)
    public struct AnimatedTabView<
        Selection: AnimatedTabSelectionProtocol,
        Content: TabContent<Selection>
    >: View {
        @Binding var selectedTab: Selection
        @TabContentBuilder<Selection> var content: () -> Content
        var effects: (Selection) -> [any DiscreteSymbolEffect & SymbolEffect]

        @State private var imageViews: [Selection: UIImageView] = [:]

        public init(
            selectedTab: Binding<Selection>,
            @TabContentBuilder<Selection> _ content: @escaping () -> Content,
            effects: @escaping (any AnimatedTabSelectionProtocol) -> [any DiscreteSymbolEffect & SymbolEffect]
        ) {
            self._selectedTab = selectedTab
            self.content = content
            self.effects = effects
        }

        public var body: some View {
            TabView(selection: $selectedTab) {
                content()
            }
            .apply {
                if #available(iOS 26.0, *) {
                    $0.tabBarMinimizeBehavior(.onScrollDown)
                } else {
                    $0
                }
            }
            .tabViewStyle(.tabBarOnly)
            .background(ExtractImageViewsFromTabBar(result: { imageViews = $0 }))
            .compositingGroup()
            .onChange(of: selectedTab) { _, newValue in
                let symbolEffect = effects(newValue)
                guard let imageView = imageViews[newValue] else { return }
                for effect in symbolEffect {
                    imageView.addSymbolEffect(effect, options: .nonRepeating)
                }
            }
        }
    }

    // MARK: - UIKit traversal helper (private)

    @available(iOS 18.0, *)
    private struct ExtractImageViewsFromTabBar<Value: AnimatedTabSelectionProtocol>: UIViewRepresentable {
        var result: ([Value: UIImageView]) -> Void

        func makeUIView(context _: Context) -> UIView {
            let view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false

            DispatchQueue.main.async {
                // The compositingGroup sits two layers above the tab hosting controller.
                if let compositingGroup = view.superview?.superview,
                   let tabHostingController = compositingGroup.subviews.last,
                   let tabController = tabHostingController.subviews.first?.next as? UITabBarController
                {
                    extractImageViews(tabController.tabBar)
                }
            }

            return view
        }

        func updateUIView(_: UIView, context _: Context) {}

        private func extractImageViews(_ tabBar: UITabBar) {
            let imageViews = tabBar.subviews(type: UIImageView.self)
                .filter { $0.image?.isSymbolImage ?? false }
                // On iOS 26 only the tinted image view is the icon — others are background art.
                .filter { isiOS26 ? ($0.tintColor == tabBar.tintColor) : true }

            var dict: [Value: UIImageView] = [:]
            for tab in Value.allCases {
                if let imageView = imageViews.first(where: { $0.description.contains(tab.symbolImage) }) {
                    dict[tab] = imageView
                }
            }
            result(dict)
        }

        private var isiOS26: Bool {
            if #available(iOS 26.0, *) { return true }
            return false
        }
    }

    private extension UIView {
        /// Recursive descent that flattens all subviews of a concrete type.
        func subviews<T: UIView>(type: T.Type) -> [T] {
            subviews.compactMap { $0 as? T } +
                subviews.flatMap { $0.subviews(type: type) }
        }
    }

#endif
