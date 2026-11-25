// swift-tools-version: 6.0

import PackageDescription

// A WebSocket echo server for the Autobahn|Testsuite (scripts/autobahn/run.sh). It hosts the
// real NIOWebSocketServer with a transport whose delegate echoes every message, so the suite
// exercises the server's frame handling and nothing above it.
let package = Package(
    name: "AutobahnEcho",
    platforms: [
        .macOS(.v15)
    ],
    products: [
        .executable(name: "AutobahnEcho", targets: ["AutobahnEcho"])
    ],
    dependencies: [
        .package(name: "SwiftStateTree", path: "../..")
    ],
    targets: [
        .executableTarget(
            name: "AutobahnEcho",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeNIO", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree")
            ],
            path: "Sources/AutobahnEcho"
        )
    ]
)
