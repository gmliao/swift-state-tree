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
    /// `availableCPUCount`. An explicit value of 0 or below gives `availableCPUCount` (not
    /// `EVENT_LOOP_THREADS`).
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
    /// How long after a keepalive ping the peer may send nothing before the connection is closed
    /// with 1001 (going away). Any inbound frame counts, not only the pong. The clock starts when
    /// the ping is written to the channel, not when it reaches the wire: with a slow reader the
    /// ping waits behind every frame queued before it, so a backed-up peer that sends nothing can
    /// hit the timeout too. Must be positive and below the ping interval
    /// (`WebSocketSessionHandler.pingInterval`, 30 s). Defaults to `WS_PONG_TIMEOUT_MS`, else
    /// `defaultPongTimeout` (20 s). See #108.
    public var pongTimeout: TimeAmount
    /// When a session's outbound backlog closes it (4008), by bytes held or time unwritable.
    /// Defaults to `WS_SEND_BACKLOG_MAX_BYTES` and `WS_SEND_BACKLOG_MAX_UNWRITABLE_MS`, else
    /// `SendBacklogBound.default` (8 MiB, 30 s). See #61.
    public var sendBacklogBound: SendBacklogBound
    /// When a session stops being read: messages or bytes read but not yet delivered to the
    /// transport. Reading resumes at half. Defaults to `WS_INBOUND_BACKLOG_MAX_MESSAGES` and
    /// `WS_INBOUND_BACKLOG_MAX_BYTES`, else `InboundBacklogBound.default` (1024, 4 MiB). See #113.
    public var inboundBacklogBound: InboundBacklogBound

    /// The CPUs this process may use: the smaller of NIO's `System.coreCount` (cgroup quota and
    /// cpuset on Linux) and the scheduler affinity mask, which `System.coreCount` does not read,
    /// so a server pinned with `taskset` would otherwise get a thread per CPU on the machine.
    /// The mask is read from `/proc/self/status` (`Cpus_allowed_list`, Linux); where that file
    /// does not exist, or does not parse, `activeProcessorCount` stands in. At least 1.
    public static var availableCPUCount: Int { availableCPUs().count }

    /// Where `availableCPUCount` came from, as the startup log reports it.
    public enum CPUCountSource: String, Sendable {
        /// The affinity mask in `/proc/self/status`.
        case cpusAllowedList
        /// Foundation's count, used where `/proc/self/status` is missing or does not parse.
        case activeProcessorCount
        /// NIO's count (cgroup quota and cpuset), when it is the smaller one.
        case coreCount
    }

    /// `availableCPUCount` with its source.
    public struct AvailableCPUs: Sendable, Equatable {
        public var count: Int
        public var source: CPUCountSource
        /// `/proc/self/status` exists but its `Cpus_allowed_list` did not parse, so the affinity
        /// mask was not applied; the server warns at startup.
        public var affinityMaskUnparsable: Bool
    }

    /// What reading the affinity mask gave.
    enum AffinityMaskReading: Equatable {
        /// The mask's CPU count.
        case cpus(Int)
        /// No `/proc/<pid>/status` (not Linux).
        case unavailable
        /// The file exists but could not be read, or its `Cpus_allowed_list` did not parse.
        case unparsable
    }

    static func availableCPUs(statusPath: String = "/proc/self/status") -> AvailableCPUs {
        let reading = readAffinityMask(statusPath: statusPath)
        var count: Int
        var source: CPUCountSource
        if case .cpus(let cpus) = reading {
            (count, source) = (cpus, .cpusAllowedList)
        } else {
            (count, source) = (ProcessInfo.processInfo.activeProcessorCount, .activeProcessorCount)
        }
        if System.coreCount < count {
            (count, source) = (System.coreCount, .coreCount)
        }
        return AvailableCPUs(count: max(1, count), source: source, affinityMaskUnparsable: reading == .unparsable)
    }

    static func readAffinityMask(statusPath: String = "/proc/self/status") -> AffinityMaskReading {
        guard FileManager.default.fileExists(atPath: statusPath) else { return .unavailable }
        guard let status = try? String(contentsOfFile: statusPath, encoding: .utf8),
              let cpus = cpusAllowedCount(status: status)
        else {
            return .unparsable
        }
        return .cpus(cpus)
    }

    /// The CPU count of the `Cpus_allowed_list:` line of a `/proc/<pid>/status` text, such as
    /// `0-3,8,10-11` (7 CPUs). Nil if the line is missing or malformed: an empty piece (`0,,2`,
    /// `-3`, `3-`), a non-number, a reversed range, or a count that overflows.
    static func cpusAllowedCount(status: String) -> Int? {
        guard let line = status.split(separator: "\n").first(where: { $0.hasPrefix("Cpus_allowed_list:") }) else {
            return nil
        }
        let list = line.dropFirst("Cpus_allowed_list:".count).trimmingCharacters(in: .whitespaces)
        guard !list.isEmpty else { return nil }
        var count = 0
        for piece in list.split(separator: ",", omittingEmptySubsequences: false) {
            let bounds = piece.split(separator: "-", omittingEmptySubsequences: false).map { Int($0) }
            guard bounds.count <= 2, let first = bounds.first ?? nil, let last = bounds.last ?? nil,
                  first >= 0, last >= first
            else {
                return nil
            }
            let (width, widthOverflow) = (last - first).addingReportingOverflow(1)
            let (sum, sumOverflow) = count.addingReportingOverflow(width)
            guard !widthOverflow, !sumOverflow else { return nil }
            count = sum
        }
        return count
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

    /// The pong timeout without `WS_PONG_TIMEOUT_MS`.
    public static let defaultPongTimeout: TimeAmount = WebSocketSessionHandler.defaultPongTimeout

    /// The pong timeout from `WS_PONG_TIMEOUT_MS`: a positive number of milliseconds below the
    /// ping interval; missing or invalid values give `defaultPongTimeout`. A value that is set
    /// but rejected is logged at warning level, once per process (this is the default argument
    /// of more than one configuration), so a run can't use the default unnoticed.
    public static func pongTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> TimeAmount {
        if let rejected = rejectedPongTimeout(environment: environment) {
            guard rejectedPongTimeoutWarning.claim() else { return defaultPongTimeout }
            Logger(label: "com.swiftstatetree.nio").warning("WS_PONG_TIMEOUT_MS is not a whole number of milliseconds above 0 and below the ping interval; using the default", metadata: [
                "value": .string(rejected),
                "defaultMs": .stringConvertible(defaultPongTimeout.nanoseconds / 1_000_000),
                "pingIntervalMs": .stringConvertible(WebSocketSessionHandler.pingInterval.nanoseconds / 1_000_000),
            ])
            return defaultPongTimeout
        }
        let ms = EnvHelpers.getEnvInt(key: EnvKeys.Server.pongTimeoutMs, defaultValue: 0, environment: environment)
        let value = TimeAmount.milliseconds(Int64(clamping: ms))
        return isValidPongTimeout(value) ? value : defaultPongTimeout
    }

    /// The `WS_PONG_TIMEOUT_MS` value when it is set but not a usable pong timeout; nil when it
    /// is unset or valid.
    static func rejectedPongTimeout(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        guard let raw = environment[EnvKeys.Server.pongTimeoutMs] else { return nil }
        let parsed = EnvHelpers.getEnvInt(key: EnvKeys.Server.pongTimeoutMs, defaultValue: 0, environment: environment)
        return isValidPongTimeout(.milliseconds(Int64(clamping: parsed))) ? nil : raw
    }

    /// Whether `value` is a usable pong timeout: positive and below the ping interval, so the
    /// deadline of one ping fires before the next ping is sent.
    public static func isValidPongTimeout(_ value: TimeAmount) -> Bool {
        value > .zero && value < WebSocketSessionHandler.pingInterval
    }

    /// `value` as a valid listen backlog: 0 or below gives `defaultListenBacklog`, and values
    /// above `Int32.max` are capped.
    public static func normalizedListenBacklog(_ value: Int) -> Int {
        guard value > 0 else { return defaultListenBacklog }
        return min(value, Int(Int32.max))
    }

    /// The listen backlog the kernel uses for a requested one (#124). The kernel caps the backlog
    /// at `somaxconn` without telling the application, and drops SYNs once the capped queue is
    /// full, so the startup log reports this instead of only the requested value.
    public struct ListenBacklogCheck: Equatable, Sendable {
        /// The backlog the server asks `listen()` for.
        public let requested: Int
        /// `net.core.somaxconn`, or nil when it could not be read (no `/proc`, as on macOS).
        public let systemCap: Int?

        /// The backlog the kernel queues: the requested value, capped at `systemCap` if known.
        /// When the cap is unread this is the requested value, not a measurement: macOS also caps
        /// the backlog (`kern.ipc.somaxconn`, 128 by default) but has no `/proc` to read it from.
        public var effective: Int { systemCap.map { min(requested, $0) } ?? requested }
        /// Whether the kernel lowers the requested backlog.
        public var isCapped: Bool { systemCap.map { $0 < requested } ?? false }
    }

    /// Where Linux exposes the listen backlog cap.
    static let somaxconnPath = "/proc/sys/net/core/somaxconn"

    /// Checks `requested` against `somaxconn`, read with `read` (a file path to its contents, or
    /// nil if it does not exist). Contents that are not a positive integer count as unread.
    static func listenBacklogCheck(
        requested: Int,
        read: (String) -> String?
    ) -> ListenBacklogCheck {
        let cap = read(somaxconnPath)
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .flatMap { $0 > 0 ? $0 : nil }
        return ListenBacklogCheck(requested: requested, systemCap: cap)
    }

    /// The listen backlog check for `requested` on this host. Only Linux's cap is read; elsewhere
    /// the check is unchecked, which does not mean the kernel queues the requested backlog (macOS
    /// caps it at `kern.ipc.somaxconn`, 128 by default).
    public static func listenBacklogCheck(requested: Int) -> ListenBacklogCheck {
        listenBacklogCheck(requested: requested, read: readSystemFile)
    }

    /// The contents of a small system file, or nil if it does not exist or cannot be read.
    static func readSystemFile(_ path: String) -> String? {
        try? String(contentsOfFile: path, encoding: .utf8)
    }

    public init(
        host: String = "127.0.0.1",
        port: Int = 8080,
        eventLoopThreads: Int = NIOWebSocketServerConfiguration.eventLoopThreads(),
        maxFrameSize: Int = 1 << 24,  // 16MB
        logger: Logger = Logger(label: "com.swiftstatetree.nio"),
        schemaProvider: (@Sendable () -> Data?)? = nil,
        listenBacklog: Int = NIOWebSocketServerConfiguration.listenBacklog(),
        pongTimeout: TimeAmount = NIOWebSocketServerConfiguration.pongTimeout(),
        sendBacklogBound: SendBacklogBound = NIOWebSocketServerConfiguration.sendBacklogBound(),
        inboundBacklogBound: InboundBacklogBound = NIOWebSocketServerConfiguration.inboundBacklogBound()
    ) {
        precondition(
            Self.isValidPongTimeout(pongTimeout),
            "pongTimeout must be positive and below the ping interval (\(WebSocketSessionHandler.pingInterval))"
        )
        self.pongTimeout = pongTimeout
        self.sendBacklogBound = sendBacklogBound
        self.inboundBacklogBound = inboundBacklogBound
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
    /// The transport profiler's counters when profiling is on (`TRANSPORT_PROFILE_JSONL_PATH`;
    /// `profilingConfig` is nil otherwise): the sessions count their pong-timeout closes in it.
    private let profilerCounters: TransportProfilerCounters? = TransportEnvConfig.fromEnvironment()
        .profilingConfig.map { TransportProfilingActor.shared(config: $0).getCounters() }

    private var group: MultiThreadedEventLoopGroup?
    private var serverChannel: Channel?
    private var isRunning: Bool = false

    /// Every hand-off to this server's event loops from another thread goes through it (#351):
    /// sends, closes, inbound resumes and the upgrade's auth result. `shutdown` stops it before
    /// it shuts the group down, so late work (an abandoned land, a disconnect still in flight,
    /// an auth that finishes late) never reaches a shut-down loop.
    let stopFence = StopFence()

    /// Upgrades waiting for their auth (#351). Each promise is completed once: by its auth task,
    /// or failed by `shutdown` while the loops still run.
    private let pendingUpgrades = PendingUpgrades()

    /// Hand-offs the stop fence dropped (late work after the shutdown started).
    var stopFenceDropped: Int { stopFence.droppedCount }

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
        let pongTimeout = self.configuration.pongTimeout
        let sendBacklogBound = self.configuration.sendBacklogBound
        let inboundBacklogBound = self.configuration.inboundBacklogBound
        let profilerCounters = self.profilerCounters
        let stopFence = self.stopFence
        let pendingUpgrades = self.pendingUpgrades

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
                    let upgrade = pendingUpgrades.add(promise)
                    Task {
                        let result: Result<AuthenticatedInfo?, Error>
                        do {
                            result = .success(try await resolver.resolve(path: path, uri: fullURI))
                        } catch {
                            logger.debug("Auth resolution failed", metadata: ["path": .string(path), "error": .string(String(describing: error))])
                            result = .failure(error)
                        }
                        // Through the fence, and only if `shutdown` didn't fail it first: an auth
                        // that finishes after the server stopped completes nothing (#351).
                        stopFence.submit { pendingUpgrades.take(upgrade)?.completeWith(result) }
                    }
                    return promise.futureResult
                        .flatMap { authInfo in
                            channel.pipeline.addHandler(WebSocketSessionHandler(
                                sessionID: sessionID,
                                path: path,
                                transport: transport,
                                authInfo: authInfo,
                                eventLoop: channel.eventLoop,
                                pongTimeout: pongTimeout,
                                profilerCounters: profilerCounters,
                                sendBacklogBound: sendBacklogBound,
                                inboundBacklogBound: inboundBacklogBound,
                                stopFence: stopFence,
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
                    eventLoop: channel.eventLoop,
                    pongTimeout: pongTimeout,
                    profilerCounters: profilerCounters,
                    sendBacklogBound: sendBacklogBound,
                    inboundBacklogBound: inboundBacklogBound,
                    stopFence: stopFence,
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

        let cpus = NIOWebSocketServerConfiguration.availableCPUs()
        let backlog = NIOWebSocketServerConfiguration.listenBacklogCheck(requested: configuration.listenBacklog)
        if backlog.isCapped, let cap = backlog.systemCap {
            configuration.logger.warning(
                "The kernel caps the listen backlog below the requested value; raise net.core.somaxconn to queue more connections",
                metadata: [
                    "listenBacklog": .stringConvertible(backlog.requested),
                    "somaxconn": .stringConvertible(cap),
                    "effectiveListenBacklog": .stringConvertible(backlog.effective),
                ]
            )
        }
        if cpus.affinityMaskUnparsable {
            configuration.logger.warning(
                "Cpus_allowed_list in /proc/self/status did not parse; the CPU count ignores the affinity mask",
                metadata: ["availableCPUs": .stringConvertible(cpus.count), "cpuSource": .string(cpus.source.rawValue)]
            )
        }
        configuration.logger.info(
            "NIO WebSocket server started",
            metadata: [
                "host": .string(configuration.host),
                "port": .stringConvertible(configuration.port),
                "threads": .stringConvertible(configuration.eventLoopThreads),
                // What the default is made of, to check the count against the CPUs the
                // process may use (EVENT_LOOP_THREADS overrides it).
                "availableCPUs": .stringConvertible(cpus.count),
                "cpuSource": .string(cpus.source.rawValue),
                "machineCPUs": .stringConvertible(System.coreCount),
                "eventLoopThreadsEnv": .string(EnvHelpers.getEnvStringOptional(key: EnvKeys.Server.eventLoopThreads) ?? "unset"),
                // Requested; the kernel caps it at somaxconn ("unchecked" where it can't be read).
                "listenBacklog": .stringConvertible(backlog.requested),
                "somaxconn": .string(backlog.systemCap.map(String.init) ?? "unchecked"),
                "effectiveListenBacklog": .stringConvertible(backlog.effective),
                "pongTimeoutMs": .stringConvertible(configuration.pongTimeout.nanoseconds / 1_000_000),
                "sendBacklogMaxBytes": .stringConvertible(configuration.sendBacklogBound.maxBytes),
                "sendBacklogMaxUnwritableMs": .stringConvertible(configuration.sendBacklogBound.maxUnwritable.nanoseconds / 1_000_000),
                "inboundBacklogMaxMessages": .stringConvertible(configuration.inboundBacklogBound.maxMessages),
                "inboundBacklogMaxBytes": .stringConvertible(configuration.inboundBacklogBound.maxBytes),
            ]
        )
    }

    /// Closes the listening socket: no new connection is accepted. Connections already open
    /// stay open. Part of a host shutdown's "stop accepting" step (#351); `shutdown` does it too.
    func stopAccepting() async {
        guard let channel = serverChannel else { return }
        serverChannel = nil
        do {
            try await channel.close()
        } catch {
            configuration.logger.debug("Closing the listener failed", metadata: ["error": .string("\(error)")])
        }
    }

    /// Shuts down the server: closes the listener, fails the upgrades still waiting for their
    /// auth, stops the stop fence, then shuts the event loop group down. From the fence's stop
    /// on, a hand-off from another thread is dropped and counted (#351).
    public func shutdown() async throws {
        guard isRunning else { return }

        await stopAccepting()

        // While the loops still run: an upgrade waiting for its auth is failed now, once, so
        // its promise never outlives its loop. A late auth then finds nothing to complete.
        let pendingUpgrades = self.pendingUpgrades
        stopFence.submit {
            for promise in pendingUpgrades.takeAll() { promise.fail(ServerShuttingDown()) }
        }
        let stillInFlight = await stopFence.stop(cap: .milliseconds(100))
        if stillInFlight > 0 {
            configuration.logger.warning("Stop fence: hand-offs still in flight at its cap", metadata: [
                "inFlight": .stringConvertible(stillInFlight),
            ])
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

/// Upgrades waiting for their auth, by number (#351).
final class PendingUpgrades: @unchecked Sendable {
    private let lock = NSLock()
    private var next: UInt64 = 0
    private var promises: [UInt64: EventLoopPromise<AuthenticatedInfo?>] = [:]

    func add(_ promise: EventLoopPromise<AuthenticatedInfo?>) -> UInt64 {
        lock.lock(); defer { lock.unlock() }
        next += 1
        promises[next] = promise
        return next
    }

    func take(_ id: UInt64) -> EventLoopPromise<AuthenticatedInfo?>? {
        lock.lock(); defer { lock.unlock() }
        return promises.removeValue(forKey: id)
    }

    func takeAll() -> [EventLoopPromise<AuthenticatedInfo?>] {
        lock.lock(); defer { lock.unlock() }
        let all = Array(promises.values)
        promises.removeAll()
        return all
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return promises.count
    }
}

/// An upgrade failed because the server is shutting down.
struct ServerShuttingDown: Error {}

/// A one-shot flag: the first `claim()` returns true, every later one false.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false

    func claim() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !claimed else { return false }
        claimed = true
        return true
    }
}

extension NIOWebSocketServerConfiguration {
    /// The rejected `WS_PONG_TIMEOUT_MS` warning is logged once per process.
    static let rejectedPongTimeoutWarning = OnceFlag()
}
