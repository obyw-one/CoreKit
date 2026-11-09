// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoreKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
        // tvOS was never declared. An undeclared platform builds at SwiftPM's
        // oldest supported version for it, so `AnimatedTabView` — which uses the
        // tvOS-18-only Tab DSL (`Tab`, `TabContent`, `TabContentBuilder`) behind
        // an `@available(iOS 18.0, *)` whose `*` fallback means "any" on tvOS —
        // failed to compile for every tvOS consumer.
        //
        // A consuming app CANNOT fix this: SwiftPM builds a dependency at the
        // dependency's own floor, not the app's. BrainyTube set tvOS 18.0 in
        // both project.yml and Package.swift and still failed, because the floor
        // that matters is this one.
        //
        // Apple TV 4K 3rd gen ships tvOS 26+, so 18.0 costs no reachability.
        .tvOS(.v18),
        // visionOS: what works on iOS works on visionOS. 1.0 is the visionOS release that matches
        // iOS 17, the iOS floor above.
        .visionOS(.v1),
    ],
    products: [
        .library(
            name: "CoreKit",
            targets: ["CoreKit"]
        ),
        // Apple-only UI surface (Coordinator, View+Extensions, AnimatedTabView,
        // NetworkStatus). The `CoreKit` product above is SwiftUI/Combine/Network
        // free so it builds on Linux; apps import `CoreKit` + `CoreKitUI`, the
        // backend imports `CoreKit` only. Every CoreKitUI source is wrapped in
        // `#if canImport(SwiftUI)`, so the module is empty (not half-typed) off Apple.
        .library(
            name: "CoreKitUI",
            targets: ["CoreKitUI"]
        ),
        // Apple-only Keychain + auth-token persistence, absorbed from the
        // standalone SecurityKit. Security.framework does not exist on Linux, so
        // this is its own product: the `CoreKit` product stays Linux-clean and
        // the backend never links it. Every source is wrapped in
        // `#if canImport(Security)`, so the module is empty off Apple.
        .library(
            name: "CoreKitSecurity",
            targets: ["CoreKitSecurity"]
        ),
        // Test-only helpers every consumer's ratchet stands on
        // (BR-CKT-03). Split product so app targets can depend on
        // `CoreKit` without pulling test scaffolding.
        .library(
            name: "CoreKitTestSupport",
            targets: ["CoreKitTestSupport"]
        ),
    ],
    dependencies: [
        // swift-crypto — Apple's cross-platform crypto (re-exports CryptoKit
        // impls on Darwin, pure-Swift on Linux). ONE fleet dep for hashing,
        // per [[spm-primitive-reuse-is-mandatory-not-a-question]]: plugins
        // consume CoreKit.ContentHash, never CryptoKit directly.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.5.2"),
        // swift-log — AppLog's backend where Apple's `os` is absent (Linux/Windows).
        .package(url: "https://github.com/apple/swift-log.git", from: "1.5.0"),
    ],
    targets: [
        .target(
            name: "CoreKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
                .product(
                    name: "Logging", package: "swift-log",
                    condition: .when(platforms: [.linux, .windows, .android])),
            ]
        ),
        .target(
            name: "CoreKitUI",
            dependencies: ["CoreKit"]
        ),
        .target(
            name: "CoreKitSecurity",
            dependencies: ["CoreKit"]
        ),
        .target(
            name: "CoreKitTestSupport",
            dependencies: ["CoreKit"]
        ),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit", "CoreKitTestSupport"],
            // Paths/Fixtures stays excluded: the counted-depth ratchet baseline there is read by path on purpose.
            exclude: ["Paths/Fixtures"],
            // Wire fixtures are declared resources: a moved or renamed file is a build error, and
            // `FixtureFile` reads them through `Bundle.module`, not a path into the checkout.
            resources: [.process("Fixtures")]
        ),
        .testTarget(
            name: "CoreKitSecurityTests",
            dependencies: ["CoreKitSecurity", "CoreKit"]
        ),
        .testTarget(
            name: "CoreKitUITests",
            dependencies: ["CoreKitUI", "CoreKit"]
        ),
    ]
)
