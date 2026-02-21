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
    /// Number of event loop threads.
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

    public init(
        host: String = "localhost",
        port: UInt16 = 8080,
        logger: Logger = Logger(label: "com.swiftstatetree.nio.landhost"),
        eventLoopThreads: Int = System.coreCount,
        schemaProvider: (@Sendable () -> Data?)? = nil,
        adminAPIKey: String? = nil,
        replayWebSocketPathResolver: (@Sendable (String) -> String)? = nil,
        middlewares: [any HostMiddleware] = []
    ) {
        self.host = host
        self.port = port
        self.logger = logger
        self.eventLoopThreads = eventLoopThreads
        self.schemaProvider = schemaProvider
        self.adminAPIKey = adminAPIKey
        self.replayWebSocketPathResolver = replayWebSocketPathResolver
        self.middlewares = middlewares
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
    /// When true and JWT is enabled: connections without token use createGuestSession; when false, they are rejected.
    public var allowGuestMode: Bool
    /// Factory for guest sessions when allowGuestMode is true and no JWT token is provided.
    public var createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)?

    /// Allow auto-creating land when join with instanceId but land doesn't exist (default: false).
    public var allowAutoCreateOnJoin: Bool

    /// Encoding configuration for transport messages and state updates.
    public var transportEncoding: TransportEncodingConfig

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
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        createGuestSession: (@Sendable (SessionID, ClientID) -> PlayerSession)? = nil,
        servicesFactory: @Sendable @escaping (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        },
        keeperModeResolver: (@Sendable (LandID, [String: String]) -> LandKeeperModeConfig?)? = nil
    ) {
        self.logger = logger
        self.jwtConfig = jwtConfig
        self.jwtValidator = jwtValidator
        self.allowGuestMode = allowGuestMode
        self.createGuestSession = createGuestSession
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        self.transportEncoding = transportEncoding
        self.enableLiveStateHashRecording = enableLiveStateHashRecording
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

    /// Background tasks from middlewares (cancelled on shutdown).
    private var middlewareTasks: [Task<Void, Never>] = []

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
    public func register<State: StateNodeProtocol>(
        landType: String,
        land: LandDefinition<State>,
        initialState: @autoclosure @escaping @Sendable () -> State,
        webSocketPath: String,
        configuration: NIOLandServerConfiguration
    ) async throws {
        let initialStateFunc = initialState
        
        // Create transport for this land type
        let transport = WebSocketTransport()
        
        // Create NIOLandServer
        let server = NIOLandServer<State>(
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

        // Store path mappings
        pathToLandType[webSocketPath] = landType
        pathToTransport[webSocketPath] = transport
        pathToServerConfig[webSocketPath] = configuration
        registeredLandEncodings[landType] = configuration.transportEncoding

        self.configuration.logger.info(
            "Registered land type",
            metadata: [
                "landType": .string(landType),
                "path": .string(webSocketPath),
                "encoding": .string(String(describing: configuration.transportEncoding)),
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
            replayWebSocketPathResolver: configuration.replayWebSocketPathResolver
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

    /// Starts the server and runs until shutdown.
    public func run() async throws {
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
        let serverConfig = NIOWebSocketServerConfiguration(
            host: configuration.host,
            port: Int(configuration.port),
            eventLoopThreads: configuration.eventLoopThreads,
            logger: configuration.logger,
            schemaProvider: configuration.schemaProvider
        )

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

        // Keep running until cancelled
        await withTaskCancellationHandler {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        } onCancel: {
            Task {
                try? await self.shutdown()
            }
        }
    }

    /// Shuts down the server.
    public func shutdown() async throws {
        // Cancel middleware background tasks and wait for them to finish.
        // This prevents in-flight operations (e.g. provisioning heartbeat) from completing
        // after deregistration and re-adding a dead server to the registry.
        let tasks = middlewareTasks
        middlewareTasks = []
        for task in tasks {
            task.cancel()
            _ = await task.value
        }

        // Run middleware onShutdown pipeline (reverse order)
        let context = HostContext(
            host: configuration.host,
            port: configuration.port,
            logger: configuration.logger
        )
        for middleware in configuration.middlewares.reversed() {
            try await middleware.onShutdown(context: context)
        }

        // Shutdown realm (all land servers)
        try await realm.shutdown()
        
        // Shutdown NIO server
        if let server = server {
            try await server.shutdown()
        }
        server = nil
        configuration.logger.info("NIO WebSocket server shut down")
    }
}

// MARK: - Errors

/// Errors that can occur with NIOLandHost.
public enum NIOLandHostError: Error, Sendable {
    /// No lands have been registered.
    case noLandsRegistered
}
