// swift-tools-version: 5.9
// The Duo Desktop terminal's SSH engine (project notes, M2 + the engine side of M4). Kept apart
// from the app so the "super version" (terminal + KVM) stays separable from the plain Glass Act version: the app
// links this only when built with DUO_TERMINAL. swift-nio-ssh is Apache-2.0, pinned to one exact release.
import PackageDescription

let package = Package(
    name: "DuoTerminalKit",
    platforms: [.iOS("17.0"), .macOS("14.0")],
    products: [
        .library(name: "DuoTerminalKit", targets: ["DuoTerminalKit"]),
        .executable(name: "duo-ssh-probe", targets: ["duo-ssh-probe"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio-ssh", exact: "0.15.1"),
        .package(url: "https://github.com/apple/swift-nio", from: "2.65.0"),
    ],
    targets: [
        .target(name: "DuoTerminalKit", dependencies: [
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOCore", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
        .executableTarget(name: "duo-ssh-probe", dependencies: ["DuoTerminalKit"]),
        .testTarget(name: "DuoTerminalKitTests", dependencies: [
            "DuoTerminalKit",
            .product(name: "NIOSSH", package: "swift-nio-ssh"),
            .product(name: "NIOEmbedded", package: "swift-nio"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ]),
    ]
)
