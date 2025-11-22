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
        ),
        // ⭐ Demo Server (Vapor)
        .executable(
            name: "SwiftStateTreeVaporDemo",
            targets: ["SwiftStateTreeVaporDemo"]
        )
    ],
    dependencies: [
        // Vapor 4
        .package(url: "https://github.com/vapor/vapor.git", from: "4.90.0")
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no Vapor dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [],
            path: "Sources/SwiftStateTree"
        ),

        // 🔹 Demo Server: Depends on Vapor + SwiftStateTree
        .executableTarget(
            name: "SwiftStateTreeVaporDemo",
            dependencies: [
                "SwiftStateTree",
                .product(name: "Vapor", package: "vapor")
            ],
            path: "Sources/SwiftStateTreeVaporDemo"
        ),

        // 🔹 Library tests
        .testTarget(
            name: "SwiftStateTreeTests",
            dependencies: ["SwiftStateTree"],
            path: "Tests/SwiftStateTreeTests"
        )
    ]
)

