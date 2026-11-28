// swift-tools-version: 6.4

import CompilerPluginSupport
import PackageDescription

// The NIO provisioning middleware is not built on Windows: AsyncHTTPClient's C target needs POSIX
// `strptime`, which the Windows CRT lacks. On other platforms the two lists hold the same product and
// target as before, in the same place in `products` and `targets`.
#if os(Windows)
let provisioningProducts: [Product] = []
let provisioningTargets: [Target] = []
#else
let provisioningProducts: [Product] = [
    .library(
        name: "SwiftStateTreeNIOProvisioning",
        targets: ["SwiftStateTreeNIOProvisioning"]
    ),
]
let provisioningTargets: [Target] = [
    .target(
        name: "SwiftStateTreeNIOProvisioning",
        dependencies: [
            "SwiftStateTreeNIO",
            .product(name: "Logging", package: "swift-log"),
            .product(name: "AsyncHTTPClient", package: "async-http-client"),
            .product(name: "NIOPosix", package: "swift-nio"),
        ],
        path: "Sources/SwiftStateTreeNIOProvisioning"
    ),
]
#endif

let package = Package(
    name: "SwiftStateTree",
    // macOS 15 for `Synchronization.Mutex` (the land RNG service, #700 K1b-3). Only macOS is
    // listed, so other Apple platforms keep SwiftPM's defaults; `Mutex` would need iOS, tvOS and
    // Mac Catalyst 18, watchOS 11 and visionOS 2 if the package is ever built for them. Every
    // manifest that depends on this package must name the same floor.
    platforms: [
        .macOS(.v15),
    ],
    products: [
        // ⭐ Open source library for public use
        .library(
            name: "SwiftStateTree",
            targets: ["SwiftStateTree"]
        ),
        // 📦 MessagePack core codec
        .library(
            name: "SwiftStateTreeMessagePack",
            targets: ["SwiftStateTreeMessagePack"]
        ),
        // 🌐 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .library(
            name: "SwiftStateTreeTransport",
            targets: ["SwiftStateTreeTransport"]
        ),
        // 🔁 Turn core: synchronous steps over a value machine, for actors that own state
        .library(
            name: "SwiftStateTurns",
            targets: ["SwiftStateTurns"]
        ),
        // 🔢 Deterministic Math: Fixed-point math for server-authoritative games
        .library(
            name: "SwiftStateTreeDeterministicMath",
            targets: ["SwiftStateTreeDeterministicMath"]
        ),
        // ⚡ Pure NIO WebSocket: High-performance WebSocket transport without Hummingbird
        .library(
            name: "SwiftStateTreeNIO",
            targets: ["SwiftStateTreeNIO"]
        ),
        // 📡 NIO Provisioning Middleware: Optional middleware for control plane registration
        ] + provisioningProducts + [
        // 🔍 Reevaluation Monitor: Built-in Land for monitoring reevaluation verification
        .library(
            name: "SwiftStateTreeReevaluationMonitor",
            targets: ["SwiftStateTreeReevaluationMonitor"]
        ),
        // 🔹 Benchmark executable
        .executable(
            name: "SwiftStateTreeBenchmarks",
            targets: ["SwiftStateTreeBenchmarks"]
        ),
    ],
    dependencies: [
        // The macros' swift-syntax. Package.resolved pins 604.0.0, the line of CI's Swift 6.4.3,
        // which builds it from source (no prebuilt is used). The range keeps 602 open for packages
        // that depend on this one.
        .package(url: "https://github.com/apple/swift-syntax.git", "602.0.0"..<"605.0.0"),
        .package(url: "https://github.com/apple/swift-atomics.git", from: "1.3.0"),
        .package(url: "https://github.com/apple/swift-log.git", from: "1.6.0"),
        .package(url: "https://github.com/apple/swift-crypto.git", from: "4.0.0"),
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.77.0"),
        .package(url: "https://github.com/swift-server/async-http-client.git", from: "1.21.0"),
    ],
    targets: [
        // 🔹 Core Library: Pure Swift game logic, no network dependency
        .target(
            name: "SwiftStateTree",
            dependencies: [
                "SwiftStateTreeMacros",
                "SwiftStateTurns",
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SwiftStateTree",
            exclude: [
                "Land/README.md",
                "Runtime/README.md",
                "SchemaGen/README.md",
                "Resolver/README.md",
            ]
        ),

        // 🔹 Transport Layer: Framework-agnostic transport abstraction (network + services)
        .target(
            name: "SwiftStateTreeTransport",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMessagePack",
                "SwiftStateTurns",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Atomics", package: "swift-atomics"),
            ],
            path: "Sources/SwiftStateTreeTransport"
        ),

        // 📦 MessagePack core codec
        .target(
            name: "SwiftStateTreeMessagePack",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTurns",
            ],
            path: "Sources/SwiftStateTreeMessagePack"
        ),

        // 🔢 Deterministic Math: Fixed-point math for server-authoritative games
        .target(
            name: "SwiftStateTreeDeterministicMath",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros",
                "SwiftStateTurns",
            ],
            path: "Sources/SwiftStateTreeDeterministicMath",
            exclude: [
                "Docs",
            ]
        ),

        // 🔍 Reevaluation Monitor: Built-in Land for monitoring reevaluation verification
        .target(
            name: "SwiftStateTreeReevaluationMonitor",
            dependencies: [
                "SwiftStateTree",
                // The runner replays a MessagePack land's record with the live decoder (#700 K1a).
                "SwiftStateTreeMessagePack",
            ],
            path: "Sources/SwiftStateTreeReevaluationMonitor"
        ),

        // ⚡ Pure NIO WebSocket: High-performance WebSocket transport
        .target(
            name: "SwiftStateTreeNIO",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeReevaluationMonitor",
                .product(name: "Crypto", package: "swift-crypto"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Sources/SwiftStateTreeNIO"
        ),

        // 📡 NIO Provisioning: Middleware + HTTP client for control plane registration
        ] + provisioningTargets + [

        // 🔁 Turn core: depends on nothing else in this package
        .target(
            name: "SwiftStateTurns",
            dependencies: ["SwiftStateTurnsMacros"],
            path: "Sources/SwiftStateTurns"
        ),
        .macro(
            name: "SwiftStateTurnsMacros",
            dependencies: [
                "PlainDataMacroSupport",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftStateTurnsMacros"
        ),
        // The field walk behind `@PlainData`, shared by both macro targets (not a product)
        .target(
            name: "PlainDataMacroSupport",
            dependencies: [
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftSyntaxBuilder", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
            ],
            path: "Sources/PlainDataMacroSupport"
        ),
        .testTarget(
            name: "SwiftStateTurnsTests",
            // SwiftStateTree only for the documentation's comparison (a hand-fixed actor with
            // GenerationTable); the turn core itself doesn't depend on it.
            dependencies: ["SwiftStateTurns", "SwiftStateTree"],
            path: "Tests/SwiftStateTurnsTests"
        ),
        .testTarget(
            name: "SwiftStateTurnsMacrosTests",
            dependencies: [
                "SwiftStateTurnsMacros",
                .product(name: "SwiftSyntax", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacroExpansion", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            path: "Tests/SwiftStateTurnsMacrosTests"
        ),
        // The turn core's cost against a direct baseline (release only)
        .executableTarget(
            name: "TurnsBench",
            dependencies: ["SwiftStateTurns"],
            path: "Sources/TurnsBench"
        ),
        // The mailbox's cost on an empty mailbox, mailbox on against mailbox off (release only). Its own
        // target, so its machines' specializations can't merge with TurnsBench's gated ones.
        .executableTarget(
            name: "TurnsMailboxBench",
            dependencies: ["SwiftStateTurns"],
            path: "Sources/TurnsMailboxBench"
        ),

        // 🔹 Macro Implementation: Compile-time macro expansion
        .macro(
            name: "SwiftStateTreeMacros",
            dependencies: [
                "PlainDataMacroSupport",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
            ],
            path: "Sources/SwiftStateTreeMacros"
        ),

        // 🔹 Library tests (using Swift Testing framework)
        .testTarget(
            name: "SwiftStateTreeTests",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeMacros",
                "SwiftStateTreeTransport",
                "SwiftStateTreeReevaluationMonitor",
                "SwiftStateTreeDeterministicMath",
                "SwiftStateTreeMessagePack",
                "SwiftStateTreeTestSupport",
                .product(name: "Logging", package: "swift-log"),
                .product(name: "Crypto", package: "swift-crypto"),
            ],
            path: "Tests/SwiftStateTreeTests",
            // Inputs read from the source tree (CanonicalMessagePackTests).
            exclude: ["Fixtures"]
        ),

        // 🔹 Test support: helpers shared by the test targets (TestGate, RecordingConnection).
        // Only test targets depend on it.
        .target(
            name: "SwiftStateTreeTestSupport",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeMessagePack",
            ],
            path: "Tests/SwiftStateTreeTestSupport"
        ),

        // 🔹 Transport tests
        .testTarget(
            name: "SwiftStateTreeTransportTests",
            dependencies: [
                "SwiftStateTreeTestSupport",
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                "SwiftStateTreeMessagePack",
                "SwiftStateTreeDeterministicMath",
                "SwiftStateTreeReevaluationMonitor",
                "SwiftStateTurns",
                .product(name: "Atomics", package: "swift-atomics"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/SwiftStateTreeTransportTests",
            // Golden recordings, read from the source tree by SyncOutputGoldenTests.
            exclude: ["Fixtures"]
        ),

        // ⚡ NIO tests
        .testTarget(
            name: "SwiftStateTreeNIOTests",
            dependencies: [
                "SwiftStateTreeTestSupport",
                "SwiftStateTreeNIO",
                "SwiftStateTreeTransport",
                "SwiftStateTree",
                "SwiftStateTreeMessagePack",
                "SwiftStateTreeReevaluationMonitor",
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOHTTP1", package: "swift-nio"),
                .product(name: "NIOWebSocket", package: "swift-nio"),
                .product(name: "NIOEmbedded", package: "swift-nio"),
                .product(name: "Logging", package: "swift-log"),
            ],
            path: "Tests/SwiftStateTreeNIOTests",
            // The harness's goldens, read from the source tree by path, not as resources.
            exclude: ["Differential/Golden"]
        ),

        // 🔹 Macro tests
        .testTarget(
            name: "SwiftStateTreeMacrosTests",
            dependencies: [
                "SwiftStateTreeMacros",
                .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
                .product(name: "SwiftSyntaxMacrosGenericTestSupport", package: "swift-syntax"),
                .product(name: "SwiftParser", package: "swift-syntax"),
                .product(name: "SwiftParserDiagnostics", package: "swift-syntax"),
                .product(name: "SwiftDiagnostics", package: "swift-syntax"),
            ],
            path: "Tests/SwiftStateTreeMacrosTests"
        ),

        // 🔢 Deterministic Math tests
        .testTarget(
            name: "SwiftStateTreeDeterministicMathTests",
            dependencies: [
                "SwiftStateTreeDeterministicMath",
                "SwiftStateTree",
                "SwiftStateTurns",
            ],
            path: "Tests/SwiftStateTreeDeterministicMathTests"
        ),

        // 🔹 Benchmark executable
        .executableTarget(
            name: "SwiftStateTreeBenchmarks",
            dependencies: [
                "SwiftStateTree",
                "SwiftStateTreeTransport",
                "SwiftStateTreeMacros",
            ],
            path: "Sources/SwiftStateTreeBenchmarks",
            exclude: [
                "README.md",
            ]
        ),
    ]
)
