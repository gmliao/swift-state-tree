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
    /// Number of event loop threads. Defaults to `EVENT_LOOP_THREADS`, else
    /// `availableCPUCount`; an explicit value of 0 or below also gives that default.
    public var eventLoopThreads: Int
    /// Maximum WebSocket frame size.
    public var maxFrameSize: Int
    /// Logger for server events.
    public var logger: Logger
    /// Schema data provider for /schema endpoint (legacy, prefer using NIOHTTPRouter).
    public var schemaProvider: (@Sendable () -> Data?)?
    /// Listen backlog requested for the server socket: how many connections the kernel queues
    /// before `accept`. The kernel caps it at `somaxconn` but never raises it, so a small value
    /// drops SYNs when many clients connect at once. Defaults to `LISTEN_BACKLOG`, else
    /// `defaultListenBacklog`. An explicit value of 0 or below also gives `defaultListenBacklog`
    /// (as `LISTEN_BACKLOG` does), and values above `Int32.max` are capped.
    public var listenBacklog: Int

    /// The CPUs this process may use: the smaller of NIO's `System.coreCount` (cgroup quota and
    /// cpuset on Linux) and the scheduler affinity mask, which `System.coreCount` does not read,
    /// so a server pinned with `taskset` would otherwise get a thread per CPU on the machine.
    /// The mask is read from `/proc/self/status` (`Cpus_allowed_list`, Linux); where that file
    /// does not exist, `activeProcessorCount` stands in. At least 1.
    public static var availableCPUCount: Int {
        let affinity = affinityCPUCount() ?? ProcessInfo.processInfo.activeProcessorCount
        return max(1, min(System.coreCount, affinity))
    }

    /// CPUs in this process's scheduler affinity mask, from `/proc/self/status`; nil where the
    /// file or the field is missing (not Linux) or does not parse.
    static func affinityCPUCount(statusPath: String = "/proc/self/status") -> Int? {
        guard let status = try? String(contentsOfFile: statusPath, encoding: .utf8) else { return nil }
        return cpusAllowedCount(status: status)
    }

    /// The CPU count of the `Cpus_allowed_list:` line of a `/proc/<pid>/status` text, such as
    /// `0-3,8,10-11` (7 CPUs); nil if the line is missing or malformed.
    static func cpusAllowedCount(status: String) -> Int? {
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Cpus_allowed_list:") }) else {
            return nil
        }
        let list = line.dropFirst("Cpus_allowed_list:".count).trimmingCharacters(in: .whitespaces)
        var count = 0
        for range in list.split(separator: ",") {
            let bounds = range.split(separator: "-", maxSplits: 1).map { Int($0.trimmingCharacters(in: .whitespaces)) }
            guard let first = bounds.first ?? nil, let last = bounds.last ?? nil, first >= 0, last >= first else {
                return nil
            }
            count += last - first + 1
        }
        return count > 0 ? count : nil
    }

    /// The event-loop thread count from `EVENT_LOOP_THREADS`: a positive integer; missing or
    /// invalid values give `availableCPUCount`.
    public static func eventLoopThreads(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        normalizedEventLoopThreads(EnvHelpers.getEnvInt(
            key: EnvKeys.Server.eventLoopThreads,
            defaultValue: 0,
            environment: environment.mapValues { $0.trimmingCharacters(in: .whitespaces) }
        ))
    }

    /// `value` as a valid thread count: 0 or below gives `availableCPUCount`.
    public static func normalizedEventLoopThreads(_ value: Int) -> Int {
        value > 0 ? value : availableCPUCount
    }

    /// The listen backlog without `LISTEN_BACKLOG`.
    public static let defaultListenBacklog = 4096

    /// The listen backlog from `LISTEN_BACKLOG`: a positive integer, at most `Int32.max`;
    /// missing or invalid values give `defaultListenBacklog`.
    public static func listenBacklog(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Int {
        normalizedListenBacklog(EnvHelpers.getEnvInt(
            key: EnvKeys.Server.listenBacklog,
            defaultValue: defaultListenBacklog,
            environment: environment
        ))
    }

    /// `value` as a valid listen backlog: 0 or below gives `defaultListenBacklog`, and values
    /// above `Int32.max` are capped.
    public static func normalizedListenBacklog(_ value: Int) -> Int {
        guard value > 0 else { return defaultListenBacklog }
        return min(value, Int(Int32.max))
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        eventLoopThreads: Int = NIOWebSocketServerConfiguration.eventLoopThreads(),
        maxFrameSize: Int = 1 << 24,  // 16MB
        logger: Logger = Logger(label: "com.swiftstatetree.nio"),
        schemaProvider: (@Sendable () -> Data?)? = nil,
        listenBacklog: Int = NIOWebSocketServerConfiguration.listenBacklog()
    ) {
        self.host = host
        self.port = port
        self.eventLoopThreads = Self.normalizedEventLoopThreads(eventLoopThreads)
        self.maxFrameSize = maxFrameSize
        self.logger = logger
        self.schemaProvider = schemaProvider
        self.listenBacklog = Self.normalizedListenBacklog(listenBacklog)
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
            .serverChannelOption(ChannelOptions.backlog, value: Int32(configuration.listenBacklog))
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
                // What the default is made of, to check the count against the CPUs the
                // process may use (EVENT_LOOP_THREADS overrides it).
                "availableCPUs": .stringConvertible(NIOWebSocketServerConfiguration.availableCPUCount),
                "machineCPUs": .stringConvertible(System.coreCount),
                "eventLoopThreadsEnv": .string(EnvHelpers.getEnvStringOptional(key: EnvKeys.Server.eventLoopThreads) ?? "unset"),
                // Requested; the kernel caps it at somaxconn.
                "listenBacklog": .stringConvertible(configuration.listenBacklog),
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
