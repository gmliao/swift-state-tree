// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftStateTree",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        // ⭐ Open source library for public use
        .library(
            name: "SwiftStateTree",
            targets: ["SwiftStateTree"]
        ),
        // 🌐 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .library(
            name: "SwiftStateTreeTransport",
            targets: ["SwiftStateTreeTransport"]
        ),
        // 🕊️ Hummingbird integration
        .library(
            name: "SwiftStateTreeHummingbird",
            targets: ["SwiftStateTreeHummingbird"]
        ),
        // 🎯 Matchmaking & Lobby: Matchmaking service and lobby functionality
        .library(
            name: "SwiftStateTreeMatchmaking",
            targets: ["SwiftStateTreeMatchmaking"]
        ),
        // 🔹 Benchmark executable
        .executable(
            name: "SwiftStateTreeBenchmarks",
            targets: ["SwiftStateTreeBenchmarks"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0")
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no network dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [
                "SwiftStateTreeMacros",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SwiftStateTree",
            exclude: [
                "Land/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md",
                "Resolver/README.md"
            ]
        ),
        
        // 🔹 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .target(
            name: "SwiftStateTreeTransport",
            dependencies: [
                "SwiftStateTree",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SwiftStateTreeTransport"
        ),
        
        // 🕊️ Hummingbird integration
        .target(
            name: "SwiftStateTreeHummingbird",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeMatchmaking",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket"),
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SwiftStateTreeHummingbird"
        ),
        
        // 🎯 Matchmaking & Lobby: Matchmaking service and lobby functionality
        .target(
            name: "SwiftStateTreeMatchmaking",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                .product(name: "Logging", package: "swift-log")
            ],
            path: "Sources/SwiftStateTreeMatchmaking"
        ),
        
        // 🔹 Macro Implementation: Compile-time macro expansion
        .macro(
            name: "SwiftStateTreeMacros",
            dependencies: [
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax")
            ],
            path: "Sources/SwiftStateTreeMacros"
        ),
        
        // 🔹 Library tests (using Swift Testing framework)
        .testTarget(
            name: "SwiftStateTreeTests",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros"
            ],
            path: "Tests/SwiftStateTreeTests"
        ),
        
        // 🔹 Transport tests
        .testTarget(
            name: "SwiftStateTreeTransportTests",
            dependencies: [
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                "SwiftStateTreeHummingbird",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Tests/SwiftStateTreeTransportTests"
        ),
        
        // 🕊️ Hummingbird tests
        .testTarget(
            name: "SwiftStateTreeHummingbirdTests",
            dependencies: [
                "SwiftStateTreeHummingbird",
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")
            ],
            path: "Tests/SwiftStateTreeHummingbirdTests"
        ),
        
        // 🔹 Macro tests
        .testTarget(
            name: "SwiftStateTreeMacrosTests",
            dependencies: [
                "SwiftStateTreeMacros",
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax")
            ],
            path: "Tests/SwiftStateTreeMacrosTests"
        ),
        
        // 🎯 Matchmaking tests
        .testTarget(
            name: "SwiftStateTreeMatchmakingTests",
            dependencies: [
                "SwiftStateTreeMatchmaking",
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                .product(name: "Atomics", package: "swift-atomics")
            ],
            path: "Tests/SwiftStateTreeMatchmakingTests"
        ),
        
        // 🔹 Benchmark executable
        .executableTarget(
            name: "SwiftStateTreeBenchmarks",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros"
            ],
            path: "Sources/SwiftStateTreeBenchmarks",
            exclude: [
                "README.md"
            ]
        ),
    ]
)
