// swift-tools-version: 6.0

import PackageDescription

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
        )
    ],
    dependencies: [
        // Dependencies will be added as needed during development
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no network dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [],
            path: "Sources/SwiftStateTree",
            exclude: [
                "Realm/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md"
            ]
        ),
        
        // 🔹 Library tests (using Swift Testing framework)
        .testTarget(
            name: "SwiftStateTreeTests",
            dependencies: ["SwiftStateTree"],
            path: "Tests/SwiftStateTreeTests"
        )
    ]
)

