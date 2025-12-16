import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeMatchmaking
import Logging
import NIOCore

/// Bundles runtime, transport, and Hummingbird hosting for any Land definition.
///
/// **Note**: This is the Hummingbird-specific implementation of `LandServerProtocol`.
/// For framework-agnostic usage, use the `LandServerProtocol` protocol.
///
/// **Migration Note**: `AppContainer<State>` is an alias for `LandServer<State>`.
/// New code should use `LandServer<State>` directly.
public struct LandServer<State: StateNodeProtocol> {
    public typealias Land = LandDefinition<State>
    
    public struct Configuration: Sendable {
        public var host: String
        public var port: UInt16
        public var webSocketPath: String
        public var healthPath: String
        public var enableHealthRoute: Bool
        public var logStartupBanner: Bool
        public var logger: Logger?
        
        // JWT validation configuration
        /// JWT configuration (if provided, will create DefaultJWTAuthValidator)
        /// When set, JWT validation will be performed during WebSocket handshake.
        /// Client must include `token` query parameter in the WebSocket URL: `ws://host:port/path?token=<jwt-token>`
        public var jwtConfig: JWTConfiguration?
        /// Custom JWT validator (if provided, takes precedence over jwtConfig)
        /// When set, JWT validation will be performed during WebSocket handshake.
        /// Client must include `token` query parameter in the WebSocket URL: `ws://host:port/path?token=<jwt-token>`
        public var jwtValidator: JWTAuthValidator?
        
        /// Enable guest mode (allow connections without JWT token)
        /// When enabled and JWT validation is enabled:
        /// - Connections with valid JWT token: use JWT payload for PlayerSession
        /// - Connections without JWT token: use createGuestSession closure
        /// When disabled and JWT validation is enabled:
        /// - All connections must have valid JWT token (connections without token will be rejected)
        public var allowGuestMode: Bool = false
        
        // Admin API configuration
        /// Enable admin API routes (default: false)
        public var enableAdminRoutes: Bool = false
        /// Admin authentication middleware (required if enableAdminRoutes is true)
        public var adminAuth: AdminAuthMiddleware?
        
        public init(
            host: String = "localhost",
            port: UInt16 = 8080,
            webSocketPath: String = "/game",
            healthPath: String = "/health",
            enableHealthRoute: Bool = true,
            logStartupBanner: Bool = true,
            logger: Logger? = nil,
            jwtConfig: JWTConfiguration? = nil,
            jwtValidator: JWTAuthValidator? = nil,
            allowGuestMode: Bool = false,
            enableAdminRoutes: Bool = false,
            adminAuth: AdminAuthMiddleware? = nil
        ) {
            self.host = host
            self.port = port
            self.webSocketPath = webSocketPath
            self.healthPath = healthPath
            self.enableHealthRoute = enableHealthRoute
            self.logStartupBanner = logStartupBanner
            self.logger = logger
            self.jwtConfig = jwtConfig
            self.jwtValidator = jwtValidator
            self.allowGuestMode = allowGuestMode
            self.enableAdminRoutes = enableAdminRoutes
            self.adminAuth = adminAuth
        }
    }
    
    public struct LandServerForTest {
        public let land: Land
        public let keeper: LandKeeper<State>
        public let transport: WebSocketTransport
        public let transportAdapter: TransportAdapter<State>
        fileprivate let adapterHolder: TransportAdapterHolder<State>
        
        public func connect(
            sessionID: SessionID,
            using connection: any WebSocketConnection
        ) async {
            await transport.handleConnection(sessionID: sessionID, connection: connection)
        }
        
        public func disconnect(sessionID: SessionID) async {
            await transport.handleDisconnection(sessionID: sessionID)
        }
        
        public func send(_ data: Data, from sessionID: SessionID) async {
            await transport.handleIncomingMessage(sessionID: sessionID, data: data)
        }
        
