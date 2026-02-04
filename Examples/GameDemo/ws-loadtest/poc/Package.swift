// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TransportActorVsQueuePOC",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "TransportActorVsQueuePOC", targets: ["TransportActorVsQueuePOC"])],
    targets: [
        .executableTarget(
            name: "TransportActorVsQueuePOC",
            path: "Sources"
        ),
    ]
)
