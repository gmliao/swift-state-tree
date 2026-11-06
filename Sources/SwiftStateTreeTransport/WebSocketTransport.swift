import Foundation
import Logging
import SwiftStateTree

// MARK: - Per-Session Send Queue

/// Per-session send queue: enqueue returns immediately; a drain Task sends to the connection.
private struct SessionSendQueue: Sendable {
    let connection: WebSocketConnection
    /// Connection generation (see `WebSocketTransport.connectionGeneration(for:)`).
    var generation: UInt64 = 0
    let continuation: AsyncStream<Data>.Continuation
    let drainTask: Task<Void, Never>

    static func create(sessionID: SessionID, connection: WebSocketConnection, logger: Logger) -> Self {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream(Data.self) { continuation = $0 }
        let streamContinuation: AsyncStream<Data>.Continuation = continuation
        let drainTask = Task {
            for await data in stream {
                do {
                    try await connection.send(data)
                } catch {
                    if logger.logLevel <= .debug {
                        logger.debug("WS drain send failed (connection likely closed)", metadata: [
                            "session": .string(sessionID.rawValue),
                            "error": .string("\(error)"),
                        ])
                    }
                    // Finish the stream: later yields are dropped instead of buffering until
                    // the disconnect (#61).
                    streamContinuation.finish()
                    break
                }
            }
        }
        return Self(connection: connection, continuation: continuation, drainTask: drainTask)
    }
}

