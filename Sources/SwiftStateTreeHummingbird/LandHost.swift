import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore

// MARK: - LandHost

/// Unified host that combines LandRealm and HTTP server management.
///
/// `LandHost` provides a complete hosting solution for Hummingbird applications,
/// integrating game logic management (LandRealm) with HTTP server management in a single API.
///
/// **Key Features**:
/// - Combines LandRealm (game logic management) and HTTP server management
/// - Single unified API for registering land types and running the server
/// - Automatically manages shared Router and Application
/// - Supports multiple land types with different State types
///
/// **Usage Example**:
/// ```swift
/// let host = LandHost(configuration: .init(
///     host: "localhost",
///     port: 8080,
///     logger: logger
/// ))
///
/// // Register land types - router is automatically used
/// try await host.register(
///     landType: "cookie",
///     land: CookieGame.makeLand(),
///     initialState: CookieGameState(),
///     webSocketPath: "/game/cookie"
/// )
///
/// try await host.register(
///     landType: "counter",
///     land: CounterDemo.makeLand(),
///     initialState: CounterState(),
///     webSocketPath: "/game/counter"
/// )
///
/// // Run unified server
/// try await host.run()
/// ```
public actor LandHost {
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
    /// Route registration is handled by LandHost methods (register, registerAdminRoutes).
    let router: Router<BasicWebSocketRequestContext>
    
    /// Host configuration.
    public let configuration: HostConfiguration
    
    /// Registered server paths for startup logging.
    private var registeredServerPaths: [String: String] = [:]
    
    /// Initialize a new LandHost.
    ///
    /// - Parameter configuration: Host configuration (host, port, logger, etc.)
    public init(configuration: HostConfiguration = HostConfiguration()) {
        self.configuration = configuration
        self.realm = LandRealm(logger: configuration.logger)
        // Create router - all access is serialized through the actor's methods
        let createdRouter = Router(context: BasicWebSocketRequestContext.self)
        self.router = createdRouter
        
        // Register health check route if enabled
        if configuration.enableHealthRoute {
            createdRouter.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
    }
    
    /// Register a land type.
    ///
    /// This method creates a LandServer and registers it with the underlying LandRealm,
    /// automatically registering WebSocket routes on the shared router.
    /// Rooms are created dynamically by clients when they connect (if `allowAutoCreateOnJoin` is enabled).
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "cookie", "counter")
    ///   - landFactory: Factory function to create LandDefinition for a given LandID
    ///   - initialStateFactory: Factory function to create initial state for a given LandID
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    ///   - configuration: Optional LandServer configuration (uses defaults if not provided)
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func register<State: StateNodeProtocol>(
        landType: String,
        landFactory: @escaping @Sendable (LandID) -> LandDefinition<State>,
        initialStateFactory: @escaping @Sendable (LandID) -> State,
        webSocketPath: String? = nil,
        configuration: LandServerConfiguration? = nil
    ) async throws {
        // Validate landType
        guard !landType.isEmpty else {
            throw LandRealmError.invalidLandType(landType)
        }
        
        // Check for duplicate
        if await realm.isRegistered(landType: landType) {
            throw LandRealmError.duplicateLandType(landType)
        }
        
        let path = webSocketPath ?? "/\(landType)"
        
        // Create server configuration
        var finalConfig: LandServerConfiguration
        if let providedConfig = configuration {
            finalConfig = providedConfig
        } else {
            finalConfig = LandServerConfiguration()
        }
        
        // Create server (no router - LandHost handles route registration)
        // LandServer<State>.Configuration is a typealias of LandServerConfiguration, so we can use it directly
        let serverConfig: LandServer<State>.Configuration = finalConfig
        let server = try await LandServer<State>.create(
            configuration: serverConfig,
            landFactory: landFactory,
            initialStateFactory: initialStateFactory,
            createGuestSession: LandServer<State>.defaultCreateGuestSession
        )
        
        // Register WebSocket route on shared router
        guard let hbAdapter = server.hbAdapter else {
            throw LandHostError.invalidServer("Server does not have hbAdapter")
        }
        
        // Register WebSocket route
        registerWebSocketRoute(
            path: path,
            hbAdapter: hbAdapter
        )
        
        // Register server with realm (we're in actor context, so this is safe)
        try await realm.register(landType: landType, server: server)
        
        // Store path for startup logging
        registeredServerPaths[landType] = path
    }
    
    /// Register a land type - simplified version.
    ///
    /// This is a convenience overload that accepts `LandDefinition` and `State` directly
    /// instead of factory functions. It automatically creates factories that ignore the `LandID`.
    /// Rooms are created dynamically by clients when they connect (if `allowAutoCreateOnJoin` is enabled).
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "cookie", "counter")
    ///   - land: The Land definition (will be reused for all instances)
    ///   - initialState: Initial state template (will be reused for all instances)
    ///   - webSocketPath: Optional custom WebSocket path (defaults to "/{landType}")
    ///   - configuration: Optional LandServer configuration (uses defaults if not provided)
    /// - Throws: `LandRealmError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandRealmError.invalidLandType` if the land type is invalid (e.g., empty)
    public func register<State: StateNodeProtocol>(
        landType: String,
        land: LandDefinition<State>,
        initialState: State = State(),
        webSocketPath: String? = nil,
        configuration: LandServerConfiguration? = nil
    ) async throws {
        // Delegate to the factory-based method
        try await register(
            landType: landType,
            landFactory: { _ in land },
            initialStateFactory: { _ in initialState },
            webSocketPath: webSocketPath,
            configuration: configuration
        )
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
            scope: "LandHost"
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
            logger.info("🚀 LandHost server started at \(baseURL)")
            
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
            
            // Add connection hint for multi-room mode
            if registeredServerPaths.count > 0 {
                logger.info("💡 Tip: Use JoinRequest message with landID to connect to specific rooms")
            }
        }
        
        do {
            try await app.runService()
        } catch {
            // Check for port binding errors (EADDRINUSE = errno 48)
            let errorDescription = String(describing: error)
            let errorMessage = "\(error)"
            let lowercasedError = errorMessage.lowercased()
            
            // Check if it's a port binding error (multiple patterns to catch different error formats)
            let isPortInUse = lowercasedError.contains("address already in use") ||
                             lowercasedError.contains("errno: 48") ||
                             lowercasedError.contains("errno 48") ||
                             lowercasedError.contains("eaddrinuse") ||
                             errorDescription.contains("Address already in use") ||
                             errorDescription.contains("errno: 48")
            
            if isPortInUse {
                logger.error("❌ Failed to start server: Port \(configuration.port) is already in use", metadata: [
                    "host": .string(configuration.host),
                    "port": .string("\(configuration.port)"),
                    "error": .string(errorMessage),
                    "errno": .string("48"),
                    "errorType": .string("EADDRINUSE"),
                    "suggestion": .string("Try using a different port or stop the process using this port")
                ])
                throw LandHostError.portAlreadyInUse(host: configuration.host, port: configuration.port, underlyingError: errorMessage)
            } else {
                // Log other errors
                logger.error("❌ Failed to start server", metadata: [
                    "host": .string(configuration.host),
                    "port": .string("\(configuration.port)"),
                    "error": .string(errorMessage),
                    "errorType": .string(String(describing: type(of: error)))
                ])
                throw LandHostError.serverStartupFailed(underlyingError: errorMessage)
            }
        }
    }
    
    /// Get the state type name for a registered land type (for logging).
    private func getStateTypeName(for landType: String) async -> String {
        return await realm.getStateTypeName(for: landType) ?? "Unknown"
    }
    
    /// Register WebSocket route on the router.
    private func registerWebSocketRoute(
        path: String,
        hbAdapter: HummingbirdStateTreeAdapter
    ) {
        router.ws(RouterPath(path)) { inbound, outbound, context in
            await hbAdapter.handle(inbound: inbound, outbound: outbound, context: context)
        }
    }
    
    /// Register admin routes for this LandHost.
    ///
    /// This method creates and registers admin HTTP routes that can manage lands
    /// across all registered land types in this LandHost.
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

/// Errors that can be thrown by LandHost.
public enum LandHostError: Error, Sendable {
    /// The server does not have a valid hbAdapter.
    case invalidServer(String)
    /// The land type is already registered.
    case duplicateLandType(String)
    /// The land type is invalid (e.g., empty).
    case invalidLandType(String)
    /// The port is already in use (EADDRINUSE, errno: 48).
    case portAlreadyInUse(host: String, port: UInt16, underlyingError: String)
    /// The server failed to start for other reasons.
    case serverStartupFailed(underlyingError: String)
}
