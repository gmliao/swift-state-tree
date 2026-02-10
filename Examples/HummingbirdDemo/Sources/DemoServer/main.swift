import Foundation
import HummingbirdDemoContent
import SwiftStateTree
import SwiftStateTreeNIO
import SwiftStateTreeTransport

/// Demo Server (NIO WebSocket)
///
/// A unified demo server that showcases SwiftStateTree capabilities:
/// - Multiple land types (cookie game and counter demo)
/// - Multi-room support with dynamic room creation
/// - Unified HTTP server and game logic management via NIOLandHost
///
/// **Land Types**:
/// - `cookie`: Cookie Clicker game (CookieGameState) at `/game/cookie`
/// - `counter`: Simple counter demo (CounterState) at `/game/counter`
///
/// **Configuration**:
/// - Port: Set via `PORT` environment variable (default: 8080)
/// - Host: Set via `HOST` environment variable (default: "localhost")
/// - Transport Encoding: Set via `TRANSPORT_ENCODING` environment variable (default: "json")
///   - `json`: JSON messages + JSON object state updates (default)
///   - `jsonOpcode`: JSON messages + opcode JSON array state updates
///   - `opcode`: Opcode JSON array for both messages and state updates
///   - `messagepack`: MessagePack binary encoding for both
/// - Guest mode: Enabled (all connections allowed; NIO has no JWT)
/// - Auto-create rooms: Enabled (clients can create rooms dynamically)
/// - Admin routes: Enabled at `/admin/*` (API Key: `demo-admin-key`)
///
/// **Usage**:
/// ```bash
/// # Run with default settings (localhost:8080, json encoding)
/// swift run DemoServer
///
/// # Run on custom port
/// PORT=3000 swift run DemoServer
///
/// # Run on custom host and port
/// HOST=0.0.0.0 PORT=3000 swift run DemoServer
///
/// # Run with opcode JSON array state updates
/// TRANSPORT_ENCODING=jsonOpcode swift run DemoServer
/// ```
@main
struct DemoServer {
    static func main() async throws {
        // Create logger with custom log level
        let logger = HummingbirdDemoContent.createDemoLogger(
            scope: "DemoServer",
            logLevel: .debug
        )

        // Get configuration from environment variables
        let host = HummingbirdDemoContent.getEnvString(key: "HOST", defaultValue: "localhost")
        let port = HummingbirdDemoContent.getEnvUInt16(key: "PORT", defaultValue: 8080)
        let transportEncodingRaw = HummingbirdDemoContent.getEnvString(key: "TRANSPORT_ENCODING", defaultValue: "json")
        let transportEncoding = resolveTransportEncoding(rawValue: transportEncodingRaw)

        // Schema for /schema endpoint (used by E2E CLI and WebClient codegen)
        let demoLandDefinitions: [AnyLandDefinition] = [
            AnyLandDefinition(HummingbirdDemoContent.CookieGame.makeLand()),
            AnyLandDefinition(HummingbirdDemoContent.CounterDemo.makeLand()),
        ]
        let protocolSchema = SchemaGenCLI.generateSchema(landDefinitions: demoLandDefinitions, version: "0.1.0")
        let schemaEncoder = JSONEncoder()
        schemaEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let schemaData = try schemaEncoder.encode(protocolSchema)

        // Create NIOLandHost to manage both game logic and HTTP server
        let landHost = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: host,
            port: port,
            logger: logger,
            schemaProvider: { schemaData },
            adminAPIKey: "demo-admin-key"
        ))

        // Shared server configuration for all land types
        let serverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: true
        )

        logger.info("📡 Transport encoding: \(transportEncodingRaw) (message: \(transportEncoding.message.rawValue), stateUpdate: \(transportEncoding.stateUpdate.rawValue))")

        // Register Cookie Game server
        try await landHost.register(
            landType: "cookie",
            land: HummingbirdDemoContent.CookieGame.makeLand(),
            initialState: CookieGameState(),
            webSocketPath: "/game/cookie",
            configuration: serverConfig
        )

        // Register Counter Demo server
        try await landHost.register(
            landType: "counter",
            land: HummingbirdDemoContent.CounterDemo.makeLand(),
            initialState: CounterState(),
            webSocketPath: "/game/counter",
            configuration: serverConfig
        )

        // Register admin routes (uses adminAPIKey from NIOLandHostConfiguration)
        await landHost.registerAdminRoutes()
        logger.info("✅ Admin routes registered at /admin/* (API Key: demo-admin-key)")

        // Run unified server
        do {
            try await landHost.run()
        } catch let error as NIOLandHostError {
            logger.error("❌ Server startup failed: \(error)", metadata: [
                "error": .string(String(describing: error)),
            ])
            exit(1)
        }
    }
}

private func resolveTransportEncoding(rawValue: String) -> TransportEncodingConfig {
    switch rawValue.lowercased() {
    case "json":
        return .json
    case "jsonopcode", "json_opcode", "json-opcode":
        return .jsonOpcode
    case "opcode":
        return .opcode
    case "messagepack", "msgpack":
        return .messagepack
    default:
        return .json
    }
}