        fileprivate init(
            land: Land,
            keeper: LandKeeper<State>,
            transport: WebSocketTransport,
            transportAdapter: TransportAdapter<State>,
            adapterHolder: TransportAdapterHolder<State>
        ) {
            self.land = land
            self.keeper = keeper
            self.transport = transport
            self.transportAdapter = transportAdapter
            self.adapterHolder = adapterHolder
        }
    }
    
    public let configuration: Configuration
    public let land: Land?
    public let keeper: LandKeeper<State>?
    public let transport: WebSocketTransport?
    public let transportAdapter: TransportAdapter<State>?
    public let hbAdapter: HummingbirdStateTreeAdapter?
    public let landRouter: LandRouter<State>?
    public let router: Router<BasicWebSocketRequestContext>
    
    // Multi-room mode
    public let landManager: LandManager<State>?
    // MatchmakingService is generic and must be created by the user with proper Registry and LandTypeRegistry
    // For type safety, we don't store it here - users should manage it separately if needed
    
    private let adapterHolder: TransportAdapterHolder<State>?
    
    /// Get a lobby by landID and wrap it as LobbyContainer.
    ///
    /// Note: This requires MatchmakingService and LandTypeRegistry to be provided.
    /// Users should create LobbyContainer directly if they have these dependencies.
    ///
    /// - Parameters:
    ///   - landID: The lobby landID (e.g., "lobby-asia").
    ///   - matchmakingService: The matchmaking service instance.
    ///   - landManagerRegistry: The land manager registry.
    ///   - landTypeRegistry: The land type registry.
    /// - Returns: LobbyContainer if the lobby exists, nil otherwise.
    public func getLobby<Registry: LandManagerRegistry>(
        landID: LandID,
        matchmakingService: MatchmakingService<State, Registry>,
        landManagerRegistry: Registry,
        landTypeRegistry: LandTypeRegistry<State>
    ) async -> LobbyContainer<State, Registry>? where Registry.State == State {
        guard let landManager = landManager else {
            return nil
        }
        
        guard let container = await landManager.getLobby(landID: landID) else {
            return nil
        }
        
        return LobbyContainer(
            container: container,
            matchmakingService: matchmakingService,
            landManagerRegistry: landManagerRegistry,
            landTypeRegistry: landTypeRegistry
        )
    }
    
    // Private initializer for single-room mode
    private init(
        configuration: Configuration,
        land: Land,
        keeper: LandKeeper<State>,
        transport: WebSocketTransport,
        transportAdapter: TransportAdapter<State>,
        hbAdapter: HummingbirdStateTreeAdapter,
        router: Router<BasicWebSocketRequestContext>,
        landManager: LandManager<State>?,
        adapterHolder: TransportAdapterHolder<State>
    ) {
        self.configuration = configuration
        self.land = land
        self.keeper = keeper
        self.transport = transport
        self.transportAdapter = transportAdapter
        self.hbAdapter = hbAdapter
        self.landRouter = nil
        self.router = router
        self.landManager = landManager
        self.adapterHolder = adapterHolder
    }
    
    // Private initializer for multi-room mode
    private init(
        configuration: Configuration,
        router: Router<BasicWebSocketRequestContext>,
        landManager: LandManager<State>,
        transport: WebSocketTransport? = nil,
        hbAdapter: HummingbirdStateTreeAdapter? = nil,
        landRouter: LandRouter<State>? = nil
    ) {
        self.configuration = configuration
        self.land = nil
        self.keeper = nil
        self.transport = transport
        self.transportAdapter = nil
        self.hbAdapter = hbAdapter
        self.landRouter = landRouter
        self.router = router
        self.landManager = landManager
        self.adapterHolder = nil
    }
    
    public func run() async throws {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandServer"
        )

        let httpConfiguration = ApplicationConfiguration(
            address: .hostname(configuration.host, port: Int(configuration.port))
        )
        
        let app = Application(
            router: router,
            server: .http1WebSocketUpgrade(
                webSocketRouter: router
            ),
            configuration: httpConfiguration,
            logger: logger
        )
        
