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
    
    /// Assemble a multi-room server with Hummingbird hosting.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - lobbyIDs: Optional array of lobby landIDs to pre-create (e.g., ["lobby-asia", "lobby-europe"]).
    ///   - allowAutoCreateOnJoin: Allow auto-creating land when join with instanceId but land doesn't exist (default: false).
    ///                            **Security Note**: When `true`, clients can create rooms by specifying any instanceId.
    ///                            This is useful for demo/testing but should be `false` in production.
    ///   - router: Optional external router to use. If provided, routes will be registered on this router instead of creating a new one.
    ///             This allows multiple land types to share the same Hummingbird Application.
    ///   - configureRouter: Optional router configuration closure
    public static func makeMultiRoomServer(
        configuration: Configuration = Configuration(),
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        lobbyIDs: [String] = [],
        allowAutoCreateOnJoin: Bool = false,
        router: Router<BasicWebSocketRequestContext>? = nil,
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
            allowAutoCreateOnJoin: allowAutoCreateOnJoin,
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

        // Use external router if provided, otherwise create a new one
        let finalRouter = router ?? Router(context: BasicWebSocketRequestContext.self)
        
        // Generate schema from a sample land definition
        // Use a dummy LandID to create a sample definition for schema extraction
        let sampleLandID = LandID.generate(landType: "sample")
        let sampleDefinition = landFactory(sampleLandID)
        let schemaDataResult = generateSchema(from: sampleDefinition)
        
        // Register common routes (WebSocket, health, schema)
        // When using external router (from LandHost), only register WebSocket route.
        // LandHost manages health check and schema routes centrally.
        let usingSharedRouter = router != nil
        registerCommonRoutes(
            router: finalRouter,
            configuration: configuration,
            hbAdapter: hbAdapter,
            schemaDataResult: schemaDataResult,
            logger: logger,
            skipSchemaRoute: usingSharedRouter,
            skipHealthRoute: usingSharedRouter
        )
        
        // Note: Admin routes are now registered at LandRealm level when using LandRealm.
        // If you need admin routes, use LandRealmHost.registerAdminRoutes() or create AdminRoutes directly.
        // This keeps admin routes consistent across all land types.
        
        configureRouter?(finalRouter)
        
        return LandServer(
            configuration: configuration,
            router: finalRouter,
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
    ///   - router: Optional external router to use (e.g., from `LandHost`). If provided, health and schema routes will be skipped.
    ///   - configureRouter: Optional router configuration closure
    public static func makeServer(
        configuration: Configuration = Configuration(),
        land definition: Land,
        initialState: State = State(),
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        router: Router<BasicWebSocketRequestContext>? = nil,
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
        
        // Use external router if provided, otherwise create a new one
        let finalRouter = router ?? Router(context: BasicWebSocketRequestContext.self)
        let schemaDataResult = generateSchema(from: definition)
        
        // Register common routes (WebSocket, health, schema)
        // When using external router (from LandHost), only register WebSocket route.
        // LandHost manages health check and schema routes centrally.
        let usingSharedRouter = router != nil
        registerCommonRoutes(
            router: finalRouter,
            configuration: configuration,
            hbAdapter: hbAdapter,
            schemaDataResult: schemaDataResult,
            logger: logger,
            skipSchemaRoute: usingSharedRouter,
            skipHealthRoute: usingSharedRouter
        )
        
        configureRouter?(finalRouter)
        
        return LandServer(
            configuration: configuration,
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            hbAdapter: hbAdapter,
            router: finalRouter,
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
    ///
    /// **Note**: When using a shared router (e.g., from `LandHost`), health check and schema
    /// routes should be skipped as they are managed centrally by `LandHost`.
    ///
    /// - Parameters:
    ///   - router: The router to register routes on
    ///   - configuration: Server configuration
    ///   - hbAdapter: Hummingbird adapter for WebSocket handling
    ///   - schemaDataResult: Schema generation result
    ///   - logger: Logger instance
    ///   - skipSchemaRoute: If true, skip schema route registration (when using shared router from LandHost)
    ///   - skipHealthRoute: If true, skip health route registration (when using shared router from LandHost)
    private static func registerCommonRoutes(
        router: Router<BasicWebSocketRequestContext>,
        configuration: Configuration,
        hbAdapter: HummingbirdStateTreeAdapter,
        schemaDataResult: Result<Data, Error>,
        logger: Logger,
        skipSchemaRoute: Bool = false,
        skipHealthRoute: Bool = false
    ) {
        // WebSocket route (always registered)
        router.ws(RouterPath(configuration.webSocketPath)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
        
        // Health route (only when not using shared router - LandHost manages it centrally)
        if configuration.enableHealthRoute && !skipHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
        
        // Schema endpoint with CORS support (only when not using shared router)
        if !skipSchemaRoute {
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

/// Errors that can be thrown by LandServer.
public enum LandServerError: Error, Sendable {
    // Note: All run() related errors have been removed as run() method has been removed.
    // HTTP server lifecycle is now managed by LandHost.
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
