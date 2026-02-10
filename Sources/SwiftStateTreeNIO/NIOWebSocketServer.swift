// Sources/SwiftStateTreeNIO/NIOWebSocketServer.swift
//
// High-performance WebSocket server using pure SwiftNIO.

import Foundation
import Logging
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOWebSocket
import SwiftStateTree
import SwiftStateTreeTransport

/// Configuration for NIOWebSocketServer.
public struct NIOWebSocketServerConfiguration: Sendable {
    /// Host to bind to.
    public var host: String
    /// Port to bind to.
    public var port: Int
    /// Number of event loop threads. Defaults to system core count.
    public var eventLoopThreads: Int
    /// Maximum WebSocket frame size.
    public var maxFrameSize: Int
    /// Logger for server events.
    public var logger: Logger
    /// Schema data provider for /schema endpoint (legacy, prefer using NIOHTTPRouter).
    public var schemaProvider: (@Sendable () -> Data?)?

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        eventLoopThreads: Int = System.coreCount,
        maxFrameSize: Int = 1 << 24,  // 16MB
        logger: Logger = Logger(label: "com.swiftstatetree.nio"),
        schemaProvider: (@Sendable () -> Data?)? = nil
    ) {
        self.host = host
        self.port = port
        self.eventLoopThreads = eventLoopThreads
        self.maxFrameSize = maxFrameSize
        self.logger = logger
        self.schemaProvider = schemaProvider
    }
}

