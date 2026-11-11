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
/// - Players per land: `HERO_DEFENSE_MAX_PLAYERS` (default: 10), e.g. 50 for 50-player load-test rooms.
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
        // First, before any output: a closed stdout or stderr pipe gives EPIPE, not a kill (#273).
        ProcessSignals.ignoreSIGPIPE()
        let logLevelForProfile = getEnvLogLevel(key: "LOG_LEVEL", defaultValue: .info)
        let loggerForProfile = createGameLogger(scope: "HeroDefenseServer", logLevel: logLevelForProfile)
        // Run Swift Profile Recorder in background only when it is configured: reading its
        // configuration starts NIO's singleton event-loop group (see ProfileRecorderEnvKeys).
        if ProfileRecorderEnvKeys.isConfigured {
            Task {
                do {
                    let configuration = try await ProfileRecorderServerConfiguration.parseFromEnvironment()
                    await ProfileRecorderServer(configuration: configuration).runIgnoringFailures(logger: loggerForProfile)
                } catch {
                    loggerForProfile.warning("Profile recorder not started: \(error)")
                }
            }
        }
        let logLevel = getEnvLogLevel(key: "LOG_LEVEL", defaultValue: .info)
        let logger = createGameLogger(
            scope: "HeroDefenseServer",
            logLevel: logLevel
        )

        let host = getEnvString(key: "HOST", defaultValue: "localhost")
        let port = getEnvUInt16(key: "PORT", defaultValue: 8080)
        let enableReevaluation = getEnvBool(key: "ENABLE_REEVALUATION", defaultValue: false)
        // Unset: replay any record this build reads (2.5+ JSON, 3.x). Set it to require one major
        // (e.g. "3.0" refuses a 2.6 record). A replay that refuses its record never advances.
        let requiredReplayRecordVersion: String? = ProcessInfo.processInfo.environment[
            "REEVALUATION_REPLAY_REQUIRED_RECORD_VERSION"
        ]

        // Single TRANSPORT_ENCODING controls both message and stateUpdate encoding
        let transportEncodingEnv = getEnvString(key: "TRANSPORT_ENCODING", defaultValue: "messagepack")
        // DYNAMIC_KEY_COMPRESSION=false sends dynamic keys as full strings (#59); PATH_INDEX=false
        // sends path hashes instead of path indices (on by default; clients declare `pathIndex`);
        // FIELD_MERGE=false turns off merged entries (on by default; clients declare `fieldMerge`).
        // ROW_ADDRESSING=true names the rows of root node maps by slot (off by default; clients
        // declare `rowAddressing`; the load-test client doesn't yet).
        let transportEncoding = resolveTransportEncoding(rawValue: transportEncodingEnv)
            .withDynamicKeyCompression(TransportEncodingConfig.dynamicKeyCompressionFromEnvironment())
            .withPathIndex(TransportEncodingConfig.pathIndexFromEnvironment())
            .withFieldMerge(TransportEncodingConfig.fieldMergeFromEnvironment())
            .withRowAddressing(TransportEncodingConfig.rowAddressingFromEnvironment())

        logger.info("📦 Transport encoding configured", metadata: [
            "message": .string(transportEncoding.message.rawValue),
            "stateUpdate": .string(transportEncoding.stateUpdate.rawValue),
            "dynamicKeyCompression": .stringConvertible(transportEncoding.dynamicKeyCompression),
            "pathIndex": .stringConvertible(transportEncoding.pathIndex),
            "fieldMerge": .stringConvertible(transportEncoding.fieldMerge),
        ])

        let maxPlayers = heroDefenseMaxPlayers()
        let gameConfig = DefaultGameConfigProvider.fromEnvironment()
        // Unconditional startup lines (not the logger: load-test scripts run with LOG_LEVEL=error).
        try? FileHandle.standardError.write(contentsOf: Data(
            "GameServer effective maxPlayers=\(maxPlayers) (\(GameServerEnvKeys.maxPlayers), default 10)\n".utf8
        ))
        try? FileHandle.standardError.write(contentsOf: Data(
            ("GameServer effective spawnRampTicks=\(gameConfig.spawnRampTicks) (\(HeroDefenseEnvKeys.spawnRampTicks), "
                + "default \(GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS))\n").utf8
        ))
        // The listen backlog the kernel will queue (#124): the requested value capped at somaxconn
        let backlog = NIOWebSocketServerConfiguration.listenBacklogCheck(
            requested: NIOWebSocketServerConfiguration.listenBacklog()
        )
        try? FileHandle.standardError.write(contentsOf: Data(
            ("GameServer effective listenBacklog=\(backlog.effective) (requested \(backlog.requested) via "
                + "\(EnvKeys.Server.listenBacklog), somaxconn \(backlog.systemCap.map(String.init) ?? "unchecked"))\n").utf8
        ))

        // Schema and path hashes (replay land types only when reevaluation enabled)
        let liveLand = HeroDefense.makeLand(maxPlayers: maxPlayers)
        // Test lands (#65), each on its own path; Hero Defense's registration is unchanged.
        // The broadcast twin is a benchmark and re-evaluation variant; a client of this server
        // gets the per-player state's schema, so it can't serve the twin.
        if VisibilityTestSettings.current.filter == .broadcast {
            FileHandle.standardError.write(Data("\(VisibilityTestEnvKeys.filter)=broadcast is for EncodingBenchmark and ReevaluationRunner only\n".utf8))
            exit(2)
        }
        let visibilityLand = VisibilityTest.makeLand()
        let resolverLand = ResolverTest.makeLand()
        let testLands = [AnyLandDefinition(visibilityLand), AnyLandDefinition(resolverLand)]
        let schemaLands: [AnyLandDefinition] = enableReevaluation
            ? [AnyLandDefinition(liveLand), AnyLandDefinition(ReevaluationMonitor.makeLand())] + testLands
            : [AnyLandDefinition(liveLand)] + testLands
        let schema = try SchemaGenCLI.generateSchema(
            landDefinitions: schemaLands,
            replayLandTypes: enableReevaluation ? ["hero-defense", VisibilityTestConfig.landType, ResolverTestConfig.landType] : nil
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

        // HERO_DEFENSE_STATS_PATH: each hero-defense land's monsters and base health, one JSONL line per window.
        let heroDefenseStats = try HeroDefenseStatsWriter.startFromEnvironment()
        let serverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: pathHashes,
            eventHashes: nil,
            clientEventHashes: nil,
            // The replay land (`hero-defense-replay`) is built through this factory too: only
            // live lands note their stats.
            servicesFactory: { landID, _ in
                makeGameServices(enableReevaluation: enableReevaluation, requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers,
                                 gameConfig: gameConfig, stats: landID.landType == "hero-defense" ? heroDefenseStats : nil)
            }
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
                runnerServiceFactory: { ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers)) }
            )
        )

        let visibilityConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: schema.lands[VisibilityTestConfig.landType]?.pathHashes,
            eventHashes: nil,
            clientEventHashes: nil,
            servicesFactory: { _, _ in makeTestLandServices(enableReevaluation: enableReevaluation, requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers) }
        )
        try await nioHost.registerWithGenericReplay(
            landType: VisibilityTestConfig.landType,
            liveLand: visibilityLand,
            liveInitialState: VisibilityTestState(),
            liveWebSocketPath: "/game/\(VisibilityTestConfig.landType)",
            configuration: visibilityConfig,
            reevaluation: ReevaluationFeatureConfiguration(
                enabled: enableReevaluation,
                replayEventPolicy: .projectedOnly,
                runnerServiceFactory: { ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers)) }
            )
        )

        // The resolver test land reads its simulated service's settings once, here.
        let resolverServiceSettings = SimulatedServiceSettings.fromEnvironment()
        // RESOLVER_TEST_TICK_PROBE_PATH: resolver-test's tick gaps, one JSONL line per window.
        let resolverTickRecorder = try TickProbeWriter.startFromEnvironment()
        let resolverConfig = NIOLandServerConfiguration(
            logger: logger,
            allowAutoCreateOnJoin: true,
            transportEncoding: transportEncoding,
            enableLiveStateHashRecording: enableReevaluation,
            pathHashes: schema.lands[ResolverTestConfig.landType]?.pathHashes,
            eventHashes: nil,
            clientEventHashes: nil,
            servicesFactory: { _, _ in
                var services = makeTestLandServices(enableReevaluation: enableReevaluation, requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers)
                services.merge(ResolverTest.makeServices(settings: resolverServiceSettings, tickRecorder: resolverTickRecorder))
                return services
            }
        )
        try await nioHost.registerWithGenericReplay(
            landType: ResolverTestConfig.landType,
            liveLand: resolverLand,
            liveInitialState: ResolverTestState(),
            liveWebSocketPath: "/game/\(ResolverTestConfig.landType)",
            configuration: resolverConfig,
            reevaluation: ReevaluationFeatureConfiguration(
                enabled: enableReevaluation,
                replayEventPolicy: .projectedOnly,
                runnerServiceFactory: { ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredReplayRecordVersion, maxPlayers: maxPlayers)) }
            )
        )

        await nioHost.registerAdminRoutes()
        logger.info("✅ HTTP endpoints available: /health, /schema, /admin/*")

        do {
            // Until SIGINT or SIGTERM, then a graceful shutdown (#351): sessions closed with
            // 1001 after their leave, every land destroyed and its record saved.
            try await nioHost.runUntilShutdownSignal()
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

private func makeGameServices(enableReevaluation: Bool, requiredRecordVersion: String?, maxPlayers: Int,
                              gameConfig: DefaultGameConfigProvider, stats: HeroDefenseStatsRecorder? = nil) -> LandServices {
    var services = LandServices()
    services.register(GameConfigProviderService(provider: gameConfig), as: GameConfigProviderService.self)
    let reevaluationFactory = GameServerReevaluationFactory(requiredRecordVersion: requiredRecordVersion, maxPlayers: maxPlayers,
                                                            gameConfig: gameConfig)
    if let stats {
        services.register(stats, as: HeroDefenseStatsRecorder.self)
    }
    if enableReevaluation {
        services.register(ReevaluationRunnerService(factory: reevaluationFactory), as: ReevaluationRunnerService.self)
        services.register(ReevaluationReplayPolicyService(eventPolicy: .projectedOnly), as: ReevaluationReplayPolicyService.self)
    }
    return services
}

/// Services for the test lands: no game config, the reevaluation services when enabled.
private func makeTestLandServices(enableReevaluation: Bool, requiredRecordVersion: String?, maxPlayers: Int) -> LandServices {
    var services = LandServices()
    if enableReevaluation {
        services.register(ReevaluationRunnerService(factory: GameServerReevaluationFactory(requiredRecordVersion: requiredRecordVersion, maxPlayers: maxPlayers)), as: ReevaluationRunnerService.self)
        services.register(ReevaluationReplayPolicyService(eventPolicy: .projectedOnly), as: ReevaluationReplayPolicyService.self)
    }
    return services
}

private struct GameServerReevaluationFactory: ReevaluationTargetFactory {
    let requiredRecordVersion: String?
    /// The live land's player limit, so replayed joins are admitted the same way.
    let maxPlayers: Int
    /// The live lands' game config (the spawn ramp), so a replay spawns the same way.
    var gameConfig = DefaultGameConfigProvider.fromEnvironment()

    func createRunner(landType: String, recordFilePath: String) async throws -> any ReevaluationRunnerProtocol {
        switch landType {
        case "hero-defense":
            var services = LandServices()
            services.register(
                GameConfigProviderService(provider: gameConfig),
                as: GameConfigProviderService.self
            )

            return try await ConcreteReevaluationRunner(
                definition: HeroDefense.makeLand(maxPlayers: maxPlayers),
                initialState: HeroDefenseState(),
                recordFilePath: recordFilePath,
                requiredRecordVersion: requiredRecordVersion,
                services: services
            )
        case VisibilityTestConfig.landType:
            return try await ConcreteReevaluationRunner(
                definition: VisibilityTest.makeLand(),
                initialState: VisibilityTestState(),
                recordFilePath: recordFilePath,
                requiredRecordVersion: requiredRecordVersion,
                services: LandServices()
            )
        case ResolverTestConfig.landType:
            // Replay applies the recorded resolver outputs and never calls the service.
            return try await ConcreteReevaluationRunner(
                definition: ResolverTest.makeLand(),
                initialState: ResolverTestState(),
                recordFilePath: recordFilePath,
                requiredRecordVersion: requiredRecordVersion,
                services: LandServices()
            )
        default:
            throw ReevaluationError.unknownLandType(landType)
        }
    }
}

// MARK: - Players per land

enum GameServerEnvKeys {
    /// Players a hero-defense land admits (`MaxPlayers`). Default 10.
    static let maxPlayers = "HERO_DEFENSE_MAX_PLAYERS"
}

/// `HERO_DEFENSE_MAX_PLAYERS`, or 10 when unset, invalid, or 0 or below.
func heroDefenseMaxPlayers(environment: [String: String] = ProcessInfo.processInfo.environment) -> Int {
    let value = EnvHelpers.getEnvInt(key: GameServerEnvKeys.maxPlayers, defaultValue: 10, environment: environment)
    return value > 0 ? value : 10
}
