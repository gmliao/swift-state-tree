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

        // Schema and path hashes (replay land types only when reevaluation enabled)
        let liveLand = HeroDefense.makeLand()
        let schemaLands: [AnyLandDefinition] = enableReevaluation
            ? [AnyLandDefinition(liveLand), AnyLandDefinition(ReevaluationMonitor.makeLand())]
            : [AnyLandDefinition(liveLand)]
        let schema = SchemaGenCLI.generateSchema(
            landDefinitions: schemaLands,
            replayLandTypes: enableReevaluation ? ["hero-defense"] : nil
        )
        let pathHashes = schema.lands["hero-defense"]?.pathHashes
        logPathHashes(pathHashes, logger: logger)
        logger.info(enableReevaluation ? "✅ Reevaluation enabled (recording for replay/verification)" : "Reevaluation disabled (set ENABLE_REEVALUATION=true to enable)")

        let schemaData: Data? = try? JSONEncoder().encode(schema)
        let schemaProvider: @Sendable () -> Data? = { schemaData }

        let middlewares = buildProvisioningMiddlewares()
        let nioHost = NIOLandHost(configuration: NIOLandHostConfiguration(
            host: host,
            port: port,
            logger: logger,
            schemaProvider: schemaProvider,
            adminAPIKey: "hero-defense-admin-key",
            middlewares: middlewares
        ))

        let serverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: pathHashes,
            eventHashes: nil,
            clientEventHashes: nil,
            servicesFactory: { _, _ in makeGameServices(enableReevaluation: enableReevaluation, requiredRecordVersion: requiredReplayRecordVersion) }
        )

        try await nioHost.registerWithGenericReplay(
            landType: "hero-defense",
            liveLand: liveLand,
            liveInitialState: HeroDefenseState(),
            liveWebSocketPath: "/game/hero-defense",
            configuration: serverConfig,
            reevaluation: ReevaluationFeatureConfiguration(
                enabled: enableReevaluation,
                replayEventPolicy: .projectedOnly,
                runnerServiceFactory: { ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredReplayRecordVersion)) }
            )
        )

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

// MARK: - Helpers

private func logPathHashes(_ pathHashes: [String: UInt32]?, logger: Logger) {
    if let pathHashes = pathHashes {
        logger.info("✅ PathHashes extracted", metadata: [
            "count": .string("\(pathHashes.count)"),
            "sample": .string(Array(pathHashes.keys.prefix(3)).joined(separator: ", ")),
        ])
    } else {
        logger.warning("⚠️ PathHashes is nil - compression will fall back to Legacy format")
    }
}

private func buildProvisioningMiddlewares() -> [any HostMiddleware] {
    var builder = HostMiddlewareBuilder()
    if let provBaseUrl = getEnvStringOptional(key: ProvisioningEnvKeys.baseUrl) {
        let connectHost = getEnvStringOptional(key: ProvisioningEnvKeys.connectHost)
        let connectPort = getEnvStringOptional(key: ProvisioningEnvKeys.connectPort).flatMap { Int($0) }
        let connectScheme = getEnvStringOptional(key: ProvisioningEnvKeys.connectScheme)
        let serverId = getEnvStringOptional(key: ProvisioningEnvKeys.serverId) ?? "game-\(String(UUID().uuidString.prefix(8)))"
        builder.add(NIOLandHostConfiguration.provisioningMiddleware(
            baseUrl: provBaseUrl,
            serverId: serverId,
            landType: "hero-defense",
            heartbeatIntervalSeconds: 30,
            connectHost: connectHost,
            connectPort: connectPort,
            connectScheme: (connectScheme == "ws" || connectScheme == "wss") ? connectScheme : nil
        ))
    }
    return builder.build()
}

private func makeGameServices(enableReevaluation: Bool, requiredRecordVersion: String) -> LandServices {
    var services = LandServices()
    services.register(GameConfigProviderService(provider: DefaultGameConfigProvider()), as: GameConfigProviderService.self)
    if enableReevaluation {
        services.register(ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredRecordVersion)), as: ReevaluationRunnerService.self)
        services.register(ReevaluationReplayPolicyService(eventPolicy: .projectedOnly), as: ReevaluationReplayPolicyService.self)
    }
    return services
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