/// Pure SwiftNIO WebSocket server for SwiftStateTree.
///
/// This server provides a high-performance WebSocket transport layer
/// without the overhead of Hummingbird's HTTP framework.
///
/// Auth is resolved via `AuthInfoResolverProtocol` from SwiftStateTreeTransport;
/// use `ClosureAuthInfoResolver` to wrap a closure if needed.
public actor NIOWebSocketServer {
    private let configuration: NIOWebSocketServerConfiguration
    private let transportResolver: @Sendable (String) -> WebSocketTransport?
    private let pathMatcher: @Sendable (String) -> Bool
    private let httpRouter: NIOHTTPRouter?
    private let authInfoResolver: (any AuthInfoResolverProtocol)?


    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var isRunning: Bool = false

    /// Creates a new NIO WebSocket server with a single transport.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration.
    ///   - transport: The WebSocketTransport to delegate connections to.
    ///   - pathMatcher: A closure that returns true if a given path should be upgraded to WebSocket.
    public init(
        configuration: NIOWebSocketServerConfiguration = .init(),
        transport: WebSocketTransport,
        pathMatcher: @escaping @Sendable (String) -> Bool = { $0.hasPrefix("/game/") }
    ) {
        self.configuration = configuration
        self.transportResolver = { _ in transport }
        self.pathMatcher = pathMatcher
        self.httpRouter = nil
        self.authInfoResolver = nil
    }
    
    /// Creates a new NIO WebSocket server with multiple transports.
    ///
    /// - Parameters:
    ///   - configuration: Server configuration.
    ///   - transportResolver: Resolves the transport for a given WebSocket path.
    ///   - pathMatcher: A closure that returns true if a given path should be upgraded to WebSocket.
    ///   - httpRouter: Optional HTTP router for handling non-WebSocket requests.
    ///   - authInfoResolver: Optional auth resolver (e.g. JWT). If it throws, the upgrade is rejected. Use `ClosureAuthInfoResolver` to wrap a closure.
    public init(
        configuration: NIOWebSocketServerConfiguration = .init(),
        transportResolver: @escaping @Sendable (String) -> WebSocketTransport?,
        pathMatcher: @escaping @Sendable (String) -> Bool,
        httpRouter: NIOHTTPRouter? = nil,
        authInfoResolver: (any AuthInfoResolverProtocol)? = nil
    ) {
        self.configuration = configuration
        self.transportResolver = transportResolver
        self.pathMatcher = pathMatcher
        self.httpRouter = httpRouter
        self.authInfoResolver = authInfoResolver
    }

    /// Starts the WebSocket server.
    public func start() async throws {
        guard !isRunning else {
            configuration.logger.warning("Server already running")
            return
        }

        let group = MultiThreadedEventLoopGroup(numberOfThreads: configuration.eventLoopThreads)
        self.group = group

        let transportResolver = self.transportResolver
        let pathMatcher = self.pathMatcher
        let authInfoResolver = self.authInfoResolver
        let maxFrameSize = self.configuration.maxFrameSize
        let logger = self.configuration.logger
        let schemaProvider = self.configuration.schemaProvider ?? { nil }
        let httpRouter = self.httpRouter

        let upgrader = NIOWebSocketServerUpgrader(
            maxFrameSize: maxFrameSize,
            automaticErrorHandling: true,
            shouldUpgrade: { channel, head in
                let path = head.uri.components(separatedBy: "?").first ?? head.uri
                if pathMatcher(path) {
                    return channel.eventLoop.makeSucceededFuture(HTTPHeaders())
                }
                return channel.eventLoop.makeSucceededFuture(nil)
            },
            upgradePipelineHandler: { channel, head in
                let path = head.uri.components(separatedBy: "?").first ?? head.uri
                let fullURI = head.uri
                let sessionID = SessionID(UUID().uuidString)

                guard let transport = transportResolver(path) else {
                    logger.error("No transport found for path", metadata: ["path": .string(path)])
                    return channel.close()
                }

                if let resolver = authInfoResolver {
                    let promise = channel.eventLoop.makePromise(of: AuthenticatedInfo?.self)
                    Task {
                        do {
                            let authInfo = try await resolver.resolve(path: path, uri: fullURI)
                            promise.succeed(authInfo)
                        } catch {
                            logger.debug("Auth resolution failed", metadata: ["path": .string(path), "error": .string(String(describing: error))])
                            promise.fail(error)
                        }
                    }
                    return promise.futureResult
                        .flatMap { authInfo in
                            channel.pipeline.addHandler(WebSocketSessionHandler(
                                sessionID: sessionID,
                                path: path,
                                transport: transport,
                                authInfo: authInfo,
                                logger: logger
                            ))
                        }
                        .flatMapError { error in
                            logger.warning("JWT/auth validation failed, rejecting upgrade", metadata: ["path": .string(path), "error": .string(String(describing: error))])
                            return channel.close()
                        }
                }

                let handler = WebSocketSessionHandler(
                    sessionID: sessionID,
                    path: path,
                    transport: transport,
                    authInfo: nil,
                    logger: logger
                )
                return channel.pipeline.addHandler(handler)
            }
        )

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                // Create HTTP handler with router support
                let httpHandler = NIOHTTPRequestHandler(
                    logger: logger,
                    schemaProvider: schemaProvider,
                    httpRouter: httpRouter
                )
                
                return channel.pipeline.configureHTTPServerPipeline(
                    withPipeliningAssistance: false,
                    withServerUpgrade: (
                        upgraders: [upgrader],
                        completionHandler: { context in
                            // Remove our HTTP handler after WebSocket upgrade completes
                            // This is critical: if left in pipeline, it will try to decode
                            // WebSocket frames as HTTP, causing fatal errors
                            context.pipeline.removeHandler(httpHandler, promise: nil)
                        }
                    ),
                    withErrorHandling: true
                ).flatMap {
                    // Add our HTTP handler after the HTTP pipeline is configured
                    channel.pipeline.addHandler(httpHandler, position: .last)
                }
            }
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)

        let channel = try await bootstrap.bind(host: configuration.host, port: configuration.port).get()
        self.serverChannel = channel
        self.isRunning = true

        configuration.logger.info(
            "NIO WebSocket server started",
            metadata: [
                "host": .string(configuration.host),
                "port": .stringConvertible(configuration.port),
                "threads": .stringConvertible(configuration.eventLoopThreads),
            ]
        )
    }

    /// Shuts down the server gracefully.
    public func shutdown() async throws {
        guard isRunning else { return }

        if let channel = serverChannel {
            try await channel.close()
        }

        if let group = self.group {
            try await group.shutdownGracefully()
        }

        self.serverChannel = nil
        self.group = nil
        self.isRunning = false

        configuration.logger.info("NIO WebSocket server stopped")
    }

    /// Returns whether the server is currently running.
    public var running: Bool {
        isRunning
    }

    /// Returns the local address the server is bound to.
    public var localAddress: SocketAddress? {
        serverChannel?.localAddress
    }
}
