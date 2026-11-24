// swift-tools-version: 6.0
// A throwaway codemod for #771 D2 and #769 R1: not part of the library. Deleted in the PR that
// runs it (#771 D-Q1 (a)).
import PackageDescription

let package = Package(
    name: "DSLCodemod",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-syntax.git", exact: "602.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "DSLCodemod",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
            ]
        ),
    ]
)
