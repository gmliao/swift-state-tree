import Foundation
import Logging
import SwiftStateTree

// MARK: - Per-Session Send Queue

/// One element of a session's send stream: a frame, the marker after which the session is
/// closed (`WebSocketTransport.closeSessionAfterQueuedFrames`), or a flush marker
/// (`WebSocketTransport.flushSessionQueues`), whose waiter resumes when the drain reaches it.
private enum SessionSendElement: Sendable {
    case data(Data)
    case close
    case flush(UInt64)
}

/// A session queue's flush markers (`flushSessionQueues`). A marker is registered and yielded
/// first, then waited on; it is done when the drain reaches it, or when the drain is retired
/// (`endAll`), since markers left in the stream then are never read. A drain stuck in a send
/// keeps its task alive past its cancellation, so the retiring code calls `endAll` itself rather
/// than leaving it to the drain's exit.
private final class SessionFlushWaiters: @unchecked Sendable {
    private enum Entry {
        case pending
        case waiting(CheckedContinuation<Void, Never>)
    }

    private let lock = NSLock()
    private var entries: [UInt64: Entry] = [:]
    private var nextID: UInt64 = 0
    private var ended = false

    /// A new pending marker's ID; nil once the queue is retired or its drain has ended.
    func register() -> UInt64? {
        lock.withLock {
            guard !ended else { return nil }
            let id = nextID
            nextID += 1
            entries[id] = .pending
            return id
        }
    }

    /// Marker `id` is done: its waiter, if it is waiting already, resumes.
    func resume(_ id: UInt64) {
        let entry = lock.withLock { entries.removeValue(forKey: id) }
        if case .waiting(let waiter) = entry {
            waiter.resume()
        }
    }

    /// Returns once marker `id` is done (at once if it is already).
    func wait(_ id: UInt64) async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let stored: Bool = lock.withLock {
                guard case .pending = entries[id] else { return false }
                entries[id] = .waiting(waiter)
                return true
            }
            if !stored {
                waiter.resume()
            }
        }
    }

    /// Markers registered and not yet done (tests).
    var pendingCount: Int {
        lock.withLock { entries.count }
    }

    /// Every marker is done, and later `register`s return nil. Idempotent.
    func endAll() {
        let all = lock.withLock {
            ended = true
            let all = Array(entries.values)
            entries.removeAll()
            return all
        }
        for case .waiting(let waiter) in all {
            waiter.resume()
        }
    }
}

/// Per-session send queue: enqueue returns immediately; a drain Task sends to the connection.
private struct SessionSendQueue: Sendable {
    let connection: WebSocketConnection
    /// Connection generation (see `WebSocketTransport.connectionGeneration(for:)`).
    var generation: UInt64 = 0
    let continuation: AsyncStream<SessionSendElement>.Continuation
    let drainTask: Task<Void, Never>
    fileprivate let flushWaiters: SessionFlushWaiters
    /// A close marker was yielded: later frames are dropped and counted
    /// (`framesDroppedAfterCloseMarker`), never sent after the marker.
    var closeMarkerYielded = false

    /// - Parameter onCloseMarker: Run by the drain when it reaches a close marker, after every
    ///   frame queued before it was handed to the connection.
    static func create(
        sessionID: SessionID,
        connection: WebSocketConnection,
        logger: Logger,
        onCloseMarker: @escaping @Sendable () async -> Void
    ) -> Self {
        var continuation: AsyncStream<SessionSendElement>.Continuation!
        let stream = AsyncStream(SessionSendElement.self) { continuation = $0 }
        let flushWaiters = SessionFlushWaiters()
        let drainTask = Task {
            // However the drain ends, no flush marker behind it is read: release their waiters.
            defer { flushWaiters.endAll() }
            for await element in stream {
                let data: Data
                switch element {
                case .data(let frame):
                    data = frame
                case .close:
                    await onCloseMarker()
                    return
                case .flush(let id):
                    flushWaiters.resume(id)
                    continue
                }
                do {
                    try await connection.send(data)
                } catch {
                    if logger.logLevel <= .debug {
                        logger.debug("WS drain send failed (connection likely closed)", metadata: [
                            "session": .string(sessionID.rawValue),
                            "error": .string("\(error)"),
                        ])
                    }
                    // Ending the loop ends the task, which releases the stream: later yields
                    // return `.terminated` and are counted as dropped (#61).
                    break
                }
            }
        }
        return Self(connection: connection, continuation: continuation, drainTask: drainTask, flushWaiters: flushWaiters)
    }

