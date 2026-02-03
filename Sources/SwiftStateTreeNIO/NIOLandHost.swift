// Sources/SwiftStateTreeNIO/NIOLandHost.swift
//
// High-level API for hosting Lands with NIO WebSocket transport.

import Foundation
import Logging
import NIOCore
import NIOPosix
import SwiftStateTree
import SwiftStateTreeTransport

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

    public init(
        host: String = "localhost",
        port: UInt16 = 8080,
        logger: Logger = Logger(label: "com.swiftstatetree.nio.landhost"),
        eventLoopThreads: Int = System.coreCount,
        schemaProvider: (@Sendable () -> Data?)? = nil,
        adminAPIKey: String? = nil
    ) {
        self.host = host
        self.port = port
        self.logger = logger
        self.eventLoopThreads = eventLoopThreads
        self.schemaProvider = schemaProvider
        self.adminAPIKey = adminAPIKey
    }
}

/// Configuration for a Land registered with NIOLandHost.
///
/// This is a simplified configuration without JWT authentication support.
/// For JWT authentication, use `LandServerConfiguration` from `SwiftStateTreeHummingbird`.
public struct NIOLandServerConfiguration: Sendable {
    /// Logger for land events.
    public var logger: Logger?

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

    public init(
        logger: Logger? = nil,
        allowAutoCreateOnJoin: Bool = false,
        transportEncoding: TransportEncodingConfig = .json,
        enableLiveStateHashRecording: Bool = false,
        pathHashes: [String: UInt32]? = nil,
        eventHashes: [String: Int]? = nil,
        clientEventHashes: [String: Int]? = nil,
        servicesFactory: @Sendable @escaping (LandID, [String: String]) -> LandServices = { _, _ in
            LandServices()
        }
    ) {
        self.logger = logger
        self.allowAutoCreateOnJoin = allowAutoCreateOnJoin
        self.transportEncoding = transportEncoding
        self.enableLiveStateHashRecording = enableLiveStateHashRecording
        self.pathHashes = pathHashes
        self.eventHashes = eventHashes
        self.clientEventHashes = clientEventHashes
        self.servicesFactory = servicesFactory
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
    
    /// Registered land encodings for logging.
    private var registeredLandEncodings: [String: TransportEncodingConfig] = [:]

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
            logger: configuration.logger
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

        // Create path matcher and transport resolver
        let paths = pathToLandType
        let transports = pathToTransport
        
        let pathMatcher: @Sendable (String) -> Bool = { path in
            let cleanPath = path.components(separatedBy: "?").first ?? path
            return paths.keys.contains(cleanPath)
        }
        
        let transportResolver: @Sendable (String) -> WebSocketTransport? = { path in
            let cleanPath = path.components(separatedBy: "?").first ?? path
            return transports[cleanPath]
        }

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
            httpRouter: httpRouter
        )
        self.server = server

        try await server.start()

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