        if configuration.logStartupBanner {
            let baseURL = "http://\(configuration.host):\(configuration.port)"
            let wsURL = "ws://\(configuration.host):\(configuration.port)\(configuration.webSocketPath)"
            logger.info("🚀 SwiftStateTree Hummingbird server started at \(baseURL)")
            logger.info("📡 WebSocket endpoint: \(wsURL)")
            if configuration.enableHealthRoute {
                logger.info("❤️  Health check: \(baseURL)\(configuration.healthPath)")
            }
        }
        
        try await app.runService()
    }
    
    /// Assemble a multi-room server with Hummingbird hosting.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - lobbyIDs: Optional array of lobby landIDs to pre-create (e.g., ["lobby-asia", "lobby-europe"]).
    ///   - configureRouter: Optional router configuration closure
    public static func makeMultiRoomServer(
        configuration: Configuration = Configuration(),
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        lobbyIDs: [String] = [],
        configureRouter: ((Router<BasicWebSocketRequestContext>) -> Void)? = nil
    ) async throws -> LandServer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandServer"
        )
        
        // Create JWT validator if configured
        let jwtValidator: JWTAuthValidator? = {
            if let customValidator = configuration.jwtValidator {
                return customValidator
            } else if let jwtConfig = configuration.jwtConfig {
                return DefaultJWTAuthValidator(config: jwtConfig, logger: logger)
            }
            return nil
        }()
        
        // Create global WebSocketTransport
        // Since we are using LandRouter, all connections go through this single transport
        let transport = WebSocketTransport(logger: logger)
        
        // Create LandManager (must share the same transport so per-land adapters can send snapshots/updates)
        let landManager = LandManager<State>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            transport: transport,
            createGuestSession: createGuestSession,
            logger: logger
        )
        
        // Pre-create lobbies if specified
        for lobbyIDString in lobbyIDs {
            let lobbyID = LandID(lobbyIDString)
            let definition = landFactory(lobbyID)
            let initialState = initialStateFactory(lobbyID)
            _ = await landManager.getOrCreateLand(
                landID: lobbyID,
                definition: definition,
                initialState: initialState
            )
            logger.info("Pre-created lobby: \(lobbyIDString)")
        }
        
        // Create adapter for LandTypeRegistry
        // Note: landFactory here expects LandID which needs the 'type' embedded if we pass it directly
        let landTypeRegistry = LandTypeRegistry<State>(
            landFactory: { _, landID in landFactory(landID) },
            initialStateFactory: { _, landID in initialStateFactory(landID) }
        )
        
        // Create LandRouter using the global transport
        let landRouter = LandRouter<State>(
            landManager: landManager,
            landTypeRegistry: landTypeRegistry,
            transport: transport,
            createGuestSession: createGuestSession,
            logger: logger
        )
        
        // Set LandRouter as the delegate for the transport to handle events
        await transport.setDelegate(landRouter)
        
        // Create Hummingbird Adapter that feeds the global transport
        let hbAdapter = HummingbirdStateTreeAdapter(
            transport: transport,
            jwtValidator: jwtValidator,
            allowGuestMode: configuration.allowGuestMode,
            logger: logger
        )
        
        let router = Router(context: BasicWebSocketRequestContext.self)
        
        // Generate schema from a sample land definition
        // Use a dummy LandID to create a sample definition for schema extraction
        let sampleLandID = LandID.generate(landType: "sample")
        let sampleDefinition = landFactory(sampleLandID)
        let schemaDataResult: Result<Data, Error> = {
            do {
                let anyLand = AnyLandDefinition(sampleDefinition)
                let schema = anyLand.extractSchema()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(schema)
                return .success(jsonData)
            } catch {
                return .failure(error)
            }
        }()
        
        @Sendable
        func addCORSHeaders(_ response: inout Response) {
            response.headers[.accessControlAllowOrigin] = "*"
            response.headers[.accessControlAllowMethods] = "GET, OPTIONS"
            response.headers[.accessControlAllowHeaders] = "Content-Type"
        }
        
        // Generic WebSocket route
        // All Join logic is now handled by sending a Join message after connection
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
        
        // Add schema endpoint with CORS support
        router.on(RouterPath("/schema"), method: .options) { _, _ in
            var response = Response(status: .noContent)
            addCORSHeaders(&response)
            return response
        }
        
        router.get(RouterPath("/schema")) { _, _ in
            switch schemaDataResult {
            case let .success(schemaData):
                var buffer = ByteBufferAllocator().buffer(capacity: schemaData.count)
                buffer.writeBytes(schemaData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                response.headers[.cacheControl] = "public, max-age=3600"
                addCORSHeaders(&response)
                return response
            case let .failure(error):
                logger.error("Failed to generate schema at startup: \(error)")
                let errorMsg = "Failed to generate schema: \(error)"
                var buffer = ByteBufferAllocator().buffer(capacity: errorMsg.utf8.count)
                buffer.writeString(errorMsg)
                var response = Response(status: .internalServerError, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "text/plain"
                addCORSHeaders(&response)
                return response
            }
        }
        
        // Register admin routes if enabled
        if configuration.enableAdminRoutes, let adminAuth = configuration.adminAuth {
            let adminRoutes = AdminRoutes<State>(
                landManager: landManager,
                adminAuth: adminAuth,
                logger: logger
            )
            adminRoutes.registerRoutes(on: router)
        }
        
        configureRouter?(router)
        
        return LandServer(
            configuration: configuration,
            router: router,
            landManager: landManager,
            transport: transport,
            hbAdapter: hbAdapter,
            landRouter: landRouter
        )
    }
    
    /// Assemble a runnable server with Hummingbird hosting.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - land: The Land definition
    ///   - initialState: Initial state for the Land
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    ///                          Only used when `allowGuestMode` is true and JWT validation is enabled.
    ///                          Default creates guest session with "guest-{randomID}" as playerID.
    ///   - configureRouter: Optional router configuration closure
    public static func makeServer(
        configuration: Configuration = Configuration(),
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        configureRouter: ((Router<BasicWebSocketRequestContext>) -> Void)? = nil
    ) async throws -> LandServer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandServer"
        )
        // Create JWT validator if configured
        let jwtValidator: JWTAuthValidator? = {
            if let customValidator = configuration.jwtValidator {
                return customValidator
            } else if let jwtConfig = configuration.jwtConfig {
                return DefaultJWTAuthValidator(config: jwtConfig, logger: logger)
            }
            return nil
        }()
        
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createGuestSession: createGuestSession,
            logger: logger
        )
        
        let hbAdapter = HummingbirdStateTreeAdapter(
            transport: core.transport,
            jwtValidator: jwtValidator,
            allowGuestMode: configuration.allowGuestMode,
            logger: logger
        )
        let router = Router(context: BasicWebSocketRequestContext.self)
        let schemaDataResult: Result<Data, Error> = {
            do {
                let anyLand = AnyLandDefinition(definition)
                let schema = anyLand.extractSchema()
                let encoder = JSONEncoder()
                encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                let jsonData = try encoder.encode(schema)
                return .success(jsonData)
            } catch {
                return .failure(error)
            }
        }()
        @Sendable
        func addCORSHeaders(_ response: inout Response) {
            response.headers[.accessControlAllowOrigin] = "*"
            response.headers[.accessControlAllowMethods] = "GET, OPTIONS"
            response.headers[.accessControlAllowHeaders] = "Content-Type"
        }
        
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
        
        // Add schema endpoint with CORS support
        router.on(RouterPath("/schema"), method: .options) { _, _ in
            var response = Response(status: .noContent)
            addCORSHeaders(&response)
            return response
        }
        
        router.get(RouterPath("/schema")) { _, _ in
            switch schemaDataResult {
            case let .success(schemaData):
                var buffer = ByteBufferAllocator().buffer(capacity: schemaData.count)
                buffer.writeBytes(schemaData)
                var response = Response(status: .ok, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "application/json"
                response.headers[.cacheControl] = "public, max-age=3600"
                addCORSHeaders(&response)
                return response
            case let .failure(error):
                logger.error("Failed to generate schema at startup: \(error)")
                let errorMsg = "Failed to generate schema: \(error)"
                var buffer = ByteBufferAllocator().buffer(capacity: errorMsg.utf8.count)
                buffer.writeString(errorMsg)
                var response = Response(status: .internalServerError, body: .init(byteBuffer: buffer))
                response.headers[.contentType] = "text/plain"
                addCORSHeaders(&response)
                return response
            }
        }
        
        configureRouter?(router)
        
        return LandServer(
            configuration: configuration,
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            hbAdapter: hbAdapter,
            router: router,
            landManager: nil,
            adapterHolder: core.adapterHolder
        )
    }
    
    public static func makeForTest(
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger? = nil
    ) async -> LandServerForTest {
        let testLogger = logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.test",
            scope: "Test"
        )
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createGuestSession: createGuestSession,
            logger: testLogger
        )
        
        return LandServerForTest(
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            adapterHolder: core.adapterHolder
        )
    }
    
    private struct CoreComponents {
        let land: Land
        let keeper: LandKeeper<State>
        let transport: WebSocketTransport
        let transportAdapter: TransportAdapter<State>
        let adapterHolder: TransportAdapterHolder<State>
    }
    
    private static func buildCoreComponents(
        land definition: Land,
        initialState: State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        logger: Logger
    ) async -> CoreComponents {
        let transport = WebSocketTransport(logger: logger)
        let adapterHolder = TransportAdapterHolder<State>()
        
        // Create keeper first (without transport)
        let keeper = LandKeeper<State>(
            definition: definition,
            initialState: initialState,
            logger: logger
        )
        
        // Create TransportAdapter with keeper
        let transportAdapter = TransportAdapter<State>(
            keeper: keeper,
            transport: transport,
            landID: definition.id,
            createGuestSession: createGuestSession,
            enableLegacyJoin: true,
            logger: logger
        )
        
        // Set transport adapter as the transport for keeper
        await keeper.setTransport(transportAdapter)
        
        await adapterHolder.set(transportAdapter)
        await transport.setDelegate(transportAdapter)
        
        return CoreComponents(
            land: definition,
            keeper: keeper,
            transport: transport,
            transportAdapter: transportAdapter,
            adapterHolder: adapterHolder
        )
    }
}

