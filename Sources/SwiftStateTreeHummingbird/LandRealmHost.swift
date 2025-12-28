import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore

// MARK: - LandRealmHost

/// Unified host that combines LandRealm and LandHost functionality.
///
/// `LandRealmHost` integrates HTTP server management (LandHost) directly into LandRealm,
/// making LandRealm a complete host for Hummingbird applications. This eliminates the need
/// to separately manage LandRealm and LandHost.
///
/// **Key Features**:
/// - Combines LandRealm (game logic management) and LandHost (HTTP server management)
/// - Single unified API for registering land types and running the server
/// - Automatically manages shared Router and Application
/// - Supports multiple land types with different State types
///
/// **Usage Example**:
/// ```swift
/// var realmHost = LandRealmHost(configuration: .init(
///     host: "localhost",
///     port: 8080,
///     logger: logger
/// ))
///
/// // Register land types - router is automatically used
/// try await realmHost.registerWithLandServer(
///     landType: "cookie",
///     landFactory: { _ in CookieGame.makeLand() },
///     initialStateFactory: { _ in CookieGameState() },
///     webSocketPath: "/game/cookie"
/// )
///
/// try await realmHost.registerWithLandServer(
///     landType: "counter",
///     landFactory: { _ in CounterDemo.makeLand() },
///     initialStateFactory: { _ in CounterState() },
///     webSocketPath: "/game/counter"
/// )
///
/// // Run unified server
/// try await realmHost.run()
/// ```
public actor LandRealmHost {
    /// HTTP server configuration for Hummingbird hosting.
    public struct HostConfiguration: Sendable {
        /// Server host address (default: "localhost")
        public var host: String
        /// Server port (default: 8080)
        public var port: UInt16
        /// Health check path (default: "/health")
        public var healthPath: String
        /// Enable health check route (default: true)
        public var enableHealthRoute: Bool
        /// Enable startup banner logging (default: true)
        public var logStartupBanner: Bool
        /// Logger instance (optional)
        public var logger: Logger?
        
        public init(
            host: String = "localhost",
            port: UInt16 = 8080,
            healthPath: String = "/health",
            enableHealthRoute: Bool = true,
            logStartupBanner: Bool = true,
            logger: Logger? = nil
        ) {
            self.host = host
            self.port = port
            self.healthPath = healthPath
            self.enableHealthRoute = enableHealthRoute
            self.logStartupBanner = logStartupBanner
            self.logger = logger
        }
    }
    
    /// The underlying LandRealm for game logic management.
    public let realm: LandRealm
    
    /// The shared Router for all registered LandServer instances.
    ///
    /// LandServer instances should use this router when registering their routes.
    /// Marked as nonisolated to allow safe access from actor contexts.
    nonisolated(unsafe) public let router: Router<BasicWebSocketRequestContext>
    
    /// Host configuration.
    public let configuration: HostConfiguration
    
    /// Registered server paths for startup logging.
    private var registeredServerPaths: [String: String] = [:]
    
    /// Initialize a new LandRealmHost.
    ///
    /// - Parameter configuration: Host configuration (host, port, logger, etc.)
    public init(configuration: HostConfiguration = HostConfiguration()) {
        self.configuration = configuration
        self.realm = LandRealm(logger: configuration.logger)
        // Router must be created as nonisolated(unsafe) to allow access from nonisolated contexts
        nonisolated(unsafe) let createdRouter = Router(context: BasicWebSocketRequestContext.self)
        self.router = createdRouter
        
        // Register health check route if enabled
        if configuration.enableHealthRoute {
            createdRouter.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
    }
    
    /// Register a land type with LandServer (Hummingbird-specific convenience method).
    ///
    /// This method creates a LandServer and registers it with the underlying LandRealm,
    /// automatically using the shared router from this host.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "cookie", "counter")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    ///   - configuration: Optional LandServer configuration (uses defaults if not provided)
    ///   - allowAutoCreateOnJoin: Allow auto-creating land when join with instanceId but land doesn't exist (default: false)
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func registerWithLandServer<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil,
        configuration: LandServer<State>.Configuration? = nil,
        allowAutoCreateOnJoin: Bool = false
    ) async throws {
        let path = webSocketPath ?? "/\(landType)"
        
        // Create server configuration
        let finalConfig: LandServer<State>.Configuration
        if let providedConfig = configuration {
            var config = providedConfig
            config.webSocketPath = path
            finalConfig = config
        } else {
            finalConfig = LandServer<State>.Configuration(webSocketPath: path)
        }
        
        // Create server with shared router
        // Router is nonisolated(unsafe), so we can safely pass it directly
        // The router is only used for route registration, which is safe even from actor context
        // Extract router in a nonisolated context to avoid Swift 6 concurrency warnings
        let server = try await Self.createServerWithRouter(
            router: router,
            configuration: finalConfig,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            allowAutoCreateOnJoin: allowAutoCreateOnJoin
        )
        
        // Register server with realm (we're in actor context, so this is safe)
        try await realm.register(landType: landType, server: server)
        
        // Store path for startup logging
        registeredServerPaths[landType] = path
    }
    
    /// Run the unified Hummingbird HTTP server.
    ///
    /// This method creates and runs a single Hummingbird Application with the
    /// shared router that contains all registered LandServer routes.
    ///
    /// - Throws: Error if the Application fails to start
    public func run() async throws {
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandRealmHost"
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
            logger.info("🚀 LandRealmHost server started at \(baseURL)")
            
            if configuration.enableHealthRoute {
                logger.info("❤️  Health check: \(baseURL)\(configuration.healthPath)")
            }
            
            logger.info("📡 Registered WebSocket endpoints:")
            for (landType, path) in registeredServerPaths.sorted(by: { $0.key < $1.key }) {
                let wsURL = "ws://\(configuration.host):\(configuration.port)\(path)"
                // Get state type name from realm
                let stateTypeName = await getStateTypeName(for: landType)
                logger.info("   - \(landType): \(wsURL) (State: \(stateTypeName))")
            }
        }
        
        try await app.runService()
    }
    
    /// Get the state type name for a registered land type (for logging).
    private func getStateTypeName(for landType: String) async -> String {
        return await realm.getStateTypeName(for: landType) ?? "Unknown"
    }
    
    /// Create a LandServer with the shared router (nonisolated helper to avoid concurrency warnings).
    ///
    /// This method is nonisolated to allow safe passing of the nonisolated(unsafe) router
    /// to makeMultiRoomServer without triggering Swift 6 concurrency warnings.
    private nonisolated static func createServerWithRouter<State: StateNodeProtocol>(
        router: Router<BasicWebSocketRequestContext>,
        configuration: LandServer<State>.Configuration,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        allowAutoCreateOnJoin: Bool
    ) async throws -> LandServer<State> {
        return try await LandServer<State>.makeMultiRoomServer(
            configuration: configuration,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            createGuestSession: LandServer<State>.defaultCreateGuestSession,
            allowAutoCreateOnJoin: allowAutoCreateOnJoin,
            router: router
        )
    }
    
    /// Register admin routes for this LandRealmHost.
    ///
    /// This method creates and registers admin HTTP routes that can manage lands
    /// across all registered land types in this LandRealmHost.
    /// The routes are automatically registered on the shared router.
    ///
    /// **Key Feature**: Unlike the old `AdminRoutes<State>`, this version can manage
    /// lands across different `State` types by aggregating data from all registered servers.
    ///
    /// - Parameters:
    ///   - adminAuth: Admin authentication middleware
    ///   - logger: Optional logger instance
    public func registerAdminRoutes(
        adminAuth: AdminAuthMiddleware,
        logger: Logger? = nil
    ) {
        // Create AdminRoutes and register on the shared router
        let adminRoutes = AdminRoutes(
            landRealm: realm,
            adminAuth: adminAuth,
            logger: logger
        )
        adminRoutes.registerRoutes(on: router)
    }
}
