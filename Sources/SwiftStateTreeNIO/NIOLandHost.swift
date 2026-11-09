// Sources/SwiftStateTreeNIO/NIOLandHost.swift
//
// High-level API for hosting Lands with NIO WebSocket transport.

import Foundation
import Logging
import NIOCore
import NIOPosix
import SwiftStateTree
import SwiftStateTreeTransport

// MARK: - Host Middleware (defined here for compilation order)

/// Immutable context passed to middlewares.
public struct HostContext: Sendable {
    public let host: String
    public let port: UInt16
    public let logger: Logger
    public init(host: String, port: UInt16, logger: Logger) {
        self.host = host
        self.port = port
        self.logger = logger
    }
}

/// Middleware that runs at host lifecycle events.
public protocol HostMiddleware: Sendable {
    func onStart(context: HostContext) async throws -> Task<Void, Never>?
    func onShutdown(context: HostContext) async throws
}

/// Builder for collecting host middlewares. Use when configuring NIOLandHost.
public struct HostMiddlewareBuilder: Sendable {
    private var items: [any HostMiddleware] = []

    public init() {}

    public mutating func add(_ middleware: any HostMiddleware) {
        items.append(middleware)
    }

    public func build() -> [any HostMiddleware] {
        items
    }
}

// MARK: - Configuration

/// Configuration for NIOLandHost.
public struct NIOLandHostConfiguration: Sendable {
    /// Host to bind to.
    public var host: String
    /// Port to bind to.
    public var port: UInt16
    /// Logger for server events.
    public var logger: Logger
    /// Number of event loop threads; see `NIOWebSocketServerConfiguration.eventLoopThreads`.
    public var eventLoopThreads: Int
    /// Schema data provider for /schema endpoint.
    public var schemaProvider: (@Sendable () -> Data?)?
    /// Admin API key for admin routes (nil = admin routes disabled).
    public var adminAPIKey: String?
    /// Resolver for replay land WebSocket path in replay-start response. When nil, uses default "/game/{replayLandType}".
    /// Set this to match ReevaluationFeatureConfiguration.replayWebSocketPathResolver when using a custom path.
    public var replayWebSocketPathResolver: (@Sendable (String) -> String)?
    /// Lifecycle middlewares (run at start/shutdown). Order: start runs in order; shutdown runs in reverse.
    public var middlewares: [any HostMiddleware]
    /// Listen backlog for the WebSocket server socket; see `NIOWebSocketServerConfiguration.listenBacklog`.
    /// Defaults to `LISTEN_BACKLOG`, else 4096; 0 or below gives 4096.
    public var listenBacklog: Int
    /// Keepalive pong timeout; see `NIOWebSocketServerConfiguration.pongTimeout`.
    /// Defaults to `WS_PONG_TIMEOUT_MS`, else 20 s. Must be positive and below the 30 s ping interval.
    public var pongTimeout: TimeAmount
    /// Send backlog bound; see `NIOWebSocketServerConfiguration.sendBacklogBound`.
    /// Defaults to `WS_SEND_BACKLOG_MAX_BYTES` / `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`, else 8 MiB / 30 s.
    public var sendBacklogBound: SendBacklogBound
    /// Inbound backlog bound; see `NIOWebSocketServerConfiguration.inboundBacklogBound`.
    /// Defaults to `WS_INBOUND_BACKLOG_MAX_MESSAGES` / `WS_INBOUND_BACKLOG_MAX_BYTES`, else 1024 / 4 MiB.
    public var inboundBacklogBound: InboundBacklogBound
    /// The bound on a shutdown's session closes, leaves and land destroys (#351). Default 8 s,
    /// which ends before `docker stop`'s default 10 s SIGKILL. Under another supervisor, set it
    /// a second or two below its grace period (Kubernetes 30 s, systemd 90 s). Half of it is
    /// always kept for destroying the lands and saving their records. Must be positive.
    ///
    /// The middlewares' `onShutdown` get min(T/4, 2 s) minus stop-accepting's 250 ms minimum: at
    /// 1 s or less they get none (their calls still run, unawaited past it).
    public var shutdownTimeout: Duration

