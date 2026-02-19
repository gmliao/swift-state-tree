import Foundation
import GameContent
import Logging
import ProfileRecorderServer
import SwiftStateTree
import SwiftStateTreeNIO
import SwiftStateTreeNIOProvisioning
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
/// - Matchmaking: Set `PROVISIONING_BASE_URL` (e.g. http://127.0.0.1:3000) to register with matchmaking control plane on startup.
/// - Client-facing URL (K8s/nginx): Set `PROVISIONING_CONNECT_HOST`, `PROVISIONING_CONNECT_PORT`, `PROVISIONING_CONNECT_SCHEME` when behind Ingress or LB.
/// - Guest mode: Enabled (all connections allowed; NIO has no JWT)
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
        let logLevelForProfile = getEnvLogLevel(key: "LOG_LEVEL", defaultValue: .info)
        let loggerForProfile = createGameLogger(scope: "HeroDefenseServer", logLevel: logLevelForProfile)
        // Run Swift Profile Recorder in background when PROFILE_RECORDER_SERVER_URL_PATTERN is set.
        async let _ = ProfileRecorderServer(configuration: .parseFromEnvironment()).runIgnoringFailures(logger: loggerForProfile)
        let logLevel = getEnvLogLevel(key: "LOG_LEVEL", defaultValue: .info)
        let logger = createGameLogger(
            scope: "HeroDefenseServer",
            logLevel: logLevel
        )

        let host = getEnvString(key: "HOST", defaultValue: "localhost")
        let port = getEnvUInt16(key: "PORT", defaultValue: 8080)
        let enableReevaluation = getEnvBool(key: "ENABLE_REEVALUATION", defaultValue: false)
        let requiredReplayRecordVersion = ProcessInfo.processInfo.environment[
            "REEVALUATION_REPLAY_REQUIRED_RECORD_VERSION"
        ] ?? "2.0"

        // Single TRANSPORT_ENCODING controls both message and stateUpdate encoding
        let transportEncodingEnv = getEnvString(key: "TRANSPORT_ENCODING", defaultValue: "messagepack")
        let transportEncoding = resolveTransportEncoding(rawValue: transportEncodingEnv)

        logger.info("📦 Transport encoding configured", metadata: [
            "message": .string(transportEncoding.message.rawValue),
            "stateUpdate": .string(transportEncoding.stateUpdate.rawValue),
        ])

        // Extract pathHashes from schema for compression
        let landDef = HeroDefense.makeLand()
        var schemaLandDefinitions: [AnyLandDefinition] = [AnyLandDefinition(landDef)]
        if enableReevaluation {
            schemaLandDefinitions.append(AnyLandDefinition(ReevaluationMonitor.makeLand()))
            schemaLandDefinitions.append(AnyLandDefinition(HeroDefenseReplay.makeLand()))
        }
        let schema = SchemaGenCLI.generateSchema(landDefinitions: schemaLandDefinitions)
        let pathHashes = schema.lands["hero-defense"]?.pathHashes

        if let pathHashes = pathHashes {
            logger.info("✅ PathHashes extracted", metadata: [
                "count": .string("\(pathHashes.count)"),
                "sample": .string(Array(pathHashes.keys.prefix(3)).joined(separator: ", ")),
            ])
        } else {
            logger.warning("⚠️ PathHashes is nil - compression will fall back to Legacy format")
        }

        if enableReevaluation {
            logger.info("✅ Reevaluation enabled (recording for replay/verification)")
        } else {
            logger.info("Reevaluation disabled (set ENABLE_REEVALUATION=true to enable)")
        }

        // Generate schema for /schema endpoint
        let schemaData: Data? = try? JSONEncoder().encode(schema)
        let schemaProvider: @Sendable () -> Data? = { schemaData }

        var middlewareBuilder = HostMiddlewareBuilder()
        if let provBaseUrl = getEnvStringOptional(key: ProvisioningEnvKeys.baseUrl) {
            let connectHost = getEnvStringOptional(key: ProvisioningEnvKeys.connectHost)
            let connectPort = getEnvStringOptional(key: ProvisioningEnvKeys.connectPort).flatMap { Int($0) }
            let connectScheme = getEnvStringOptional(key: ProvisioningEnvKeys.connectScheme)
            let serverId = getEnvStringOptional(key: ProvisioningEnvKeys.serverId) ?? "game-\(String(UUID().uuidString.prefix(8)))"
            middlewareBuilder.add(NIOLandHostConfiguration.provisioningMiddleware(
                baseUrl: provBaseUrl,
                serverId: serverId,
                landType: "hero-defense",
                heartbeatIntervalSeconds: 30,
                connectHost: connectHost,
                connectPort: connectPort,
                connectScheme: (connectScheme == "ws" || connectScheme == "wss") ? connectScheme : nil
            ))
        }
        let middlewares = middlewareBuilder.build()

        let nioHost = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: host,
            port: port,
            logger: logger,
            schemaProvider: schemaProvider,
            adminAPIKey: "hero-defense-admin-key",
            middlewares: middlewares
        ))

        let baseServerConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: nil,
            eventHashes: nil,
            clientEventHashes: nil,
            servicesFactory: { _, _ in
                var services = LandServices()

                // Inject GameConfig provider
                let configProvider = DefaultGameConfigProvider()
                let configService = GameConfigProviderService(provider: configProvider)
                services.register(configService, as: GameConfigProviderService.self)

                if enableReevaluation {
                    let reevaluationFactory = GameServerReevaluationFactory(
                        requiredRecordVersion: requiredReplayRecordVersion
                    )
                    let reevaluationService = ReevaluationRunnerService(factory: reevaluationFactory)
                    services.register(reevaluationService, as: ReevaluationRunnerService.self)
                }

                return services
            }
        )

        var heroDefenseServerConfig = baseServerConfig
        heroDefenseServerConfig.pathHashes = pathHashes

        // Register Hero Defense game
        try await nioHost.register(
            landType: "hero-defense",
            land: HeroDefense.makeLand(),
            initialState: HeroDefenseState(),
            webSocketPath: "/game/hero-defense",
            configuration: heroDefenseServerConfig
        )

        if enableReevaluation {
            // Register Reevaluation Monitor
            try await nioHost.register(
                landType: "reevaluation-monitor",
                land: ReevaluationMonitor.makeLand(),
                initialState: ReevaluationMonitorState(),
                webSocketPath: "/reevaluation-monitor",
                configuration: baseServerConfig
            )

            // Register Hero Defense replay stream land
            try await nioHost.register(
                landType: "hero-defense-replay",
                land: HeroDefenseReplay.makeLand(),
                initialState: HeroDefenseState(),
                webSocketPath: "/game/hero-defense-replay",
                configuration: baseServerConfig
            )
        }

        await nioHost.registerAdminRoutes()
        logger.info("✅ HTTP endpoints available: /health, /schema, /admin/*")

        do {
            try await nioHost.run()
        } catch {
            logger.error("❌ Server startup failed: \(error)", metadata: [
                "error": .string(String(describing: error)),
            ])
            exit(1)
        }
    }
}

private struct GameServerReevaluationFactory: ReevaluationTargetFactory {
    let requiredRecordVersion: String

    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "hero-defense":
            var services = LandServices()
            services.register(
                GameConfigProviderService(provider: DefaultGameConfigProvider()),
                as: GameConfigProviderService.self
            )

            return try await ConcreteReevaluationRunner(
                definition: HeroDefense.makeLand(),
                initialState: HeroDefenseState(),
                recordFilePath: recordFilePath,
                requiredRecordVersion: requiredRecordVersion,
                services: services
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}
