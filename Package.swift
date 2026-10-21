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
    ],
    products: [
        .library(
            name: "CoreKit",
            targets: ["CoreKit"]
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
        // 3.x or 4.x: ContentHash only uses SHA256, stable across both majors. `from: "3.0.0"`
        // capped consumers below 4.0 and downgraded them (ShikkiMCP#10 review: swift-crypto
        // 4.5.1 → 3.15.1, forced by a test-support dependency).
        .package(url: "https://github.com/apple/swift-crypto.git", "3.0.0"..<"5.0.0"),
    ],
    targets: [
        .target(
            name: "CoreKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .target(
            name: "CoreKitTestSupport"
        ),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit", "CoreKitTestSupport"]
        ),
    ]
)