    public init(
        host: String = "localhost",
        port: UInt16 = 8080,
        logger: Logger = Logger(label: "com.swiftstatetree.nio.landhost"),
        eventLoopThreads: Int = NIOWebSocketServerConfiguration.eventLoopThreads(),
        schemaProvider: (@Sendable () -> Data?)? = nil,
        adminAPIKey: String? = nil,
        replayWebSocketPathResolver: (@Sendable (String) -> String)? = nil,
        middlewares: [any HostMiddleware] = [],
        listenBacklog: Int = NIOWebSocketServerConfiguration.listenBacklog(),
        pongTimeout: TimeAmount = NIOWebSocketServerConfiguration.pongTimeout(),
        sendBacklogBound: SendBacklogBound = NIOWebSocketServerConfiguration.sendBacklogBound(),
        inboundBacklogBound: InboundBacklogBound = NIOWebSocketServerConfiguration.inboundBacklogBound(),
        shutdownTimeout: Duration = .seconds(8)
    ) {
        precondition(shutdownTimeout > .zero, "shutdownTimeout must be positive")
        self.shutdownTimeout = shutdownTimeout
        self.sendBacklogBound = sendBacklogBound
        self.inboundBacklogBound = inboundBacklogBound
        precondition(
            NIOWebSocketServerConfiguration.isValidPongTimeout(pongTimeout),
            "pongTimeout must be positive and below the ping interval (\(WebSocketSessionHandler.pingInterval))"
        )
        self.pongTimeout = pongTimeout
        self.host = host
        self.port = port
        self.logger = logger
        self.eventLoopThreads = NIOWebSocketServerConfiguration.normalizedEventLoopThreads(eventLoopThreads)
        self.schemaProvider = schemaProvider
        self.adminAPIKey = adminAPIKey
        self.replayWebSocketPathResolver = replayWebSocketPathResolver
        self.middlewares = middlewares
        self.listenBacklog = NIOWebSocketServerConfiguration.normalizedListenBacklog(listenBacklog)
    }

    /// The WebSocket server configuration this host starts its server with.
    func webSocketServerConfiguration() -> NIOWebSocketServerConfiguration {
        NIOWebSocketServerConfiguration(
            host: host,
            port: Int(port),
            eventLoopThreads: eventLoopThreads,
            logger: logger,
            schemaProvider: schemaProvider,
            listenBacklog: listenBacklog,
            pongTimeout: pongTimeout,
            sendBacklogBound: sendBacklogBound,
            inboundBacklogBound: inboundBacklogBound
        )
    }
}

/// Configuration for a Land registered with NIOLandHost.
///
/// Supports JWT validation during WebSocket handshake.
/// Client must include `token` query parameter: `ws://host:port/path?token=<jwt-token>`
public struct NIOLandServerConfiguration: Sendable {
    /// Logger for land events.
    public var logger: Logger?

    /// JWT configuration (if provided, creates DefaultJWTAuthValidator when jwtValidator is nil).
    public var jwtConfig: JWTConfiguration?
    /// Custom JWT validator (takes precedence over jwtConfig when set).
    public var jwtValidator: JWTAuthValidator?
    /// Whether this land type authenticates players: a JWT validator or configuration is set.
    /// A session without a token is then a guest, and can't name a `playerID` (#209).
    public var authenticatesPlayers: Bool { jwtValidator != nil || jwtConfig != nil }
    /// When true and JWT is enabled: connections without token use createGuestSession; when false, they are rejected.
    public var allowGuestMode: Bool
    /// Factory for guest sessions when allowGuestMode is true and no JWT token is provided.
    public var createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?

    /// Allow auto-creating land when join with instanceId but land doesn't exist (default: false).
    public var allowAutoCreateOnJoin: Bool

    /// Encoding configuration for transport messages and state updates.
    public var transportEncoding: TransportEncodingConfig

    /// The thresholds of sync-lag tracking from client acks (#332), which is always on for a
    /// hosted land: every state frame carries the sync sequence, and a client must declare
    /// `syncSequence` to join. Defaults to the environment (`SyncLagPolicy.fromEnvironment()`);
    /// a value set here replaces it.
    public var syncLag: SyncLagPolicy