    /// Yields a flush marker behind every frame queued so far and returns its ID, for
    /// `waitForFlush`; nil when the queue is retired or its drain has ended (nothing to wait for).
    func queueFlushMarker() -> UInt64? {
        guard let id = flushWaiters.register() else { return nil }
        // A drain that already ended on a failed send released the stream: the marker is done
        // (as `closeSessionAfterQueuedFrames` treats `.terminated`).
        if case .terminated = continuation.yield(.flush(id)) {
            flushWaiters.resume(id)
        }
        return id
    }

    /// Returns once the drain has reached marker `id`, or the queue was retired.
    func waitForFlush(_ id: UInt64) async {
        await flushWaiters.wait(id)
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
    /// the close as unconfirmed and forgets the session. A close with a grace waits that much
    /// longer (`serverCloseConfirmDeadline(for:)`).
    private(set) var serverCloseConfirmTimeout: Duration = .seconds(10)

    /// Override the close-confirmation timeout (tests).
    func setServerCloseConfirmTimeout(_ timeout: Duration) {
        serverCloseConfirmTimeout = timeout
    }

    /// Runs `expire` after `deadline`: in a Task after a sleep, or, in tests, whenever the test
    /// calls it, so the order against the disconnect callback is the test's.
    typealias ServerCloseExpiry = @Sendable (_ deadline: Duration, _ expire: @escaping @Sendable () async -> Void) -> Void
    private var scheduleServerCloseExpiry: ServerCloseExpiry = { deadline, expire in
        Task {
            try? await safeTaskSleep(for: deadline)
            await expire()
        }
    }

    func setServerCloseExpiryForTesting(_ schedule: @escaping ServerCloseExpiry) {
        scheduleServerCloseExpiry = schedule
    }

    /// Server closes expired without their disconnect callback (tests).
    private(set) var unconfirmedServerClosesForTesting = 0

    /// How long `closeSession` waits for `close`'s disconnect callback: the confirm timeout plus
    /// the close's grace (#339). The channel stays open for the grace after the close frame is
    /// written, so a fixed timeout shorter than the grace would forget the session while its
    /// channel is still open, and its callback would then notify the delegate a second time.
    func serverCloseConfirmDeadline(for close: SessionClose) -> Duration {
        serverCloseConfirmTimeout + max(.zero, close.closeGrace ?? .zero)
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
        await stop(closingWith: nil)
    }

    /// `stop()`, closing each connection still held with `close` (`nil`: the connection's
    /// default close). A server shutdown passes 1001 Going Away (#351), so a session its
    /// close-sessions step cut gets the same close as the others.
    package func stop(closingWith close: SessionClose?) async {
        // Finish all continuations so drain tasks exit, then close connections
        for (_, queue) in sessionQueues {
            queue.continuation.finish()
            queue.drainTask.cancel()
            // A drain stuck in a send outlives its cancellation: release its flush waiters now.
            queue.flushWaiters.endAll()
            if let close {
                try? await queue.connection.close(with: close)
            } else {
                try? await queue.connection.close()
            }
        }
        sessionQueues.removeAll()
        sessionToClientID.removeAll()
        playerSessions.removeAll()
        logger.info("WebSocketTransport stopped")
    }

    /// Frames yielded to a session queue whose stream has terminated (its drain task ended at a
    /// failed send): dropped, not buffered (#61). Diagnostics.
    private(set) var framesDroppedAfterSendFailure = 0

    /// Frames for a session whose close marker was already yielded: dropped, since the session
    /// closes at the marker. Diagnostics.
    public private(set) var framesDroppedAfterCloseMarker = 0

    /// Frames for a session the transport doesn't hold, and session frames stamped with an
    /// ended connection's generation: dropped. Diagnostics.
    private(set) var framesDroppedMissingSession = 0
    private(set) var framesDroppedStaleGeneration = 0

    /// `framesDroppedMissingSession` per session, kept only after
    /// `recordMissingSessionDropsBySessionForTesting()` (tests): the transport-wide count also
    /// counts frames for other sessions that a test ends on purpose (#259).
    private(set) var missingSessionDropsBySession: [SessionID: Int]?

    func recordMissingSessionDropsBySessionForTesting() {
        if missingSessionDropsBySession == nil { missingSessionDropsBySession = [:] }
    }

    private func countMissingSessionDrop(_ sessionID: SessionID) {
        framesDroppedMissingSession += 1
        missingSessionDropsBySession?[sessionID, default: 0] += 1
    }

    /// Connections rejected by `handleConnection` because their `SessionID` was still held.
    public private(set) var connectionsRejectedSessionIDInUse = 0

    /// Yields `data` to the session's stream; counts it when the stream is finished, or when the
    /// session's close marker is already queued.
    private func enqueue(_ data: Data, into queue: SessionSendQueue) {
        if queue.closeMarkerYielded {
            framesDroppedAfterCloseMarker += 1
            return
        }
        if case .terminated = queue.continuation.yield(.data(data)) {
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
                countMissingSessionDrop(sessionID)
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

    /// Registers a new connection under `sessionID`, unless the transport still holds that ID.
    ///
    /// **One `SessionID` per connection.** Every per-session map here and in the router and
    /// adapter is keyed by `SessionID`, so callers must pass a fresh ID for every connection (the
    /// NIO server makes a new UUID per connection). An ID is held while its session is connected,
    /// while its `handleDisconnection` runs (the delegate's cleanup included), and while a
    /// server close waits for the server's own disconnect callback. A connection whose ID is held
    /// is rejected: closed at once, with no queue, no client ID and no `onConnect`. Reusing an ID
    /// after its session is fully gone is outside the contract and isn't detected; async work of
    /// the old session (a join wait, a drain, a keeper await) could then act on the new one.
    ///
    /// **After a rejection, the caller must not call `handleIncomingMessage` or
    /// `handleDisconnection` for that connection:** both are keyed by the ID, and would act on
    /// the session that holds it.
    @discardableResult
    public func handleConnection(sessionID: SessionID, connection: WebSocketConnection, authInfo: AuthenticatedInfo? = nil) async -> ConnectionAcceptance {
        if isHeld(sessionID) {
            connectionsRejectedSessionIDInUse += 1
            logger.warning("Connection rejected: its SessionID is still in use", metadata: [
                "session": .string(sessionID.rawValue),
            ])
            try? await connection.close()
            return .rejected(.sessionIDInUse)
        }
        var queue = SessionSendQueue.create(
            sessionID: sessionID,
            connection: connection,
            logger: logger,
            // In a Task of its own: `closeSession` cancels the drain task this runs on, and the
            // delegate's cleanup must not run in a cancelled task.
            onCloseMarker: { [weak self] in Task { await self?.closeSession(sessionID) } }
        )
        lastConnectionGeneration += 1
        queue.generation = lastConnectionGeneration
        sessionQueues[sessionID] = queue
        lastMissingSessionLogAt.removeValue(forKey: sessionID)
        // Generate short client ID (6 characters) for better identification
        let clientIDString = String(UUID().uuidString.prefix(6))
        let clientID = ClientID(clientIDString)
        sessionToClientID[sessionID] = clientID
        await delegate?.onConnect(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
        return .accepted
    }

    /// Whether `sessionID` is held: connected, being disconnected, or closed by the server and
    /// waiting for its disconnect callback (see `handleConnection`).
    private func isHeld(_ sessionID: SessionID) -> Bool {
        sessionQueues[sessionID] != nil || closingSessions.contains(sessionID) || serverClosedSessions.contains(sessionID)
    }

    /// Sessions whose `handleDisconnection` is running: the queue may already be gone, but the
    /// delegate is still cleaning up, so the ID stays held.
    private var closingSessions: Set<SessionID> = []

    public func handleDisconnection(sessionID: SessionID) async {
        if sessionQueues[sessionID] == nil, serverClosedSessions.remove(sessionID) != nil {
            // Already handled by `closeSession`; this is the server's own callback for it.
            return
        }
        closingSessions.insert(sessionID)
        defer { closingSessions.remove(sessionID) }
        if let queue = sessionQueues[sessionID] {
            queue.continuation.finish()
            queue.drainTask.cancel()
            // A drain stuck in a send outlives its cancellation: release its flush waiters now.
            queue.flushWaiters.endAll()
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

    /// Returns once every current session's drain has handed its connection the frames queued
    /// before this call (for a benchmark that reads what its connections received). A session
    /// whose drain has ended (a failed send, a close marker, its removal) counts as flushed;
    /// sessions connected during the call aren't waited for. Event-driven: a flush marker per
    /// session, resumed by its drain.
    @_spi(Diagnostics) public func flushSessionQueues() async {
        // Every marker is yielded in this turn, before any wait: a frame queued after the call
        // lands behind its session's marker.
        let markers = sessionQueues.values.compactMap { queue in
            queue.queueFlushMarker().map { (queue, $0) }
        }
        if let hook = flushMarkersQueuedForTesting {
            await hook()
        }
        await withTaskGroup(of: Void.self) { group in
            for (queue, id) in markers {
                group.addTask { await queue.waitForFlush(id) }
            }
        }
    }

    /// Runs in `flushSessionQueues` after its markers are queued and before it waits (tests: a
    /// hold there orders a disconnect or a send against the queued markers).
    private var flushMarkersQueuedForTesting: (@Sendable () async -> Void)?

    func setFlushMarkersQueuedForTesting(_ hook: (@Sendable () async -> Void)?) {
        flushMarkersQueuedForTesting = hook
    }

    /// Flush markers registered over every current session and not yet done (tests).
    func pendingFlushMarkersForTesting() -> Int {
        sessionQueues.values.reduce(0) { $0 + $1.flushWaiters.pendingCount }
    }

    /// Closes the session once every frame queued for it so far has been handed to the
    /// connection, or after `timeout` if the drain doesn't get there (a client that stopped
    /// reading). Both end in `closeSession`, so the session is closed once. Frames queued after
    /// this call are dropped and counted. On NIO, "handed to the connection" means written to
    /// the channel before the close: a stalled client may still not receive them.
    ///
    /// `async` to match the requirement exactly: from an async caller holding the concrete type,
    /// a synchronous method loses overload resolution to the protocol extension's `async`
    /// default, which closes at once.
    public func closeSessionAfterQueuedFrames(_ sessionID: SessionID) async {
        closeSessionAfterQueuedFrames(sessionID, timeout: JoinFlipConfig.finalFrameCloseTimeout)
    }

    /// Only while the session's connection is the one with `generation` (nil: any); its delayed
    /// close (the bound) checks the generation again.
    public func closeSessionAfterQueuedFrames(_ sessionID: SessionID, generation: UInt64?) async {
        closeSessionAfterQueuedFrames(sessionID, timeout: JoinFlipConfig.finalFrameCloseTimeout, generation: generation)
    }

    /// `closeSessionAfterQueuedFrames(_:)` with an explicit bound (tests).
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID, timeout: Duration, generation: UInt64? = nil) {
        if let generation, sessionQueues[sessionID]?.generation != generation { return }
        guard var queue = sessionQueues[sessionID], !queue.closeMarkerYielded else { return }
        queue.closeMarkerYielded = true
        sessionQueues[sessionID] = queue
        if case .terminated = queue.continuation.yield(.close) {
            // The drain already ended (a failed send): nothing more can be written.
            Task { [weak self] in await self?.closeSession(sessionID, with: .normal, generation: generation) }
            return
        }
        Task { [weak self] in
            try? await safeTaskSleep(for: timeout)
            await self?.closeSession(sessionID, with: .normal, generation: generation)
        }
    }

    /// Closes the session's connection from the server side: the delegate is told the session
    /// disconnected (as for a client close), then the connection is closed. Every server close
    /// goes through here; a second call for the same session is a no-op.
    public func closeSession(_ sessionID: SessionID) async {
        await closeSession(sessionID, with: .normal)
    }

    /// `closeSession(_:)` with the close frame's code and reason. The leave happens here, before
    /// the connection closes: nothing the client sends after this reaches the land.
    public func closeSession(_ sessionID: SessionID, with close: SessionClose) async {
        await closeSession(sessionID, with: close, awaitingClosed: false)
    }

    /// `closeSession(_:with:)`; with `awaitingClosed`, it returns once the connection has closed
    /// (its close grace ended or the client's close frame arrived), when the connection can say
    /// so (`ClosedAwaitingConnection`). A server shutdown's sessions step uses it (#351).
    package func closeSession(_ sessionID: SessionID, with close: SessionClose, awaitingClosed: Bool) async {
        guard let queue = sessionQueues[sessionID] else { return }
        serverClosedSessions.insert(sessionID)
        await handleDisconnection(sessionID: sessionID)
        if close == .normal {
            try? await queue.connection.close()
        } else {
            try? await queue.connection.close(with: close)
        }
        scheduleServerCloseExpiry(serverCloseConfirmDeadline(for: close)) { [weak self] in
            await self?.expireUnconfirmedServerClose(sessionID)
        }
        // Waits only: nothing here reads or changes this transport's state after it.
        if awaitingClosed, let connection = queue.connection as? any ClosedAwaitingConnection {
            await connection.closed()
        }
    }

    /// `closeSession(_:with:)` while the connection is still the one with `generation`.
    public func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        if let generation, sessionQueues[sessionID]?.generation != generation { return }
        await closeSession(sessionID, with: close)
    }

    /// The server never reported the closed connection as disconnected: log it and stop
    /// waiting, so the set does not grow with connections whose callback never comes.
    private func expireUnconfirmedServerClose(_ sessionID: SessionID) {
        guard sessionQueues[sessionID] == nil, serverClosedSessions.remove(sessionID) != nil else { return }
        unconfirmedServerClosesForTesting += 1
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
                countMissingSessionDrop(frame.sessionID)
                logDropMissingSession(sessionID: frame.sessionID, bytes: frame.data.count)
                continue
            }
            if let generation = frame.connectionGeneration, generation != queue.generation {
                framesDroppedStaleGeneration += 1
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

/// Whether `WebSocketTransport.handleConnection` registered the connection.
public enum ConnectionAcceptance: Sendable, Equatable {
    case accepted
    case rejected(ConnectionRejection)
}

/// Why `WebSocketTransport.handleConnection` rejected a connection.
public enum ConnectionRejection: Sendable, Equatable {
    /// The `SessionID` is still held by another connection: connected, being disconnected, or
    /// closed by the server and not yet confirmed. Callers pass a fresh ID per connection.
    case sessionIDInUse
}

/// Abstract interface for a WebSocket connection
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func close() async throws
    /// Close with a status code and reason (`SessionClose`). The default calls `close()`.
    func close(with close: SessionClose) async throws
}

extension WebSocketConnection {
    public func close(with close: SessionClose) async throws {
        try await self.close()
    }
}

/// A connection that can report when it has closed: after a server close, once its close grace
/// ended or the client's close frame arrived. A server shutdown awaits it, so the close grace
/// it was given runs inside the shutdown's sessions step (#351).
package protocol ClosedAwaitingConnection: WebSocketConnection {
    /// Returns once the connection has closed.
    func closed() async
}
