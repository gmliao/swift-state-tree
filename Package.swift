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
        // 🌐 Transport Layer
        .library(
            name: "SwiftStateTreeTransport",
            targets: ["SwiftStateTreeTransport"]
        ),
        // 🕊️ Hummingbird Transport Adapter
        .library(
            name: "SwiftStateTreeHummingbird",
            targets: ["SwiftStateTreeHummingbird"]
        ),
        // 🔹 Benchmark executable
        .executable(
            name: "SwiftStateTreeBenchmarks",
            targets: ["SwiftStateTreeBenchmarks"]
        ),
        // 🕊️ Hummingbird Demo executable
        .executable(
            name: "SwiftStateTreeHummingbirdDemo",
            targets: ["SwiftStateTreeHummingbirdDemo"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird.git", from: "2.0.0"),
        .package(url: "https://github.com/hummingbird-project/hummingbird-websocket.git", from: "2.0.0")
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no network dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [
                "SwiftStateTreeMacros"
            ],
            path: "Sources/SwiftStateTree",
            exclude: [
                "Land/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md"
            ]
        ),
        
        // 🔹 Transport Layer: Network abstraction
        .target(
            name: "SwiftStateTreeTransport",
            dependencies: [
                "SwiftStateTree"
            ],
            path: "Sources/SwiftStateTreeTransport"
        ),
        
        // 🕊️ Hummingbird Adapter
        .target(
            name: "SwiftStateTreeHummingbird",
            dependencies: [
                "SwiftStateTreeTransport",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")
            ],
            path: "Sources/SwiftStateTreeHummingbird"
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
                "SwiftStateTree"
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
        
        // 🕊️ Hummingbird Demo executable
        .executableTarget(
            name: "SwiftStateTreeHummingbirdDemo",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros",
                "SwiftStateTreeTransport",
                "SwiftStateTreeHummingbird",
                .product(name: "Hummingbird", package: "hummingbird"),
                .product(name: "HummingbirdWebSocket", package: "hummingbird-websocket")
            ],
            path: "Sources/SwiftStateTreeHummingbirdDemo"
        )
    ]
)
