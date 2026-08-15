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