    /// `transportEncoding` with `syncSequence`, as the land runs it.
    package var effectiveTransportEncoding: TransportEncodingConfig {
        transportEncoding.withSyncSequence(true)
    }

    /// Path hashes for state update compression (extracted from schema).
    public var pathHashes: [String: UInt32]?

    /// Event hashes for event compression (extracted from schema).
    public var eventHashes: [String: Int]?

    /// Client event hashes for client event compression (extracted from schema).
    public var clientEventHashes: [String: Int]?

    /// Factory for providing LandServices per land instance.
    public var servicesFactory: @Sendable (LandID, [String: String]) -> LandServices

    /// Record live per-tick state hashes into the re-evaluation record (ground truth).
    public var enableLiveStateHashRecording: Bool

    /// Delay each live land's first tick and first sync by a per-land offset in `[0, min(interval, 100 ms))`
    /// (`LandLoopPhase`), so lands created together do not run their loops in phase. Defaults to
    /// on unless `LAND_LOOP_PHASE_OFFSET` is false.
    public var enableLoopPhaseOffset: Bool

    /// Run each live land's sync phase inside its keeper's turns (`InTurnSync`). `false` keeps the
    /// legacy sync path (the transport adapter on its own executor). The `IN_TURN_SYNC` environment
    /// variable can also turn it off; an explicit off in either place wins. Default: on.
    public var inTurnSync: Bool

    /// Suffix appended to base land type to form the replay land type (e.g. "-replay").
    public var replayLandSuffix: String

    /// Resolver for dynamic keeper mode (live vs reevaluation) per land instance.
    /// When non-nil and returns `.reevaluation(recordFilePath)`, LandManager creates a reevaluation LandKeeper.
    public var keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)?

    public init(
        logger: Logger? = nil,
        jwtConfig: JWTConfiguration? = nil,
        jwtValidator: JWTAuthValidator? = nil,
        allowGuestMode: Bool = false,
        allowAutoCreateOnJoin: Bool = false,
        transportEncoding: TransportEncodingConfig = .json,
        enableLiveStateHashRecording: Bool = false,
        replayLandSuffix: String = "-replay",
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        servicesFactory: @Sendable @escaping (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        },
        keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil,
        enableLoopPhaseOffset: Bool = LandLoopPhase.isEnabled(),
        inTurnSync: Bool = true,
        syncLag: SyncLagPolicy = .fromEnvironment()
    ) {
        self.logger = logger
        self.syncLag = syncLag
        self.enableLoopPhaseOffset = enableLoopPhaseOffset
        self.inTurnSync = inTurnSync
        self.jwtConfig = jwtConfig
        self.jwtValidator = jwtValidator
        self.allowGuestMode = allowGuestMode
        self.createGuestSession = createGuestSession
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        self.transportEncoding = transportEncoding
        self.enableLiveStateHashRecording = enableLiveStateHashRecording
        self.replayLandSuffix = replayLandSuffix
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.servicesFactory = servicesFactory
        self.keeperModeResolver = keeperModeResolver
    }
}

// MARK: - NIOLandHost

