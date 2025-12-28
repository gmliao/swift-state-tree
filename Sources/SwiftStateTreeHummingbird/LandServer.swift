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
public struct LandServer<State: StateNodeProtocol> {
    public typealias Land = LandDefinition<State>
    
    /// Default implementation for creating guest sessions.
    ///
    /// Creates a PlayerSession with:
    /// - playerID: "guest-{randomID}" format (6-character random ID)
    /// - deviceID: clientID.rawValue
    /// - isGuest: true
    ///
    /// This is the recommended default for most use cases.
    public static func defaultCreateGuestSession(_ sessionID: SessionID, clientID: ClientID) -> PlayerSession {
        let randomID = String(UUID().uuidString.prefix(6))
        return PlayerSession(
            playerID: "guest-\(randomID)",
            deviceID: clientID.rawValue,
            isGuest: true
        )
    }
    
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
    // Note: MatchmakingService and LobbyContainer should be managed separately by users.
    // To get a lobby, use: landManager.getLobby(landID:) to get LandContainer,
    // then create LobbyContainer directly with your matchmaking dependencies.
    
    private let adapterHolder: TransportAdapterHolder<State>?
    
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
        let jwtValidator = createJWTValidator(configuration: configuration, logger: logger)
        
        // Create global WebSocketTransport
        // Since we are using LandRouter, all connections go through this single transport
        let transport = WebSocketTransport(logger: logger)
        
