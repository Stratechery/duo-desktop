// swift-tools-version: 6.0
// Duo Desktop's own copy of RoyalVNCKit (MIT, Royal Apps), taken at 090b96e (ROYALVNC_COMMIT); upstream was archived
// on 2026-10-05. Our changes to the upstream files are in patches/ (see README-DUO.md). This manifest is ours:
// Apple platforms only, a static library, upstream CryptoSwift pinned by tag, no demos, no Windows zlib, no Cstb
// (upstream used it only on Linux, Windows and Android).

import PackageDescription

let package = Package(
    name: "RoyalVNCKit",

    platforms: [
        .macOS(.v13),
        .iOS(.v16),
    ],

    products: [
        .library(name: "RoyalVNCKit", targets: [ "RoyalVNCKit" ]),
    ],

    dependencies: [
        // Upstream CryptoSwift at a pinned release (not Royal's fork branch). Its licence is in Notices.
        .package(url: "https://github.com/krzyzanowskim/CryptoSwift.git", exact: "1.9.0"),
    ],

    targets: [
        .target(name: "RoyalVNCKitC"),

        .target(
            name: "RoyalVNCKit",
            dependencies: [
                "RoyalVNCKitC",
                "d3des",
                "Z",
                .product(name: "CryptoSwift", package: "CryptoSwift"),
            ],
            swiftSettings: [
                .swiftLanguageMode(.v5),
                // As upstream: its `@_implementationOnly` imports (CryptoSwift, RoyalVNCKitC) need library evolution.
                .unsafeFlags([ "-enable-library-evolution" ]),
            ]
        ),

        .target(name: "d3des"),

        // The system zlib (in iOS and macOS).
        .target(name: "Z", linkerSettings: [ .linkedLibrary("z") ]),

        // Our tests for our changes (sign-in fixes, Mac-account-only choice).
        .testTarget(
            name: "RoyalVNCKitTests",
            dependencies: [ "RoyalVNCKit" ],
            swiftSettings: [ .swiftLanguageMode(.v5) ]
        ),
    ]
)
