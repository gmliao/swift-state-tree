// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
    name: "SwiftStateTree",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        // ⭐ Open source library for public use
        .library(
            name: "SwiftStateTree",
            targets: ["SwiftStateTree"]
        ),
        // 📦 MessagePack core codec
        .library(
            name: "SwiftStateTreeMessagePack",
            targets: ["SwiftStateTreeMessagePack"]
        ),
        // 🌐 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .library(
            name: "SwiftStateTreeTransport",
            targets: ["SwiftStateTreeTransport"]
        ),
        // 🔢 Deterministic Math: Fixed-point math for server-authoritative games
        .library(
            name: "SwiftStateTreeDeterministicMath",
            targets: ["SwiftStateTreeDeterministicMath"]
        ),
        // ⚡ Pure NIO WebSocket: High-performance WebSocket transport without Hummingbird
        .library(
            name: "SwiftStateTreeNIO",
            targets: ["SwiftStateTreeNIO"]
        ),
        // 📡 NIO Provisioning Middleware: Optional middleware for control plane registration
        .library(
            name: "SwiftStateTreeNIOProvisioning",
            targets: ["SwiftStateTreeNIOProvisioning"]
        ),
        // 🔍 Reevaluation Monitor: Built-in Land for monitoring reevaluation verification
        .library(
            name: "SwiftStateTreeReevaluationMonitor",
            targets: ["SwiftStateTreeReevaluationMonitor"]
        ),
        // 🔹 Benchmark executable
        .executable(
            name: "SwiftStateTreeBenchmarks",
            targets: ["SwiftStateTreeBenchmarks"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no network dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [
                "SwiftStateTreeMacros",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SwiftStateTree",
            exclude: [
                "Land/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md",
                "Resolver/README.md",
            ]
        ),

        // 🔹 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .target(
            name: "SwiftStateTreeTransport",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMessagePack",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Sources/SwiftStateTreeTransport"
        ),

        // 📦 MessagePack core codec
        .target(
            name: "SwiftStateTreeMessagePack",
            dependencies: [
                "SwiftStateTree",
            ],
            path: "Sources/SwiftStateTreeMessagePack"
        ),

        // 🔢 Deterministic Math: Fixed-point math for server-authoritative games
        .target(
            name: "SwiftStateTreeDeterministicMath",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros",
            ],
            path: "Sources/SwiftStateTreeDeterministicMath",
            exclude: [
                "Docs",
            ]
        ),

        // 🔍 Reevaluation Monitor: Built-in Land for monitoring reevaluation verification
        .target(
            name: "SwiftStateTreeReevaluationMonitor",
            dependencies: [
                "SwiftStateTree",
            ],
            path: "Sources/SwiftStateTreeReevaluationMonitor"
        ),

        // ⚡ Pure NIO WebSocket: High-performance WebSocket transport
        .target(
            name: "SwiftStateTreeNIO",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeReevaluationMonitor",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SwiftStateTreeNIO"
        ),

        // 📡 NIO Provisioning: Middleware + HTTP client for control plane registration
        .target(
            name: "SwiftStateTreeNIOProvisioning",
            dependencies: [
                "SwiftStateTreeNIO",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "AsyncHTTPClient", package: "async-http-client"),
                .product(name: "NIOPosix", package: "swift-nio"),
            ],
            path: "Sources/SwiftStateTreeNIOProvisioning"
        ),

        // 🔹 Macro Implementation: Compile-time macro expansion
        .macro(
            name: "SwiftStateTreeMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftStateTreeMacros"
        ),

        // 🔹 Library tests (using Swift Testing framework)
        .testTarget(
            name: "SwiftStateTreeTests",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros",
                "SwiftStateTreeTransport",
                "SwiftStateTreeReevaluationMonitor",
                "SwiftStateTreeDeterministicMath",
                "SwiftStateTreeMessagePack",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/SwiftStateTreeTests"
        ),

        // 🔹 Transport tests
        .testTarget(
            name: "SwiftStateTreeTransportTests",
            dependencies: [
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                "SwiftStateTreeMessagePack",
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Tests/SwiftStateTreeTransportTests",
            // Golden recordings, read from the source tree by SyncOutputGoldenTests.
            exclude: ["Fixtures"]
        ),

        // ⚡ NIO tests
        .testTarget(
            name: "SwiftStateTreeNIOTests",
            dependencies: [
                "SwiftStateTreeNIO",
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                "SwiftStateTreeReevaluationMonitor",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/SwiftStateTreeNIOTests"
        ),

        // 🔹 Macro tests
        .testTarget(
            name: "SwiftStateTreeMacrosTests",
            dependencies: [
                "SwiftStateTreeMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
            ],
            path: "Tests/SwiftStateTreeMacrosTests"
        ),

        // 🔢 Deterministic Math tests
        .testTarget(
            name: "SwiftStateTreeDeterministicMathTests",
            dependencies: [
                "SwiftStateTreeDeterministicMath",
                "SwiftStateTree",
            ],
            path: "Tests/SwiftStateTreeDeterministicMathTests"
        ),

        // 🔹 Benchmark executable
        .executableTarget(
            name: "SwiftStateTreeBenchmarks",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeMacros",
            ],
            path: "Sources/SwiftStateTreeBenchmarks",
            exclude: [
                "README.md",
            ]
        ),
    ]
)