        // Create LandManager (must share the same transport so per-land adapters can send snapshots/updates)
        let landManager = LandManager<State>(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            transport: transport,
            createGuestSession: createGuestSession ?? defaultCreateGuestSession,
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
            createGuestSession: createGuestSession ?? defaultCreateGuestSession,
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
        let schemaDataResult = generateSchema(from: sampleDefinition)
        
        // Register common routes (WebSocket, health, schema)
        registerCommonRoutes(
            router: router,
            configuration: configuration,
            hbAdapter: hbAdapter,
            schemaDataResult: schemaDataResult,
            logger: logger
        )
        
        // Note: Admin routes are now registered at LandRealm level when using LandRealm.
        // If you need admin routes for a standalone LandServer, use LandRealm.registerAdminRoutes.
        // This keeps admin routes consistent across all land types.
        
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
    ///   - initialState: Initial state for the Land (defaults to `State()`)
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    ///                          Only used when `allowGuestMode` is true and JWT validation is enabled.
    ///                          If nil, uses `defaultCreateGuestSession` which creates "guest-{randomID}" format.
    ///   - configureRouter: Optional router configuration closure
    public static func makeServer(
        configuration: Configuration = Configuration(),
        land definition: Land,
        initialState: State = State(),
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        configureRouter: ((Router<BasicWebSocketRequestContext>) -> Void)? = nil
    ) async throws -> LandServer {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandServer"
        )
        // Create JWT validator if configured
        let jwtValidator = createJWTValidator(configuration: configuration, logger: logger)
        
        let core = await buildCoreComponents(
            land: definition,
            initialState: initialState,
            createGuestSession: createGuestSession ?? defaultCreateGuestSession,
            logger: logger
        )
        
        let hbAdapter = HummingbirdStateTreeAdapter(
            transport: core.transport,
            jwtValidator: jwtValidator,
            allowGuestMode: configuration.allowGuestMode,
            logger: logger
        )
        let router = Router(context: BasicWebSocketRequestContext.self)
        let schemaDataResult = generateSchema(from: definition)
        
        // Register common routes (WebSocket, health, schema)
        registerCommonRoutes(
            router: router,
            configuration: configuration,
            hbAdapter: hbAdapter,
            schemaDataResult: schemaDataResult,
            logger: logger
        )
        
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
        initialState: State = State(),
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
    
    // MARK: - Helper Methods for Server Setup
    
    /// Create JWT validator from configuration.
    private static func createJWTValidator(
        configuration: Configuration,
        logger: Logger
    ) -> JWTAuthValidator? {
        if let customValidator = configuration.jwtValidator {
            return customValidator
        } else if let jwtConfig = configuration.jwtConfig {
            return DefaultJWTAuthValidator(config: jwtConfig, logger: logger)
        }
        return nil
    }
    
    /// Generate schema from a land definition.
    private static func generateSchema(from definition: LandDefinition<State>) -> Result<Data, Error> {
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
    }
    
    /// Add CORS headers to a response.
    @Sendable
    private static func addCORSHeaders(_ response: inout Response) {
        response.headers[.accessControlAllowOrigin] = "*"
        response.headers[.accessControlAllowMethods] = "GET, OPTIONS"
        response.headers[.accessControlAllowHeaders] = "Content-Type"
    }
    
    /// Register common routes (WebSocket, health, schema) on the router.
    private static func registerCommonRoutes(
        router: Router<BasicWebSocketRequestContext>,
        configuration: Configuration,
        hbAdapter: HummingbirdStateTreeAdapter,
        schemaDataResult: Result<Data, Error>,
        logger: Logger
    ) {
        // WebSocket route
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        // Health route
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
        
        // Schema endpoint with CORS support
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


// MARK: - LandRealm Extension

/// Convenience extension for LandRealm to work with LandServer (Hummingbird).
///
/// This extension provides a convenient way to register LandServer instances
/// with LandRealm, making it easier to use LandRealm with Hummingbird.
extension LandRealm {
    /// Register a land type with LandServer (Hummingbird-specific convenience method).
    ///
    /// This is a convenience method that creates a LandServer and registers it with LandRealm.
    /// For framework-agnostic usage, use `LandRealm.register(landType:server:)` directly.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "chess", "cardgame", "rpg")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    ///   - configuration: Optional LandServer configuration (uses defaults if not provided)
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func registerWithLandServer<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil,
        configuration: LandServer<State>.Configuration? = nil
    ) async throws {
        // Validate landType
        guard !landType.isEmpty else {
            throw LandRealmError.invalidLandType(landType)
        }
        
        // Check for duplicate
        if self.isRegistered(landType: landType) {
            throw LandRealmError.duplicateLandType(landType)
        }
        
        // Create server
        let path = webSocketPath ?? "/\(landType)"
        let finalConfig: LandServer<State>.Configuration
        if let providedConfig = configuration {
            var config = providedConfig
            config.webSocketPath = path
            finalConfig = config
        } else {
            finalConfig = LandServer<State>.Configuration(webSocketPath: path)
        }
        
        let server = try await LandServer<State>.makeMultiRoomServer(
            configuration: finalConfig,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            createGuestSession: LandServer<State>.defaultCreateGuestSession
        )
        
        // Register using the generic method
        try await register(landType: landType, server: server)
    }
    
    /// Register admin routes for this LandRealm.
    ///
    /// This method creates and registers admin HTTP routes that can manage lands
    /// across all registered land types in this LandRealm.
    ///
    /// **Key Feature**: Unlike the old `AdminRoutes<State>`, this version can manage
    /// lands across different `State` types by aggregating data from all registered servers.
    ///
    /// - Parameters:
    ///   - router: The Hummingbird router to register routes on
    ///   - adminAuth: Admin authentication middleware
    ///   - logger: Optional logger instance
    public func registerAdminRoutes(
        on router: Router<BasicWebSocketRequestContext>,
        adminAuth: AdminAuthMiddleware,
        logger: Logger? = nil
    ) {
        let adminRoutes = AdminRoutes(
            landRealm: self,
            adminAuth: adminAuth,
            logger: logger
        )
        adminRoutes.registerRoutes(on: router)
    }
}

// MARK: - LandServerProtocol Conformance

/// Extension to make LandServer conform to LandServerProtocol.
///
/// This allows LandServer to be used with LandRealm and other components
/// that work with the LandServerProtocol abstraction.
extension LandServer: LandServerProtocol {
    /// Gracefully shutdown the server.
    ///
    /// Note: Currently, LandServer doesn't have explicit shutdown support.
    /// This is a placeholder for future implementation.
    public func shutdown() async throws {
        // TODO: Implement graceful shutdown for LandServer
        // This might involve:
        // - Stopping accepting new connections
        // - Waiting for existing connections to close
        // - Cleaning up resources
    }
    
    /// Check the health status of the server.
    ///
    /// For now, we consider a server healthy if it exists.
    /// In a real implementation, we might check if the server is running,
    /// if it can accept connections, etc.
    public func healthCheck() async -> Bool {
        // TODO: Implement actual health check
        // This might involve:
        // - Checking if the server is running
        // - Checking if it can accept connections
        // - Checking resource usage
        return true
    }
    
    /// List all lands managed by this server.
    ///
    /// For multi-room servers, returns all lands from the LandManager.
    /// For single-room servers, returns the single land if it exists.
    public func listLands() async -> [LandID] {
        if let landManager = landManager {
            // Multi-room mode: query LandManager
            return await landManager.listLands()
        } else if let land = land {
            // Single-room mode: return the single land
            return [LandID(land.id)]
        } else {
            // No lands
            return []
        }
    }
    
    /// Get statistics for a specific land.
    ///
    /// - Parameter landID: The unique identifier for the land
    /// - Returns: LandStats if the land exists, nil otherwise
    public func getLandStats(landID: LandID) async -> LandStats? {
        if let landManager = landManager {
            // Multi-room mode: query LandManager
            return await landManager.getLandStats(landID: landID)
        } else if let land = land, let keeper = keeper {
            // Single-room mode: check if it's the single land
            guard LandID(land.id) == landID else {
                return nil
            }
            
            // Get stats from keeper
            let playerCount = await keeper.playerCount()
            let createdAt = Date() // TODO: Track creation time for single-room mode
            let lastActivityAt = Date() // TODO: Track last activity time
            
            return LandStats(
                landID: landID,
                playerCount: playerCount,
                createdAt: createdAt,
                lastActivityAt: lastActivityAt
            )
        } else {
            return nil
        }
    }
    
    /// Remove a land from the server.
    ///
    /// - Parameter landID: The unique identifier for the land to remove
    public func removeLand(landID: LandID) async {
        if let landManager = landManager {
            // Multi-room mode: remove from LandManager
            await landManager.removeLand(landID: landID)
        } else if let land = land {
            // Single-room mode: only allow removal if it's the single land
            if LandID(land.id) == landID {
                // TODO: Implement shutdown for single-room server
                // For now, this is a no-op as single-room servers don't support removal
            }
        }
    }
}
