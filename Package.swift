// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "CoreKit",
    platforms: [
        .iOS(.v17),
        .macOS(.v14),
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
