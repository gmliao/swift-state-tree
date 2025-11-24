// swift-tools-version: 6.0

import PackageDescription
import CompilerPluginSupport

let package = Package(
    name: "SwiftStateTree",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        // ⭐ Open source library for public use
        .library(
            name: "SwiftStateTree",
            targets: ["SwiftStateTree"]
        ),
        // 🔹 Benchmark executable
        .executable(
            name: "SwiftStateTreeBenchmarks",
            targets: ["SwiftStateTreeBenchmarks"]
        )
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", from: "509.0.0")
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
                "Realm/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md"
            ]
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
        )
    ]
)
