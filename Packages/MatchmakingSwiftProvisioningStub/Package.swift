// swift-tools-version: 6.0
// The swift-tools-version declares the minimum version of Swift required to build this package.

import PackageDescription

let package = Package(
    name: "MatchmakingSwiftProvisioningStub",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(
            name: "MatchmakingSwiftProvisioningStub",
            targets: ["MatchmakingSwiftProvisioningStub"]
        ),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
    ],
    targets: [
        .executableTarget(
            name: "MatchmakingSwiftProvisioningStub",
            dependencies: [
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
            ]
        ),
    ]
)
