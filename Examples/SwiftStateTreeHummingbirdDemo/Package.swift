// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SwiftStateTreeHummingbirdDemo",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(
            name: "SwiftStateTreeHummingbirdDemo",
            targets: ["SwiftStateTreeHummingbirdDemo"]
        )
    ],
    dependencies: [
        .package(name: "SwiftStateTree", path: "../..")
    ],
    targets: [
        .target(
            name: "SwiftStateTreeHummingbirdDemoContent",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree")
            ],
            path: "Sources/DemoContent"
        ),
        .executableTarget(
            name: "SwiftStateTreeHummingbirdDemo",
            dependencies: [
                "SwiftStateTreeHummingbirdDemoContent",
                .product(name: "SwiftStateTreeHummingbirdHosting", package: "SwiftStateTree")
            ],
            path: "Sources/SwiftStateTreeHummingbirdDemo"
        )
    ]
)

