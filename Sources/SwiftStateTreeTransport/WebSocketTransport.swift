import Foundation
import Logging
import SwiftStateTree

// MARK: - WebSocket Transport Send Queue

/// Lock-based queue for non-blocking enqueue. Drain task batches and dispatches to the actor.
private final class WebSocketTransportSendQueue: @unchecked Sendable, TransportSendQueue {
    private let lock = NSLock()
    private var buffer: [(Data, EventTarget)] = []
    private let maxBatchSize: Int
    private let drainIntervalNanoseconds: UInt64

    init(maxBatchSize: Int = 64, drainIntervalMs: Double = 1.0) {
        self.maxBatchSize = maxBatchSize
        self.drainIntervalNanoseconds = UInt64(drainIntervalMs * 1_000_000)
    }

    func enqueue(_ message: Data, to target: EventTarget) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append((message, target))
    }

    func enqueueBatch(_ updates: [(Data, EventTarget)]) {
        guard !updates.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        buffer.append(contentsOf: updates)
    }

    /// Remove and return up to maxBatchSize items. Capacity is reused for the returned array.
    func drainBatch() -> [(Data, EventTarget)] {
        lock.lock()
        defer { lock.unlock() }
        guard !buffer.isEmpty else { return [] }
        let count = min(buffer.count, maxBatchSize)
        var batch: [(Data, EventTarget)] = []
        batch.reserveCapacity(count)
        for i in 0..<count {
            batch.append(buffer[i])
        }
        buffer.removeFirst(count)
        return batch
    }
}

// MARK: - Per-Session Send Queue

/// Per-session send queue: enqueue returns immediately; a drain Task sends to the connection.
private struct SessionSendQueue: Sendable {
    let connection: WebSocketConnection
    let continuation: AsyncStream<Data>.Continuation
    let drainTask: Task<Void, Never>

    static func create(sessionID: SessionID, connection: WebSocketConnection, logger: Logger) -> Self {
        var continuation: AsyncStream<Data>.Continuation!
        let stream = AsyncStream(Data.self) { continuation = $0 }
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

    /// Queue-based send path: producers enqueue without await; drain task batches and dispatches.
    private let sendQueue: WebSocketTransportSendQueue
    /// Drain task started in init; must be nonisolated(unsafe) for init assignment.
    private nonisolated(unsafe) var drainTask: Task<Void, Never>?
    private static let drainBatchSize = 64
    private static let drainIntervalNanoseconds: UInt64 = 1_000_000  // 1 ms

    private static let missingTargetLogIntervalSeconds: TimeInterval = 2.0
    private static let missingTargetLogMapSoftLimit: Int = 5000

    /// Non-blocking send queue. When set, TransportAdapter uses enqueueBatch instead of await sendBatch.
    public nonisolated var transportSendQueue: (any TransportSendQueue)? { sendQueue }

    public init(logger: Logger? = nil) {
        // Create logger with scope if not provided
        if let logger = logger {
            self.logger = logger.withScope("WebSocketTransport")
        } else {
            self.logger = createColoredLogger(
                loggerIdentifier: "com.swiftstatetree.websocket",
                scope: "WebSocketTransport"
            )
        }
        self.sendQueue = WebSocketTransportSendQueue(
            maxBatchSize: Self.drainBatchSize,
            drainIntervalMs: Double(Self.drainIntervalNanoseconds) / 1_000_000
        )
        let sq = self.sendQueue
        self.drainTask = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let batch = sq.drainBatch()
                if !batch.isEmpty {
                    await self.dispatchBatch(batch)
                } else {
                    try? await Task.sleep(nanoseconds: Self.drainIntervalNanoseconds)
                }
            }
        }
    }

    /// Set delegate from outside the actor.
    public func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }

    public func start() async throws {
        logger.info("WebSocketTransport started")
    }

    public func stop() async throws {
        drainTask?.cancel()
        drainTask = nil
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

    /// Enqueue message and return. Drain Tasks send to connections asynchronously.
    public func send(_ message: Data, to target: EventTarget) {
        logOutgoing(message, target: target)

        switch target {
        case let .session(sessionID):
            guard let queue = sessionQueues[sessionID] else {
                logDropMissingSession(sessionID: sessionID, bytes: message.count)
                return
            }
            queue.continuation.yield(message)

        case let .player(playerID):
            guard let sessionIDs = playerSessions[playerID] else {
                logDropMissingPlayer(playerID: playerID, bytes: message.count)
                return
            }
            for sessionID in sessionIDs {
                sessionQueues[sessionID]?.continuation.yield(message)
            }

        case .broadcast:
            for queue in sessionQueues.values {
                queue.continuation.yield(message)
            }

        case let .broadcastExcept(excludedSessionID):
            for (id, queue) in sessionQueues where id != excludedSessionID {
                queue.continuation.yield(message)
            }
        }
    }

    /// Batch send: yields all messages in one actor call to reduce contention.
    public func sendBatch(_ updates: [(Data, EventTarget)]) async {
        dispatchBatch(updates)
    }

    /// Internal: dispatch batch to session queues. Used by drain task and sendBatch.
    private func dispatchBatch(_ updates: [(Data, EventTarget)]) {
        for (message, target) in updates {
            logOutgoing(message, target: target)
            switch target {
            case let .session(sessionID):
                if let queue = sessionQueues[sessionID] {
                    queue.continuation.yield(message)
                } else {
                    logDropMissingSession(sessionID: sessionID, bytes: message.count)
                }
            case let .player(playerID):
                if let sessionIDs = playerSessions[playerID] {
                    for sessionID in sessionIDs {
                        sessionQueues[sessionID]?.continuation.yield(message)
                    }
                } else {
                    logDropMissingPlayer(playerID: playerID, bytes: message.count)
                }
            case .broadcast:
                for queue in sessionQueues.values {
                    queue.continuation.yield(message)
                }
            case let .broadcastExcept(excludedSessionID):
                for (id, queue) in sessionQueues where id != excludedSessionID {
                    queue.continuation.yield(message)
                }
            }
        }
    }

    // MARK: - Connection Management (Called by the concrete server integration)

    public func handleConnection(sessionID: SessionID, connection: WebSocketConnection, authInfo: AuthenticatedInfo? = nil) async {
        let queue = SessionSendQueue.create(sessionID: sessionID, connection: connection, logger: logger)
        sessionQueues[sessionID] = queue
        lastMissingSessionLogAt.removeValue(forKey: sessionID)
        // Generate short client ID (6 characters) for better identification
        let clientIDString = String(UUID().uuidString.prefix(6))
        let clientID = ClientID(clientIDString)
        sessionToClientID[sessionID] = clientID
        await delegate?.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    public func handleDisconnection(sessionID: SessionID) async {
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

    public func registerSession(_ sessionID: SessionID, for playerID: PlayerID) {
        playerSessions[playerID, default: []].insert(sessionID)
        lastMissingPlayerLogAt.removeValue(forKey: playerID)
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
