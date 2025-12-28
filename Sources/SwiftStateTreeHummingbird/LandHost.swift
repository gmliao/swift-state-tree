import Foundation
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
import Logging
import NIOCore

/// Unified HTTP Server Host for managing multiple LandServer instances.
///
/// `LandHost` provides a single HTTP server (Application) that can host multiple
/// `LandServer` instances with different State types, all sharing the same Router
/// and Application. This solves the port conflict issue when running multiple
/// `LandServer` instances.
///
/// **Key Features**:
/// - Manages a single `Router` and `Application` instance
/// - Allows multiple `LandServer` instances with different State types to register
/// - Each `LandServer` can have its own WebSocket path (e.g., `/game/cookie`, `/game/counter`)
/// - Supports optional health check route
/// - Provides unified startup logging
///
/// **Usage Example**:
/// ```swift
/// let host = LandHost(configuration: .init(
///     host: "localhost",
///     port: 8080,
///     logger: logger
/// ))
///
/// // Register Cookie Game Server
/// let cookieServer = try await LandServer<CookieGameState>.makeMultiRoomServer(
///     configuration: ...,
///     router: host.router  // Use host's router
/// )
/// try await host.register(
///     landType: "cookie",
///     server: cookieServer,
///     webSocketPath: "/game/cookie"
/// )
///
/// // Register Counter Demo Server
/// let counterServer = try await LandServer<CounterState>.makeMultiRoomServer(
///     configuration: ...,
///     router: host.router  // Use same router
/// )
/// try await host.register(
///     landType: "counter",
///     server: counterServer,
///     webSocketPath: "/game/counter"
/// )
///
/// // Run unified server
/// try await host.run()
/// ```
public struct LandHost {
    /// Configuration for the LandHost.
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
    
    /// The shared Router for all registered LandServer instances.
    ///
    /// LandServer instances should use this router when registering their routes.
    /// Marked as nonisolated to allow safe access from actor contexts.
    nonisolated(unsafe) public let router: Router<BasicWebSocketRequestContext>
    
    /// Host configuration.
    public let configuration: HostConfiguration
    
    /// Registered servers (landType -> server info)
    private var registeredServers: [String: RegisteredServerInfo] = [:]
    
    /// Internal storage for registered server information.
    private struct RegisteredServerInfo {
        let landType: String
        let webSocketPath: String
        let stateTypeName: String
    }
    
    /// Initialize a new LandHost.
    ///
    /// - Parameter configuration: Host configuration (host, port, logger, etc.)
    public init(configuration: HostConfiguration = HostConfiguration()) {
        self.configuration = configuration
        self.router = Router(context: BasicWebSocketRequestContext.self)
        
        // Register health check route if enabled
        if configuration.enableHealthRoute {
            router.get(RouterPath(configuration.healthPath)) { _, _ in
                "OK"
            }
        }
    }
    
    /// Register a LandServer to this host.
    ///
    /// The server's routes will be registered on the shared router. The server
    /// should be created with `router: host.router` to use the shared router.
    ///
    /// **Note**: When using `LandHost`, the server should skip registering
    /// health check and schema routes, as `LandHost` manages these centrally.
    ///
    /// - Parameters:
    ///   - landType: The land type identifier (e.g., "cookie", "counter")
    ///   - server: The LandServer instance to register
    ///   - webSocketPath: The WebSocket path for this land type (e.g., "/game/cookie")
    /// - Throws: `LandHostError.duplicateLandType` if the land type is already registered
    /// - Throws: `LandHostError.invalidLandType` if the land type is invalid (e.g., empty)
    public mutating func register<Server: LandServerProtocol>(
        landType: String,
        server: Server,
        webSocketPath: String
    ) throws {
        // Validate landType
        guard !landType.isEmpty else {
            throw LandHostError.invalidLandType(landType)
        }
        
        // Check for duplicate
        guard registeredServers[landType] == nil else {
            throw LandHostError.duplicateLandType(landType)
        }
        
        // Store server info
        let serverInfo = RegisteredServerInfo(
            landType: landType,
            webSocketPath: webSocketPath,
            stateTypeName: String(describing: Server.State.self)
        )
        
        registeredServers[landType] = serverInfo
        
        let logger = configuration.logger ?? createColoredLogger(
            loggerIdentifier: "com.swiftstatetree.hummingbird",
            scope: "LandHost"
        )
        
        logger.info("Registered land type '\(landType)' (State: \(serverInfo.stateTypeName)) at path '\(webSocketPath)'")
    }
    
    /// Run the unified Application.
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
            for (landType, serverInfo) in registeredServers.sorted(by: { $0.key < $1.key }) {
                let wsURL = "ws://\(configuration.host):\(configuration.port)\(serverInfo.webSocketPath)"
                logger.info("   - \(landType): \(wsURL) (State: \(serverInfo.stateTypeName))")
            }
        }
        
        try await app.runService()
    }
}

/// Errors that can be thrown by LandHost.
public enum LandHostError: Error, Sendable {
    /// The land type is already registered.
    case duplicateLandType(String)
    /// The land type is invalid (e.g., empty).
    case invalidLandType(String)
}
