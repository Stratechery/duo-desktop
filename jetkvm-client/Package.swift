// swift-tools-version:5.9
// JetKVM native client engine for Duo Desktop. MIT, written from scratch (no JetKVM code copied).
import PackageDescription

let package = Package(
    name: "JetKVMClient",
    platforms: [.iOS(.v16), .macOS(.v13)],
    products: [
        .library(name: "JetKVMProtocol", targets: ["JetKVMProtocol"]),
        .library(name: "JetKVMClient", targets: ["JetKVMClient"]),
        .executable(name: "jetkvm-probe", targets: ["jetkvm-probe"]),
    ],
    dependencies: [
        // Pinned exactly. BSD-3-Clause (build scripts) + WebRTC's BSD-style licence. See LICENSES.md.
        .package(url: "https://github.com/stasel/WebRTC.git", exact: "158.0.0"),
    ],
    targets: [
        // Pure Swift: wire formats only (hidrpc, signaling, JSON-RPC events, login). No WebRTC. Unit tested.
        .target(name: "JetKVMProtocol"),
        // The session: login, signaling WebSocket, WebRTC peer connection, video, input, take-over.
        .target(name: "JetKVMClient", dependencies: [
            "JetKVMProtocol",
            .product(name: "WebRTC", package: "WebRTC"),
        ]),
        // Command-line live check: connect, save one frame as PNG, nudge the pointer, press shift, disconnect.
        .executableTarget(name: "jetkvm-probe", dependencies: ["JetKVMClient"]),
        .testTarget(name: "JetKVMProtocolTests", dependencies: ["JetKVMProtocol"]),
        // Review fixes (review finding 4): the connect deadline, with the network steps replaced (no JetKVM).
        .testTarget(name: "JetKVMClientTests", dependencies: [
            "JetKVMClient", .product(name: "WebRTC", package: "WebRTC"),
        ]),
    ]
)