private actor TransportAdapterHolder<State: StateNodeProtocol> {
    private var adapter: TransportAdapter<State>?
    
    func set(_ adapter: TransportAdapter<State>) {
        self.adapter = adapter
    }
    
    func forwardSendEvent(
        _ event: AnyServerEvent,
        to target: SwiftStateTree.EventTarget
    ) async {
        await adapter?.sendEvent(event, to: target)
    }
    
    func forwardSyncNow() async {
        await adapter?.syncNow()
    }
    
    func forwardSyncBroadcastOnly() async {
        await adapter?.syncBroadcastOnly()
    }
}

// MARK: - Type Aliases

/// AppContainer is an alias for LandServer (migration in progress).
///
/// **Migration Note**: 
/// - Phase 1 (current): `AppContainer<State>` is an alias for `LandServer<State>`
/// - Phase 2 (future): `AppContainer` will be marked as deprecated
/// - Phase 3 (future): `AppContainer` will be removed
///
/// **Recommendation**: New code should use `LandServer<State>` directly.
public typealias AppContainer<State: StateNodeProtocol> = LandServer<State>

/// AppContainerForTest is an alias for LandServerForTest (migration in progress).
///
/// **Migration Note**: 
/// - Phase 1 (current): `AppContainerForTest<State>` is an alias for `LandServer<State>.LandServerForTest`
/// - Phase 2 (future): `AppContainerForTest` will be marked as deprecated
/// - Phase 3 (future): `AppContainerForTest` will be removed
///
/// **Recommendation**: New code should use `LandServer<State>.LandServerForTest` directly.
public typealias AppContainerForTest<State: StateNodeProtocol> = LandServer<State>.LandServerForTest
