import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeMatchmaking
import Logging
import NIOCore

/// Configuration for LandServer instances.
///
/// This configuration is independent of the State type and can be reused across
/// different land types. Use `LandServerConfiguration` directly instead of
/// `LandServer<State>.Configuration` to avoid specifying the State type.
public struct LandServerConfiguration: Sendable {
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
        
        /// Allow auto-creating land when join with instanceId but land doesn't exist (default: false).
        ///
        /// **Security Note**: When `true`, clients can create rooms by specifying any instanceId.
        /// This is useful for demo/testing but should be `false` in production.
        public var allowAutoCreateOnJoin: Bool = false
        
        public init(
            logger: Logger? = nil,
            jwtConfig: JWTConfiguration? = nil,
            jwtValidator: JWTAuthValidator? = nil,
            allowGuestMode: Bool = false,
            allowAutoCreateOnJoin: Bool = false
        ) {
            self.logger = logger
            self.jwtConfig = jwtConfig
            self.jwtValidator = jwtValidator
            self.allowGuestMode = allowGuestMode
            self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        }
}

/// Bundles runtime, transport, and Hummingbird hosting for any Land definition.
///
/// **Note**: This is the Hummingbird-specific implementation of `LandServerProtocol`.
/// For framework-agnostic usage, use the `LandServerProtocol` protocol.
public struct LandServer<State: StateNodeProtocol> {
    public typealias Land = LandDefinition<State>
    
    /// Configuration type alias for backward compatibility.
    /// Prefer using `LandServerConfiguration` directly to avoid specifying State type.
    public typealias Configuration = LandServerConfiguration
    
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
        self.landManager = landManager
        self.adapterHolder = adapterHolder
    }
    
    // Private initializer for multi-room mode
    private init(
        configuration: Configuration,
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
        self.landManager = landManager
        self.adapterHolder = nil
    }
    
    /// Assemble a multi-room server with Hummingbird hosting.
    ///
    /// **Note**: This method no longer handles router registration. Route registration
        /// should be handled by the hosting component (e.g., `LandHost`).
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - landFactory: Factory function to create LandDefinition for a given LandID.
    ///   - initialStateFactory: Factory function to create initial state for a given LandID.
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users.
    ///   - lobbyIDs: Optional array of lobby landIDs to pre-create (e.g., ["lobby-asia", "lobby-europe"]).
    public static func makeMultiRoomServer(
        configuration: Configuration,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        lobbyIDs: [String] = []
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
            allowAutoCreateOnJoin: configuration.allowAutoCreateOnJoin,
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

        // Router registration is now handled by the hosting component (LandHost)
        // LandServer only creates the hbAdapter for route registration
        
        return LandServer(
            configuration: configuration,
            landManager: landManager,
            transport: transport,
            hbAdapter: hbAdapter,
            landRouter: landRouter
        )
    }
    
    /// Assemble a runnable server with Hummingbird hosting.
    ///
    /// **Note**: This method no longer handles router registration. Route registration
        /// should be handled by the hosting component (e.g., `LandHost`).
    ///
    /// - Parameters:
    ///   - configuration: Server configuration (host, port, paths, etc.)
    ///   - land: The Land definition
    ///   - initialState: Initial state for the Land (defaults to `State()`)
    ///   - createGuestSession: Optional closure to create PlayerSession for guest users (when JWT validation is enabled but no token is provided).
    ///                          Only used when `allowGuestMode` is true and JWT validation is enabled.
    ///                          If nil, uses `defaultCreateGuestSession` which creates "guest-{randomID}" format.
    public static func makeServer(
        configuration: Configuration,
        land definition: Land,
        initialState: State = State(),
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil
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
        
        // Router registration is now handled by the hosting component (LandHost)
        // LandServer only creates the hbAdapter for route registration
        
        return LandServer(
            configuration: configuration,
            land: definition,
            keeper: core.keeper,
            transport: core.transport,
            transportAdapter: core.transportAdapter,
            hbAdapter: hbAdapter,
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
