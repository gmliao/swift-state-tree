// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GameDemo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "GameServer",
            targets: ["GameServer"]
        ),
        .executable(
            name: "SchemaGen",
            targets: ["SchemaGen"]
        )
    ],
    dependencies: [
        .package(name: "SwiftStateTree", path: "../..")
    ],
    targets: [
        .target(
            name: "GameContent",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeDeterministicMath", package: "SwiftStateTree")
            ],
            path: "Sources/GameContent"
        ),
        .executableTarget(
            name: "GameServer",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree")
            ],
            path: "Sources/GameServer"
        ),
        .executableTarget(
            name: "SchemaGen",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/SchemaGen"
        )
    ]
)
