// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "HummingbirdDemo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "HummingbirdDemo",
            targets: ["HummingbirdDemo"]
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
            name: "HummingbirdDemo",
            dependencies: [
                "HummingbirdDemoContent",
                .product(name: "SwiftStateTreeHummingbirdHosting", package: "SwiftStateTree")
            ],
            path: "Sources/SwiftStateTreeHummingbirdDemo"
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
