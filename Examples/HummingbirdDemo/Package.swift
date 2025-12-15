// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HummingbirdDemo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SingleRoomDemo",
            targets: ["SingleRoomDemo"]
        ),
        .executable(
            name: "MultiRoomDemo",
            targets: ["MultiRoomDemo"]
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
            name: "HummingbirdDemoContent",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/DemoContent"
        ),
        .executableTarget(
            name: "SingleRoomDemo",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree")
            ],
            path: "Sources/SingleRoomDemo"
        ),
        .executableTarget(
            name: "MultiRoomDemo",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree")
            ],
            path: "Sources/MultiRoomDemo"
        ),
        .executableTarget(
            name: "SchemaGen",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/SchemaGen"
        )
    ]
)
