import Foundation
import GameContent
import SwiftStateTree
import SwiftStateTreeHummingbird
import SwiftStateTreeReevaluationMonitor
import SwiftStateTreeTransport

/// Hero Defense Server
///
/// A standalone tower defense game server showcasing SwiftStateTree capabilities.
/// Players can move freely, shoot monsters, and upgrade with resources.
///
/// **Configuration**:
/// - Port: Set via `PORT` environment variable (default: 8080)
/// - Host: Set via `HOST` environment variable (default: "localhost")
/// - Log level: Set via `LOG_LEVEL` (trace, debug, info, notice, warning, error, critical; default: info)
/// - Reevaluation recording: Off by default; set `ENABLE_REEVALUATION=true` to enable writing reevaluation records (for replay/verification).
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
/// # Run with minimal logs (e.g. for load tests)
/// LOG_LEVEL=error swift run GameServer
///
/// # Enable reevaluation recording (for replay/verification)
/// ENABLE_REEVALUATION=true swift run GameServer
/// ```
@main
struct GameServer {
    static func main() async throws {
        let jwtConfig = createGameJWTConfig()
        let logLevel = getEnvLogLevel(key: "LOG_LEVEL", defaultValue: .info)
        let logger = createGameLogger(
            scope: "HeroDefenseServer",
            logLevel: logLevel
        )

        let host = getEnvString(key: "HOST", defaultValue: "localhost")
        let port = getEnvUInt16(key: "PORT", defaultValue: 8080)
        let enableReevaluation = getEnvBool(key: "ENABLE_REEVALUATION", defaultValue: false)

        // Single TRANSPORT_ENCODING controls both message and stateUpdate encoding
        let transportEncodingEnv = getEnvString(key: "TRANSPORT_ENCODING", defaultValue: "messagepack")
        let transportEncoding = resolveTransportEncoding(rawValue: transportEncodingEnv)

        logger.info("📦 Transport encoding configured", metadata: [
            "message": .string(transportEncoding.message.rawValue),
            "stateUpdate": .string(transportEncoding.stateUpdate.rawValue),
        ])

        // Extract pathHashes from schema for compression
        let landDef = HeroDefense.makeLand()
        let schema = SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(landDef)])
        let pathHashes = schema.lands["hero-defense"]?.pathHashes

        if let pathHashes = pathHashes {
            logger.info("✅ PathHashes extracted", metadata: [
                "count": .string("\(pathHashes.count)"),
                "sample": .string(Array(pathHashes.keys.prefix(3)).joined(separator: ", ")),
            ])
        } else {
            logger.warning("⚠️ PathHashes is nil - compression will fall back to Legacy format")
        }

        let landHost = LandHost(configuration: LandHost.HostConfiguration(
            host: host,
            port: port,
            logger: logger
        ))

        if enableReevaluation {
            logger.info("✅ Reevaluation enabled (recording for replay/verification)")
        } else {
            logger.info("Reevaluation disabled (set ENABLE_REEVALUATION=true to enable)")
        }

        let serverConfig = LandServerConfiguration(
            logger: logger,
            jwtConfig: jwtConfig,
            jwtValidator: nil,
            allowGuestMode: true,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: pathHashes, // Enable PathHash compression
            eventHashes: nil,
            clientEventHashes: nil,
            servicesFactory: { _, _ in
                var services = LandServices()

                // Inject GameConfig provider
                let configProvider = DefaultGameConfigProvider()
                let configService = GameConfigProviderService(provider: configProvider)
                services.register(configService, as: GameConfigProviderService.self)

                if enableReevaluation {
                    let reevaluationFactory = GameReevaluationFactory()
                    let reevaluationService = ReevaluationRunnerService(factory: reevaluationFactory)
                    services.register(reevaluationService, as: ReevaluationRunnerService.self)
                }

                return services
            }
        )

        // Register Hero Defense game
        try await landHost.register(
            landType: "hero-defense",
            land: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            webSocketPath: "/game/hero-defense",
            configuration: serverConfig
        )

        if enableReevaluation {
            // Register Reevaluation Monitor
            try await landHost.register(
                landType: "reevaluation-monitor",
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: "/reevaluation-monitor",
                configuration: serverConfig
            )
        }

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
                "error": .string(String(describing: error)),
            ])
            exit(1)
        }
    }
}
