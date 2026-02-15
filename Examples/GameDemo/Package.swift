// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "GameDemo",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .library(
            name: "GameContent",
            targets: ["GameContent"]
        ),
        .executable(
            name: "GameServer",
            targets: ["GameServer"]
        ),
        .executable(
            name: "SchemaGen",
            targets: ["SchemaGen"]
        ),
        .executable(
            name: "ReevaluationRunner",
            targets: ["ReevaluationRunner"]
        ),
        .executable(
            name: "ServerLoadTest",
            targets: ["ServerLoadTest"]
        ),
    ],
    dependencies: [
        .package(name: "SwiftStateTree", path: "../.."),
        .package(url: "https://github.com/apple/swift-profile-recorder.git", .upToNextMinor(from: "0.3.0")),
    ],
    targets: [
        .target(
            name: "GameContent",
            dependencies: [
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeDeterministicMath", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeReevaluationMonitor", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree"),
            ],
            path: "Sources/GameContent"
        ),
        .executableTarget(
            name: "GameServer",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTreeNIO", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeNIOProvisioning", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree"),
                .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
            ],
            path: "Sources/GameServer"
        ),
        .executableTarget(
            name: "SchemaGen",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
            ],
            path: "Sources/SchemaGen"
        ),
        .executableTarget(
            name: "ReevaluationRunner",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
            ],
            path: "Sources/ReevaluationRunner"
        ),
        .executableTarget(
            name: "EncodingBenchmark",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeMessagePack", package: "SwiftStateTree"),
            ],
            path: "Sources/EncodingBenchmark"
        ),
        .executableTarget(
            name: "ServerLoadTest",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTree", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeNIO", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeTransport", package: "SwiftStateTree"),
                .product(name: "SwiftStateTreeMessagePack", package: "SwiftStateTree"),
                .product(name: "ProfileRecorderServer", package: "swift-profile-recorder"),
            ],
            path: "Sources/ServerLoadTest"
        ),
        .testTarget(
            name: "GameContentTests",
            dependencies: [
                "GameContent",
                .product(name: "SwiftStateTreeDeterministicMath", package: "SwiftStateTree"),
            ],
            path: "Tests"
        ),
    ]
)
