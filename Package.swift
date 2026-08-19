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
    ],
    dependencies: [
        // swift-crypto — Apple's cross-platform crypto (re-exports CryptoKit
        // impls on Darwin, pure-Swift on Linux). ONE fleet dep for hashing,
        // per [[spm-primitive-reuse-is-mandatory-not-a-question]]: plugins
        // consume CoreKit.ContentHash, never CryptoKit directly.
        .package(url: "https://github.com/apple/swift-crypto.git", from: "3.0.0"),
    ],
    targets: [
        .target(
            name: "CoreKit",
            dependencies: [
                .product(name: "Crypto", package: "swift-crypto"),
            ]
        ),
        .testTarget(
            name: "CoreKitTests",
            dependencies: ["CoreKit"]
        ),
    ]
)