/// A high-level API for hosting multiple Land types with pure NIO WebSocket.
///
/// Similar to `LandHost` but uses pure SwiftNIO instead of Hummingbird.
/// Supports:
/// - Multiple land types with different State types
/// - LandRealm integration for multi-land management
/// - Admin HTTP routes for management
/// - Health check and schema endpoints
public actor NIOLandHost {
    /// Configuration for this host.
    public let configuration: NIOLandHostConfiguration

    /// The underlying WebSocket server.
    private var server: NIOWebSocketServer?

    /// LandRealm for multi-land type management.
    public let realm: LandRealm

    /// HTTP router for handling non-WebSocket requests.
    public let httpRouter: NIOHTTPRouter

    /// Path to land type mapping.
    private var pathToLandType: [String: String] = [:]
    
    /// Path to transport mapping (each land type can have its own transport).
    private var pathToTransport: [String: WebSocketTransport] = [:]
    
    /// Path to server configuration (for JWT auth resolution per path).
    private var pathToServerConfig: [String: NIOLandServerConfiguration] = [:]

    /// Registered land encodings for logging.
    private var registeredLandEncodings: [String: TransportEncodingConfig] = [:]

    /// Suffix used for replay land types. Updated by registerWithReevaluationSameLand.
    var replayLandSuffix: String = "-replay"

    /// Background tasks from middlewares (cancelled on shutdown).
    private var middlewareTasks: [Task<Void, Never>] = []

    /// Start and stop (#351): a second start joins the first, a stop during a start runs after
    /// it, a second stop joins the first, and a stopped host doesn't start again.
    private var lifecycle = Lifecycle()

    /// `run()` and `runUntilShutdownSignal` waiting for a stop to begin.
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []

    /// Each registered land type's part in a shutdown.
    private var shutdownParticipants: [any HostShutdownParticipant] = []

    /// What the last shutdown did (tests; it is also logged).
    private(set) var lastShutdownSummary: HostShutdownSummary?

    /// Tests: replaces the clock that ends each bounded shutdown step.
    private var shutdownDeadlines: any ShutdownDeadlines = ClockShutdownDeadlines()

    /// Tests: see `shutdownDeadlines`.
    func setShutdownDeadlinesForTesting(_ deadlines: any ShutdownDeadlines) {
        shutdownDeadlines = deadlines
    }

    /// Tests: the WebSocket server, once started.
    var serverForTesting: NIOWebSocketServer? { server }

    /// Tests: each registered land type's shutdown steps (its `NIOLandServer`).
    var shutdownParticipantsForTesting: [any HostShutdownParticipant] { shutdownParticipants }

    /// Tests: the start/stop phase.
    var lifecyclePhaseForTesting: Lifecycle.Phase { lifecycle.phase }

    /// Creates a new NIOLandHost.
    public init(configuration: NIOLandHostConfiguration = .init()) {
        self.configuration = configuration
        self.realm = LandRealm()
        self.httpRouter = NIOHTTPRouter(logger: configuration.logger)
    }

    /// Registers a Land type with this host.
    ///
    /// - Parameters:
    ///   - landType: Unique identifier for this land type.
    ///   - land: The land definition.
    ///   - initialState: Factory for creating initial state.
    ///   - webSocketPath: WebSocket path (e.g., "/game/counter").
    ///   - configuration: Server configuration for this land.
    /// - Throws: `SyncPolicyNestingError` when the state nests a per-player field under a
    ///   broadcast field (#179), or a realm registration error.
    public func register<State: StateNodeProtocol>(
        landType: String,
        land: LandDefinition<State>,
        initialState: @autoclosure @escaping @Sendable () -> State,
        webSocketPath: String,
        configuration: NIOLandServerConfiguration
    ) async throws {
        // A per-player field under a broadcast field can't reach its player in diffs (#179).
        try SyncPolicyNesting.validate(State.self)

        let initialStateFunc = initialState

        // Create transport for this land type
        let transport = WebSocketTransport()
        
        // Create NIOLandServer
        let server = try NIOLandServer<State>(
            landType: landType,
            landFactory: { _ in land },
            initialStateFactory: { _ in initialStateFunc() },
            configuration: configuration,
            transport: transport
        )
        
        // Set router as transport delegate
        await transport.setDelegate(server.landRouter)
        
        // Register with realm
        try await realm.register(landType: landType, server: server)
        shutdownParticipants.append(server)

        // Store path mappings
        pathToLandType[webSocketPath] = landType
        pathToTransport[webSocketPath] = transport
        pathToServerConfig[webSocketPath] = configuration
        registeredLandEncodings[landType] = configuration.effectiveTransportEncoding

        self.configuration.logger.info(
            "Registered land type",
            metadata: [
                "landType": .string(landType),
                "path": .string(webSocketPath),
                "encoding": .string(String(describing: configuration.effectiveTransportEncoding)),
            ]
        )
    }
    
    /// Registers admin routes if API key is configured.
    public func registerAdminRoutes() async {
        guard let apiKey = configuration.adminAPIKey else {
            configuration.logger.info("Admin routes disabled (no adminAPIKey configured)")
            return
        }
        
        let adminAuth = NIOAdminAuth(apiKey: apiKey, logger: configuration.logger)
        let adminRoutes = NIOAdminRoutes(
            landRealm: realm,
            adminAuth: adminAuth,
            logger: configuration.logger,
            replayWebSocketPathResolver: configuration.replayWebSocketPathResolver,
            replayLandSuffix: replayLandSuffix
        )
        
        await adminRoutes.registerRoutes(on: httpRouter)
        configuration.logger.info("Admin routes registered at /admin/*")
    }
    
    /// Registers default HTTP routes (health, schema).
    private func registerDefaultRoutes() async {
        // Health check
        await httpRouter.get("/health") { _ in
            NIOHTTPResponse.text("OK")
        }
        
        // Schema endpoint
        if let schemaProvider = configuration.schemaProvider {
            await httpRouter.get("/schema") { _ in
                guard let schemaData = schemaProvider() else {
                    return NIOHTTPResponse.text("Schema not available", status: .notFound)
                }
                return NIOHTTPResponse.json(data: schemaData).withCORS()
            }
            
            await httpRouter.options("/schema") { _ in
                NIOHTTPResponse.noContent().withCORS(maxAge: "86400")
            }
        }
    }

    /// Starts the server and runs until it is shut down: by `shutdown()`, or by cancelling the
    /// task that runs this. Returns once the shutdown finished (#351). On a host already shut
    /// down (including by a `shutdown()` before any start), it logs and returns without serving.
    public func run() async throws {
        try await start()
        await withTaskCancellationHandler {
            await waitForStop()
        } onCancel: {
            Task { try? await self.shutdown() }
        }
        // Joins the stop in flight, or returns at once when it already finished.
        try await shutdown()
    }

    /// Starts the server, waits for the first of `signals` (or a `shutdown()` from elsewhere),
    /// shuts down, writes the profiler's last window, and returns: the process-level entry for
    /// a server's `main` (#351).
    ///
    /// It calls `ProcessSignals.shutdownSignals(signals)`, so a second signal ends the process
    /// at once with `128 + signal`.
    public func runUntilShutdownSignal(_ signals: [Int32] = [SIGINT, SIGTERM]) async throws {
        let stream = ProcessSignals.shutdownSignals(signals)
        try await start()
        let logger = configuration.logger
        let watcher = Task { [weak self] in
            for await signal in stream {
                logger.info("Shutdown signal received", metadata: ["signal": .stringConvertible(signal)])
                try? await self?.shutdown()
                return
            }
        }
        await waitForStop()
        try await shutdown()
        watcher.cancel()
        // The process-wide profiler: once, here, not in `shutdown()` (a process can run several
        // hosts; only its entry knows it is ending).
        await TransportProfilingActor.sharedIfStarted?.flushFinalWindow()
    }

    /// Starts the server: routes, middlewares, the listener. A second call joins a start in
    /// flight or returns when running; on a host already shut down it logs and returns without
    /// serving.
    func start() async throws {
        switch lifecycle.beginStart({ Task { try await self.performStart() } }) {
        case .run(let task, let token):
            let result = await task.result
            lifecycle.finishStart(token, succeeded: (try? result.get()) != nil)
            try result.get()
        case .join(let task):
            try await task.value
        case .alreadyRunning:
            return
        case .stopped:
            // A host is started once: after `shutdown()` (even one before any start), a start
            // doesn't serve. Logged, not thrown, so `run()` just returns.
            configuration.logger.warning("NIOLandHost was shut down; it isn't started again")
        }
    }

    /// Returns once a stop has begun.
    private func waitForStop() async {
        if lifecycle.phase == .stopping || lifecycle.phase == .stopped { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            stopWaiters.append(continuation)
        }
    }

    private func resumeStopWaiters() {
        let waiters = stopWaiters
        stopWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func performStart() async throws {
        guard !pathToLandType.isEmpty else {
            throw NIOLandHostError.noLandsRegistered
        }
        
        // Register default HTTP routes
        await registerDefaultRoutes()
        
        // Register admin routes if configured
        await registerAdminRoutes()

        // Run middleware onStart pipeline
        let context = HostContext(
            host: configuration.host,
            port: configuration.port,
            logger: configuration.logger
        )
        for middleware in configuration.middlewares {
            if let task = try await middleware.onStart(context: context) {
                middlewareTasks.append(task)
            }
        }

        // Create path matcher, transport resolver, and optional JWT auth resolver
        // Supports both exact paths (/game/hero-defense) and path-with-instanceId (/game/hero-defense/room-abc)
        // for K8s path-based routing: Ingress can route /game/{landType}/{instanceId} to specific pods
        let paths = pathToLandType
        let transports = pathToTransport
        let configs = pathToServerConfig

        /// Resolve request path to base path (registered webSocketPath).
        /// Matches exact path or prefix: /game/hero-defense/room-abc -> /game/hero-defense
        let resolveBasePath: @Sendable (String) -> String? = { path in
            let cleanPath = path.components(separatedBy: "?").first ?? path
            if paths.keys.contains(cleanPath) { return cleanPath }
            // Longest-prefix match: /game/hero-defense/room-abc matches /game/hero-defense
            let sorted = paths.keys.sorted { $0.count > $1.count }
            return sorted.first { key in
                cleanPath.hasPrefix(key + "/") && cleanPath.count > key.count
            }
        }

        let pathMatcher: @Sendable (String) -> Bool = { path in
            resolveBasePath(path) != nil
        }

        let transportResolver: @Sendable (String) -> WebSocketTransport? = { path in
            guard let basePath = resolveBasePath(path) else { return nil }
            return transports[basePath]
        }

        func makeAuthResolver(_ configs: [String: NIOLandServerConfiguration]) -> some AuthInfoResolverProtocol {
            ClosureAuthInfoResolver { (path: String, uri: String) async throws -> AuthenticatedInfo? in
                guard let basePath = resolveBasePath(path) else { return nil }
                guard let config = configs[basePath] else { return nil }
                let validator = config.jwtValidator
                    ?? config.jwtConfig.map { DefaultJWTAuthValidator(config: $0, logger: config.logger) }
                guard let validator = validator else { return nil }
                let token = extractTokenFromURI(uri)
                if let token = token {
                    return try await validator.validate(token: token)
                }
                if config.allowGuestMode { return nil }
                throw JWTValidationError.custom("Missing token; JWT required and guest mode disabled")
            }
        }
        let authInfoResolver: (any AuthInfoResolverProtocol)? = configs.isEmpty ? nil : makeAuthResolver(configs)

        // Create and start server with HTTP router
        let serverConfig = configuration.webSocketServerConfiguration()

        let server = NIOWebSocketServer(
            configuration: serverConfig,
            transportResolver: transportResolver,
            pathMatcher: pathMatcher,
            httpRouter: httpRouter,
            authInfoResolver: authInfoResolver
        )
        self.server = server

        do {
            try await server.start()
        } catch {
            // Cancel middleware tasks and run onShutdown when startup fails (e.g. port conflict).
            // Otherwise provisioning heartbeats keep running and register a server that never came up.
            // If first heartbeat already ran, we must deregister via onShutdown.
            let tasks = middlewareTasks
            middlewareTasks = []
            for task in tasks {
                task.cancel()
                _ = await task.value
            }
            let context = HostContext(
                host: configuration.host,
                port: configuration.port,
                logger: configuration.logger
            )
            for middleware in configuration.middlewares.reversed() {
                try? await middleware.onShutdown(context: context)
            }
            throw error
        }

        // Log startup info
        let endpointInfo = pathToLandType.map { path, landType in
            let encoding = registeredLandEncodings[landType] ?? .json
            return "\(path) → \(landType) [\(encoding)]"
        }.joined(separator: ", ")
        
        configuration.logger.info(
            "🚀 NIO WebSocket server running",
            metadata: [
                "host": .string(configuration.host),
                "port": .stringConvertible(configuration.port),
                "endpoints": .string(endpointInfo),
                "adminRoutes": .string(configuration.adminAPIKey != nil ? "enabled" : "disabled"),
            ]
        )

    }

    /// Shuts the host down, each step bounded by `shutdownTimeout` (#351):
    ///
    /// 1. **Deregister**: middleware tasks cancelled, `onShutdown` run in reverse order.
    /// 2. **Stop accepting**: joins, new connections and land creations refused; listener closed.
    /// 3. **Close the sessions** with 1001 Going Away, each joined one after its leave ran
    ///    through its land's queue (OnLeave and its resolvers). Leaves still queued at the
    ///    deadline are cut when their land's destruction starts.
    /// 4. **Destroy the lands** through the normal path: destroy handlers, the save on destroy,
    ///    `onLandDestroyed`. Half of `shutdownTimeout` is always kept for this step. A land whose
    ///    destroy is still running at the deadline is abandoned, not cancelled.
    /// 5. The abandoned lands' session tickets are ended.
    /// 6. The transports and the WebSocket server stop; from here, late work is dropped by the
    ///    server's stop fence instead of reaching a shut-down event loop.
    /// 7. One summary line is logged.
    ///
    /// Every step runs whatever the earlier ones did; errors are logged in the summary. A second
    /// call joins the shutdown in flight; a call after it, or before any start, returns at once.
    /// Calling it from inside the shutdown (an `onShutdown` or a destroy handler) joins the
    /// shutdown that runs that code, so it returns only when that step's deadline passes: don't.
    /// It doesn't throw for a failed step (it stays `throws` for source compatibility).
    public func shutdown() async throws {
        switch lifecycle.beginStop({ start in Task { await self.performShutdown(after: start) } }) {
        case .run(let task, let token):
            resumeStopWaiters()
            await task.value
            lifecycle.finishStop(token)
        case .join(let task):
            await task.value
        case .nothingToStop:
            resumeStopWaiters()
        }
    }

    private func performShutdown(after start: Task<Void, Error>?) async {
        // A stop during a start runs after it.
        _ = await start?.result
        let began = ContinuousClock.now
        let budget = ShutdownBudget(total: configuration.shutdownTimeout, start: began)
        let deadlines = shutdownDeadlines
        let errors = ShutdownErrors()
        var summary = HostShutdownSummary()
        let logger = configuration.logger
        logger.info("Shutting down", metadata: ["timeout": .string("\(configuration.shutdownTimeout)")])

        // 1. Deregister.
        let tasks = middlewareTasks
        middlewareTasks = []
        let middlewares = configuration.middlewares
        let context = HostContext(host: configuration.host, port: configuration.port, logger: logger)
        let deregisterDeadline = budget.deregisterDeadline
        let deregistered = await BoundedWait.run(until: { await deadlines.expire(.deregister, at: deregisterDeadline) }) {
            // Cancelled and awaited, so an in-flight call (a heartbeat) can't re-register a
            // server that is going away.
            for task in tasks {
                task.cancel()
                _ = await task.value
            }
            for middleware in middlewares.reversed() {
                do {
                    try await middleware.onShutdown(context: context)
                } catch {
                    errors.append("onShutdown of \(type(of: middleware)): \(error)")
                }
            }
        }
        if !deregistered { summary.timedOutSteps.append(.deregister) }

        // 2. Stop accepting.
        let participants = shutdownParticipants
        let server = self.server
        let stopAcceptingDeadline = budget.stopAcceptingDeadline(startedAt: .now)
        let stopped = await BoundedWait.run(until: { await deadlines.expire(.stopAccepting, at: stopAcceptingDeadline) }) {
            for participant in participants { await participant.stopAccepting() }
            await server?.stopAccepting()
        }
        if !stopped { summary.timedOutSteps.append(.stopAccepting) }

        // 3. Close the sessions, awaiting their leaves.
        let leaves = ShutdownLeaveProgress()
        let leavesDeadline = budget.leavesDeadline
        let left = await BoundedWait.run(until: { await deadlines.expire(.leaves, at: leavesDeadline) }) {
            await withTaskGroup(of: Void.self) { group in
                for participant in participants {
                    group.addTask { await participant.closeSessionsForShutdown(progress: leaves) }
                }
            }
        }
        if !left { summary.timedOutSteps.append(.leaves) }

        // 4. Destroy the lands. Leaves still queued are rejected from each land's drain on.
        let lands = ShutdownLandProgress()
        let destroyDeadline = budget.destroyDeadline(startedAt: .now)
        let destroyed = await BoundedWait.run(until: { await deadlines.expire(.destroy, at: destroyDeadline) }) {
            await withTaskGroup(of: Void.self) { group in
                for participant in participants {
                    group.addTask { await participant.destroyLandsForShutdown(progress: lands) }
                }
            }
        }
        if !destroyed { summary.timedOutSteps.append(.destroy) }
        summary.landsDestroyed = lands.finishedCount
        let abandoned = lands.unfinished
        summary.landsAbandoned = abandoned.sorted { $0.stringValue < $1.stringValue }

        // 5. End the abandoned lands' sessions (a fixed bound: the adapters are not the ones
        // hanging, but nothing here may hold the shutdown).
        if !abandoned.isEmpty {
            let ended = EndedCount()
            _ = await BoundedWait.run(until: { try? await safeTaskSleep(for: .seconds(1)) }) {
                for participant in participants {
                    ended.add(await participant.endSessions(ofAbandoned: abandoned))
                }
            }
            summary.abandonedSessionsEnded = ended.value
        }

        // 6. Stop the transports, then the server behind its stop fence.
        _ = await BoundedWait.run(until: { try? await safeTaskSleep(for: .seconds(1)) }) {
            for participant in participants { await participant.stopTransport() }
        }
        if let server {
            do {
                try await server.shutdown()
            } catch {
                errors.append("WebSocket server shutdown: \(error)")
            }
            summary.fenceDropped = await server.stopFenceDropped
        }
        self.server = nil

        // 7. Summary. The leaves are read now, not at step 3's deadline: an abandoned leave that
        // finished during the destroy step counts as finished.
        summary.leaves = leaves.snapshot
        summary.errors = errors.all
        summary.elapsed = ContinuousClock.now - began
        lastShutdownSummary = summary
        let leavesSummary = summary.leaves
        logger.info("Shutdown finished", metadata: [
            "elapsed": .string("\(summary.elapsed)"),
            // Close hand-offs to the transport, not flushed close frames.
            "sessionClosesIssued": .stringConvertible(leavesSummary.sessionsClosed),
            // Leaves that ran through their land's queue, applied or rejected by its drain.
            "leavesFinished": .stringConvertible(leavesSummary.leavesFinished),
            "leavesUnfinished": .stringConvertible(leavesSummary.leavesCut),
            "landsDestroyed": .stringConvertible(summary.landsDestroyed),
            "landsAbandoned": .stringConvertible(summary.landsAbandoned.count),
            "abandonedSessionsEnded": .stringConvertible(summary.abandonedSessionsEnded),
            "fenceDropped": .stringConvertible(summary.fenceDropped),
            "timedOutSteps": .string(summary.timedOutSteps.map(\.rawValue).joined(separator: ",")),
            "errors": .stringConvertible(summary.errors.count),
        ])
        for landID in summary.landsAbandoned {
            logger.warning("Land destroy abandoned at the shutdown deadline: its record was not saved", metadata: [
                "landID": .string(landID.stringValue),
            ])
        }
        if leavesSummary.leavesCut > 0 {
            logger.warning("Leaves unfinished when the shutdown ended: their OnLeave may not have run", metadata: [
                "leavesUnfinished": .stringConvertible(leavesSummary.leavesCut),
            ])
        }
        for error in summary.errors {
            logger.error("Shutdown step failed", metadata: ["error": .string(error)])
        }
    }
}

/// A count bumped from a bounded step's task.
private final class EndedCount: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func add(_ n: Int) { lock.lock(); count += n; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

// MARK: - Errors

/// Errors that can occur with NIOLandHost.
public enum NIOLandHostError: Error, Sendable {
    /// No lands have been registered.
    case noLandsRegistered
}