/// A Transport implementation using WebSockets.
///
/// Uses per-session queues: Adapter enqueues and returns immediately; drain Tasks send to connections.
/// This is a base implementation that needs to be connected to a concrete WebSocket server
/// (e.g., Vapor, Hummingbird, or NIO).
public actor WebSocketTransport: Transport {
    public var delegate: TransportDelegate?

    private var sessionQueues: [SessionID: SessionSendQueue] = [:]
    private var sessionToClientID: [SessionID: ClientID] = [:]
    private var playerSessions: [PlayerID: Set<SessionID>] = [:]
    private var lastMissingSessionLogAt: [SessionID: Date] = [:]
    private var lastMissingPlayerLogAt: [PlayerID: Date] = [:]
    private let logger: Logger

    /// Generation of the most recent connection; each `handleConnection` takes the next one.
    private var lastConnectionGeneration: UInt64 = 0
    /// Sessions closed by `closeSession` whose server's own disconnect callback has not arrived
    /// yet; that callback must not notify the delegate a second time.
    private var serverClosedSessions: Set<SessionID> = []

    /// How long `closeSession` waits for the server's own disconnect callback before it logs
    /// the close as unconfirmed and forgets the session.
    private(set) var serverCloseConfirmTimeout: Duration = .seconds(10)

    /// Override the close-confirmation timeout (tests).
    func setServerCloseConfirmTimeout(_ timeout: Duration) {
        serverCloseConfirmTimeout = timeout
    }

    private static let missingTargetLogIntervalSeconds: TimeInterval = 2.0
    private static let missingTargetLogMapSoftLimit: Int = 5000

    /// Always `nil`: the polling send queue was removed. Each `TransportAdapter` sends through its
    /// own ordered `OutboundWriter` (#60).
    @available(*, deprecated, message: "TransportAdapter sends through its own OutboundWriter; this is always nil")
    public nonisolated var transportSendQueue: (any TransportSendQueue)? { nil }

    /// - Parameters:
    ///   - logger: Optional logger. If nil, a default colored logger is created.
    ///   - drainIntervalMs: Ignored. It tuned the removed polling send queue; kept for source
    ///     compatibility.
    public init(logger: Logger? = nil, drainIntervalMs: Double = 0.2) {
        // Create logger with scope if not provided
        if let logger = logger {
            self.logger = logger.withScope("WebSocketTransport")
        } else {
            self.logger = createColoredLogger(
                loggerIdentifier: "com.swiftstatetree.websocket",
                scope: "WebSocketTransport"
            )
        }
        _ = drainIntervalMs
    }

    /// Set delegate from outside the actor.
    public func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    public func start() async throws {
        logger.info("WebSocketTransport started")
    }

    public func stop() async throws {
        // Finish all continuations so drain tasks exit, then close connections
        for (_, queue) in sessionQueues {
            queue.continuation.finish()
            queue.drainTask.cancel()
            try? await queue.connection.close()
        }
        sessionQueues.removeAll()
        sessionToClientID.removeAll()
        playerSessions.removeAll()
        logger.info("WebSocketTransport stopped")
    }

    /// Frames yielded to a session queue whose stream was already finished (its drain task's send
    /// failed): dropped, not buffered (#61). Diagnostics.
    private(set) var framesDroppedAfterSendFailure = 0

    /// Yields `data` to the session's stream; counts it when the stream is finished.
    private func enqueue(_ data: Data, into queue: SessionSendQueue) {
        if case .terminated = queue.continuation.yield(data) {
            framesDroppedAfterSendFailure += 1
        }
    }

    /// The drain task of the session's current queue (tests).
    func sendQueueDrainTaskForTesting(_ sessionID: SessionID) -> Task<Void, Never>? {
        sessionQueues[sessionID]?.drainTask
    }

    /// Enqueue message and return. Drain Tasks send to connections asynchronously.
    public func send(_ message: Data, to target: EventTarget) {
        logOutgoing(message, target: target)

        switch target {
        case let .session(sessionID):
            guard let queue = sessionQueues[sessionID] else {
                logDropMissingSession(sessionID: sessionID, bytes: message.count)
                return
            }
            enqueue(message, into: queue)

        case let .player(playerID):
            guard let sessionIDs = playerSessions[playerID] else {
                logDropMissingPlayer(playerID: playerID, bytes: message.count)
                return
            }
            for sessionID in sessionIDs {
                if let queue = sessionQueues[sessionID] { enqueue(message, into: queue) }
            }

        case .broadcast:
            for queue in sessionQueues.values {
                enqueue(message, into: queue)
            }

        case let .broadcastExcept(excludedSessionID):
            for (id, queue) in sessionQueues where id != excludedSessionID {
                enqueue(message, into: queue)
            }
        }
    }

    /// Batch send: yields all messages in one actor call to reduce contention.
    public func sendBatch(_ updates: [(Data, EventTarget)]) async {
        dispatchBatch(updates)
    }

    /// Internal: dispatch batch to session queues. Used by sendBatch.
    private func dispatchBatch(_ updates: [(Data, EventTarget)]) {
        for (message, target) in updates {
            logOutgoing(message, target: target)
            switch target {
            case let .session(sessionID):
                if let queue = sessionQueues[sessionID] {
                    enqueue(message, into: queue)
                } else {
                    logDropMissingSession(sessionID: sessionID, bytes: message.count)
                }
            case let .player(playerID):
                if let sessionIDs = playerSessions[playerID] {
                    for sessionID in sessionIDs {
                        if let queue = sessionQueues[sessionID] { enqueue(message, into: queue) }
                    }
                } else {
                    logDropMissingPlayer(playerID: playerID, bytes: message.count)
                }
            case .broadcast:
                for queue in sessionQueues.values {
                    enqueue(message, into: queue)
                }
            case let .broadcastExcept(excludedSessionID):
                for (id, queue) in sessionQueues where id != excludedSessionID {
                    enqueue(message, into: queue)
                }
            }
        }
    }

    // MARK: - Connection Management (Called by the concrete server integration)

    public func handleConnection(sessionID: SessionID, connection: WebSocketConnection, authInfo: AuthenticatedInfo? = nil) async {
        // A reused SessionID replaces its queue: end the old one's stream and drain task, which
        // would otherwise outlive it (#61).
        if let previous = sessionQueues[sessionID] {
            previous.continuation.finish()
            previous.drainTask.cancel()
        }
        var queue = SessionSendQueue.create(sessionID: sessionID, connection: connection, logger: logger)
        lastConnectionGeneration += 1
        queue.generation = lastConnectionGeneration
        sessionQueues[sessionID] = queue
        lastMissingSessionLogAt.removeValue(forKey: sessionID)
        // Generate short client ID (6 characters) for better identification
        let clientIDString = String(UUID().uuidString.prefix(6))
        let clientID = ClientID(clientIDString)
        sessionToClientID[sessionID] = clientID
        await delegate?.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    public func handleDisconnection(sessionID: SessionID) async {
        if sessionQueues[sessionID] == nil, serverClosedSessions.remove(sessionID) != nil {
            // Already handled by `closeSession`; this is the server's own callback for it.
            return
        }
        if let queue = sessionQueues[sessionID] {
            queue.continuation.finish()
            queue.drainTask.cancel()
        }
        sessionQueues.removeValue(forKey: sessionID)
        let clientID = sessionToClientID.removeValue(forKey: sessionID) ?? ClientID("disconnected")
        // Cleanup player mapping
        for (playerID, sessionIDs) in playerSessions {
            if sessionIDs.contains(sessionID) {
                playerSessions[playerID]?.remove(sessionID)
                if playerSessions[playerID]?.isEmpty == true {
                    playerSessions.removeValue(forKey: playerID)
                }
            }
        }
        await delegate?.onDisconnect(sessionID: sessionID, clientID: clientID)
    }

    public func handleIncomingMessage(sessionID: SessionID, data: Data) async {
        logIncoming(data, from: sessionID)
        await delegate?.onMessage(data, from: sessionID)
    }

    /// Maps a player to a session for `.player` targets, and returns the session's current
    /// connection generation (`nil` when the session is not connected).
    @discardableResult
    public func registerSession(_ sessionID: SessionID, for playerID: PlayerID) -> UInt64? {
        playerSessions[playerID, default: []].insert(sessionID)
        lastMissingPlayerLogAt.removeValue(forKey: playerID)
        return sessionQueues[sessionID]?.generation
    }

    /// Closes the session's connection from the server side: the delegate is told the session
    /// disconnected (as for a client close), then the connection is closed.
    public func closeSession(_ sessionID: SessionID) async {
        guard let queue = sessionQueues[sessionID] else { return }
        serverClosedSessions.insert(sessionID)
        await handleDisconnection(sessionID: sessionID)
        try? await queue.connection.close()
        let timeout = serverCloseConfirmTimeout
        Task { [weak self] in
            try? await safeTaskSleep(for: timeout)
            await self?.expireUnconfirmedServerClose(sessionID)
        }
    }

    /// The server never reported the closed connection as disconnected: log it and stop
    /// waiting, so the set does not grow with connections whose callback never comes.
    private func expireUnconfirmedServerClose(_ sessionID: SessionID) {
        guard sessionQueues[sessionID] == nil, serverClosedSessions.remove(sessionID) != nil else { return }
        logger.warning("Server-closed session was not confirmed by a disconnect callback", metadata: [
            "session": .string(sessionID.rawValue),
            "timeout": .string("\(serverCloseConfirmTimeout)"),
        ])
    }

    /// Sessions closed by `closeSession` still waiting for the server's disconnect callback (tests).
    func pendingServerClosedSessionCount() -> Int {
        serverClosedSessions.count
    }

    public nonisolated var supportsCloseSession: Bool { true }

    /// Generation of the session's current connection, or `nil` when it is not connected.
    ///
    /// Every `handleConnection` gives the connection a new generation, also when it reuses a
    /// `SessionID`. Frames stamped with an older generation are dropped by `sendSessionFrames`.
    public func connectionGeneration(for sessionID: SessionID) -> UInt64? {
        sessionQueues[sessionID]?.generation
    }

    /// Sends single-session frames in order. A frame whose `connectionGeneration` is set and
    /// differs from the session's current connection is dropped: it was produced for a connection
    /// that has ended.
    public func sendSessionFrames(_ frames: [SessionFrame]) async {
        for frame in frames {
            logOutgoing(frame.data, target: .session(frame.sessionID))
            guard let queue = sessionQueues[frame.sessionID] else {
                logDropMissingSession(sessionID: frame.sessionID, bytes: frame.data.count)
                continue
            }
            if let generation = frame.connectionGeneration, generation != queue.generation {
                if logger.logLevel <= .debug {
                    logger.debug("Dropping frame for an ended connection", metadata: [
                        "session": .string(frame.sessionID.rawValue),
                        "frameGeneration": .stringConvertible(generation),
                        "currentGeneration": .stringConvertible(queue.generation),
                    ])
                }
                continue
            }
            enqueue(frame.data, into: queue)
        }
    }

    // MARK: - Logging helpers

    //
    /// Logging strategy:
    /// - `debug` level logs a compact summary (direction, target/session, byte size).
    /// - `trace` level logs a best‑effort UTF‑8 preview of the full payload.
    ///
    /// To see detailed payload logs in your application, configure the logger that is
    /// passed into `WebSocketTransport` (or `LandServer`) with `.logLevel = .trace`.

    private func logIncoming(_ data: Data, from sessionID: SessionID) {
        let size = data.count

        if logger.logLevel <= .debug {
            logger.debug("WS ⇦ receive", metadata: [
                "session": .string(sessionID.rawValue),
                "bytes": .string("\(size)"),
            ])
        }

        // Log payload - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: data) {
            logger.trace("WS ⇦ payload", metadata: [
                "session": .string(sessionID.rawValue),
                "payload": .string(preview),
            ])
        }
    }

    private func logOutgoing(_ data: Data, target: EventTarget) {
        let size = data.count

        let targetDescription: String = {
            switch target {
            case let .session(id):
                return "session(\(id.rawValue))"
            case let .player(id):
                return "player(\(id.rawValue))"
            case .broadcast:
                return "broadcast"
            case let .broadcastExcept(id):
                return "broadcastExcept(\(id.rawValue))"
            }
        }()

        if logger.logLevel <= .trace {
            logger.trace("WS ⇨ send", metadata: [
                "target": .string(targetDescription),
                "bytes": .string("\(size)"),
            ])
        }

        // Log payload - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: data) {
            logger.trace("WS ⇨ payload", metadata: [
                "target": .string(targetDescription),
                "payload": .string(preview),
            ])
        }
    }

    private func logDropMissingSession(sessionID: SessionID, bytes: Int) {
        if lastMissingSessionLogAt.count > Self.missingTargetLogMapSoftLimit {
            lastMissingSessionLogAt.removeAll()
        }

        let now = Date()
        if let last = lastMissingSessionLogAt[sessionID],
           now.timeIntervalSince(last) < Self.missingTargetLogIntervalSeconds
        {
            return
        }
        lastMissingSessionLogAt[sessionID] = now

        if logger.logLevel <= .debug {
            logger.debug("WS ⇨ drop (session not found)", metadata: [
                "session": .string(sessionID.rawValue),
                "bytes": .string("\(bytes)"),
            ])
        }
    }

    private func logDropMissingPlayer(playerID: PlayerID, bytes: Int) {
        if lastMissingPlayerLogAt.count > Self.missingTargetLogMapSoftLimit {
            lastMissingPlayerLogAt.removeAll()
        }

        let now = Date()
        if let last = lastMissingPlayerLogAt[playerID],
           now.timeIntervalSince(last) < Self.missingTargetLogIntervalSeconds
        {
            return
        }
        lastMissingPlayerLogAt[playerID] = now

        if logger.logLevel <= .debug {
            logger.debug("WS ⇨ drop (player has no sessions)", metadata: [
                "player": .string(playerID.rawValue),
                "bytes": .string("\(bytes)"),
            ])
        }
    }
}

/// Abstract interface for a WebSocket connection
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func close() async throws
}
