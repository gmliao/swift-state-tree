// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HummingbirdDemo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "DemoServer",
            targets: ["DemoServer"]
        ),
        .executable(
            name: "SchemaGen",
            targets: ["SchemaGen"]
        ),
        .executable(
            name: "ReevaluationRunner",
            targets: ["ReevaluationRunner"]
        )
    ],
    dependencies: [
        .package(name: "SwiftStateTree", path: "../..")
    ],
    targets: [
        .target(
            name: "HummingbirdDemoContent",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeDeterministicMath", package: "SwiftStateTree")
            ],
            path: "Sources/DemoContent"
        ),
        .executableTarget(
            name: "DemoServer",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTreeHummingbird", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree")
            ],
            path: "Sources/DemoServer"
        ),
        .executableTarget(
            name: "SchemaGen",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/SchemaGen"
        ),
        .executableTarget(
            name: "ReevaluationRunner",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/ReevaluationRunner"
        )
    ]
)
