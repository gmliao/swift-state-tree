import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeTransport

/// Hero Defense Server
///
/// A standalone tower defense game server showcasing SwiftStateTree capabilities.
/// Players can move freely, shoot monsters, and upgrade with resources.
///
/// **Configuration**:
/// - Port: Set via `PORT` environment variable (default: 8080)
/// - Host: Set via `HOST` environment variable (default: "localhost")
/// - Guest mode: Enabled (allows connections without JWT)
/// - Auto-create rooms: Enabled (clients can create rooms dynamically)
/// - Admin routes: Enabled at `/admin/*` (API Key: `hero-defense-admin-key`)
///
/// **Usage**:
/// ```bash
/// # Run with default settings (localhost:8080)
/// swift run GameServer
///
/// # Run on custom port
/// PORT=3000 swift run GameServer
///
/// # Run on custom host and port
/// HOST=0.0.0.0 PORT=3000 swift run GameServer
/// ```
@main
struct GameServer {
    static func main() async throws {
        let jwtConfig = createGameJWTConfig()
        let logger = createGameLogger(
            scope: "HeroDefenseServer",
            logLevel: .info
        )
        
        let host = getEnvString(key: "HOST", defaultValue: "localhost")
        let port = getEnvUInt16(key: "PORT", defaultValue: 8080)

        // Single TRANSPORT_ENCODING controls both message and stateUpdate encoding
        let transportEncoding = resolveTransportEncoding(
            rawValue: getEnvString(key: "TRANSPORT_ENCODING", defaultValue: "msgpack")
        )
        
        logger.info("📦 Transport encoding configured", metadata: [
            "message": .string(transportEncoding.message.rawValue),
            "stateUpdate": .string(transportEncoding.stateUpdate.rawValue)
        ])
        
        // Extract pathHashes from schema for compression
        let landDef = HeroDefense.makeLand()
        let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
        let pathHashes = schema.lands["hero-defense"]?.pathHashes
        
        if let pathHashes = pathHashes {
            logger.info("✅ PathHashes extracted", metadata: [
                "count": .string("\(pathHashes.count)"),
                "sample": .string(Array(pathHashes.keys.prefix(3)).joined(separator: ", "))
            ])
        } else {
            logger.warning("⚠️ PathHashes is nil - compression will fall back to Legacy format")
        }
        
        let landHost = LandHost(configuration: LandHost.HostConfiguration(
            host: host,
            port: port,
            logger: logger
        ))
        
        let serverConfig = LandServerConfiguration(
            logger: logger,
            jwtConfig: jwtConfig,
            allowGuestMode: true,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableParallelEncoding: true,
            pathHashes: pathHashes  // Enable PathHash compression
        )
        
        // Register Hero Defense game
        try await landHost.register(
            landType: "hero-defense",
            land: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            webSocketPath: "/game/hero-defense",
            configuration: serverConfig
        )
        
        // Register admin routes
        let adminAuth = AdminAuthMiddleware(
            jwtValidator: nil,
            apiKey: "hero-defense-admin-key"
        )
        await landHost.registerAdminRoutes(
            adminAuth: adminAuth,
            logger: logger
        )
        logger.info("✅ Admin routes registered at /admin/* (API Key: hero-defense-admin-key)")
        
        do {
            try await landHost.run()
        } catch let error as LandHostError {
            logger.error("❌ Server startup failed: \(error)", metadata: [
                "error": .string(String(describing: error))
            ])
            exit(1)
        }
    }
}

private func resolveTransportEncoding(rawValue: String) -> TransportEncodingConfig {
    switch rawValue.lowercased() {
    case "opcode", "opcodejsonarray", "opcode_json_array", "opcode-json-array":
        return TransportEncodingConfig(
            message: .opcodeJsonArray,
            stateUpdate: .opcodeJsonArray,
            enablePayloadCompression: true
        )
    case "messagepack", "msgpack", "message-pack":
        return TransportEncodingConfig(
            message: .messagepack,
            stateUpdate: .opcodeMessagePack,  // Opcode array structure, serialized as MessagePack binary
            enablePayloadCompression: true
        )
    default:
        return TransportEncodingConfig(
            message: .json,
            stateUpdate: .jsonObject,
            enablePayloadCompression: false
        )
    }
}

