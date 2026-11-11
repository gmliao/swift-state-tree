import Foundation
import SwiftStateTree

// MARK: - Authenticated Info

/// Authenticated information extracted from JWT or other auth mechanisms
public struct AuthenticatedInfo: Sendable {
    public let playerID: String
    public let deviceID: String?
    public let metadata: [String: String]
    
    public init(playerID: String, deviceID: String? = nil, metadata: [String: String] = [:]) {
        self.playerID = playerID
        self.deviceID = deviceID
        self.metadata = metadata
    }
}

// MARK: - Transport Protocol

/// Protocol defining the interface for a network transport layer.
///
/// A Transport is responsible for:
/// 1. Managing connections (clients).
/// 2. Receiving messages from clients and forwarding them to the delegate (LandKeeper).
/// 3. Sending messages from the delegate to clients.
public protocol Transport: Actor {
    /// The delegate that handles incoming messages (typically an adapter for LandKeeper).
    var delegate: TransportDelegate? { get set }
    
    /// Starts the transport (e.g., starts listening on a port).
    func start() async throws
    
    /// Stops the transport.
    func stop() async throws
    
    /// Enqueues a message for delivery. Returns immediately; delivery is asynchronous.
    ///
    /// - Parameters:
    ///   - message: The message payload (already encoded as Data or TransportMessage).
    ///   - target: The recipients of the message.
    func send(_ message: Data, to target: EventTarget)

    /// Enqueues multiple messages in a single actor call. Reduces actor contention when sending many updates.
    /// Default implementation falls back to individual sends. Override for batch optimization (e.g. WebSocketTransport).
    ///
    /// - Parameter updates: Pairs of (message, target) to send.
    func sendBatch(_ updates: [(Data, EventTarget)]) async

    /// Sends frames that each address one session, in array order. This is the only call a
    /// `TransportAdapter` makes to send (through its `OutboundWriter`).
    ///
    /// A transport that tracks connection generations drops a frame whose
    /// `connectionGeneration` differs from the session's current connection. The default
    /// implementation ignores generations and forwards to `sendBatch` with `.session` targets.
    func sendSessionFrames(_ frames: [SessionFrame]) async

    /// Closes one session's connection from the server side. `TransportAdapter` calls it when it
    /// had to drop a frame for the session (outbound writer ceiling): the client reconnects and
    /// rejoins with a fresh firstSync instead of staying on state it can no longer patch.
    ///
    /// The default does nothing; the adapter still stops sending to the session.
    func closeSession(_ sessionID: SessionID) async

    /// Closes one session's connection from the server side with an application close code and
    /// reason (`SessionClose`), for a client that acts on the code (the sync-lag closes, #332).
    /// The default ignores the code and calls `closeSession(_:)`.
    func closeSession(_ sessionID: SessionID, with close: SessionClose) async

    /// `closeSession(_:with:)` only while the session's connection is still the one with
    /// `generation` (nil: any). A close decided about one connection never closes the next one
    /// that reuses the session ID. The default ignores the generation.
    func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async

    /// Whether `closeSession` actually closes the connection. `false` (the default) means a
    /// session the adapter ends stays connected but gets no more frames until it reconnects.
    nonisolated var supportsCloseSession: Bool { get }

    /// Closes the session after the frames already queued for it have been handed to its
    /// connection (bounded by `JoinFlipConfig.finalFrameCloseTimeout`), so a closing error
    /// frame isn't overtaken by the close. The default closes at once (`closeSession`), which
    /// may drop frames still queued.
    func closeSessionAfterQueuedFrames(_ sessionID: SessionID) async
}

extension Transport {
    /// Default: send each update individually.
    public func sendBatch(_ updates: [(Data, EventTarget)]) async {
        for (data, target) in updates {
            send(data, to: target)
        }
    }

    /// Default: cannot close sessions.
    public func closeSession(_ sessionID: SessionID) async {}

    /// Default: the generation is ignored; `closeSession(_:with:)`.
    public func closeSession(_ sessionID: SessionID, with close: SessionClose, generation: UInt64?) async {
        await closeSession(sessionID, with: close)
    }

    /// Default: the code and reason are dropped; `closeSession(_:)`.
    public func closeSession(_ sessionID: SessionID, with close: SessionClose) async {
        await closeSession(sessionID)
    }

    /// Default: `closeSession` is a no-op.
    public nonisolated var supportsCloseSession: Bool { false }

    /// Default: close at once.
    public func closeSessionAfterQueuedFrames(_ sessionID: SessionID) async {
        await closeSession(sessionID)
    }

    /// Default: no generation check; forwards to `sendBatch`.
    public func sendSessionFrames(_ frames: [SessionFrame]) async {
        await sendBatch(frames.map { ($0.data, .session($0.sessionID)) })
    }
}

// MARK: - Transport Delegate

/// Delegate protocol for handling events from the Transport layer.
extension Transport {
    /// Clears the delegate if it is `delegate` itself, for a destroyed land's adapter dropping
    /// its own link (#346); a newer delegate (the router of a shared transport) stays. On the
    /// protocol, so every transport, not only `WebSocketTransport`, is released.
    func releaseDelegate(ifIdenticalTo delegate: AnyObject) {
        if let current = self.delegate, current as AnyObject === delegate {
            self.delegate = nil
        }
    }
}

public protocol TransportDelegate: Sendable {
    /// Called when a client connects.
    /// - Parameters:
    ///   - sessionID: The session identifier
    ///   - clientID: The client identifier
    ///   - authInfo: Optional authenticated information (e.g., from JWT validation)
    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async
    
    /// Called when a client disconnects.
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async
    
    /// Called when a message is received from a client.
    ///
    /// **Precondition: serial delivery per session.** A transport delivers one session's
    /// messages one at a time, each after the previous call returned (the NIO server's inbound
    /// chain does). `LandRouter` and `TransportAdapter` rely on it: no frame of a session reaches
    /// them while its join is between its binding and its admission, so the frames a client sends
    /// during its join are deferred in order (#69).
    func onMessage(_ message: Data, from sessionID: SessionID) async
}

// MARK: - Transport Send Queue

/// Thread-safe queue for non-blocking send. When available, producers enqueue without awaiting the transport actor.
///
/// No longer used: `TransportAdapter` sends through its own ordered `OutboundWriter` (#60), and
/// `WebSocketTransport.transportSendQueue` returns `nil`. Kept for source compatibility.
public protocol TransportSendQueue: Sendable {
    func enqueue(_ message: Data, to target: EventTarget)
    func enqueueBatch(_ updates: [(Data, EventTarget)])
}

// MARK: - Event Target

/// Specifies the recipients of a message.
public enum EventTarget: Sendable {
    /// Send to a specific session/connection.
    case session(SessionID)
    
    /// Send to a specific player (could be multiple sessions).
    case player(PlayerID)
    
    /// Broadcast to all connected clients.
    case broadcast
    
    /// Broadcast to all except a specific session (e.g., "everyone else").
    case broadcastExcept(SessionID)
}

/// A server-side close's WebSocket status code and reason (RFC 6455 § 7.4).
public struct SessionClose: Sendable, Equatable {
    /// The largest reason, in UTF-8 bytes: a close frame's payload is at most 125 bytes, two of
    /// them the code.
    public static let maxReasonBytes = 123

    public let code: UInt16
    /// The reason, cut at a character boundary to `maxReasonBytes`.
    public let reason: String
    /// How long the server keeps the connection open after its close frame is written (#339).
    /// Meanwhile it reads and discards what the client sends, until the client's close frame
    /// arrives or the grace ends, then closes the channel. Closing at once with unread inbound
    /// data makes the kernel send an RST, which can discard the close frame on the client's side
    /// (the client then sees 1006 instead of this code). `nil` or zero closes the channel as soon
    /// as the frame is written.
    public let closeGrace: Duration?

    public init(code: UInt16, reason: String = "", closeGrace: Duration? = nil) {
        self.code = code
        self.reason = SessionClose.truncated(reason)
        self.closeGrace = closeGrace
    }

    /// 1000, no reason: what `closeSession(_:)` sends.
    public static let normal = SessionClose(code: 1000)

    /// 1001 Going Away: the server is shutting down (#351). It carries a short close grace
    /// (decision C2a), so a client still sending gets the close frame instead of an RST. The
    /// grace runs inside the shutdown's close-sessions step: the closes are issued concurrently,
    /// and the step ends by its deadline whether or not every grace has finished.
    package static let goingAway = SessionClose(code: 1001, reason: "server shutting down", closeGrace: .milliseconds(500))

    /// 4014: the session's land was stopped (#102). The same short close grace as `goingAway`.
    package static let landStopped = SessionClose(code: Code.landStopped, reason: "land stopped", closeGrace: .milliseconds(500))

    /// Application close codes (4000–4999). 4008 is `SendBacklogBound`'s, written by the NIO
    /// handler itself; the sync-lag codes (#332) are sent through `closeSession(_:with:)`.
    public enum Code {
        public static let sendBacklog: UInt16 = 4008
        // 4009 is unassigned: a sync-lag resync happens in place, without a close.
        /// The client kept falling behind, or couldn't take its own full view; it doesn't rejoin
        /// on its own.
        public static let slowConsumer: UInt16 = 4010
        /// The client stopped acking syncs; it doesn't rejoin on its own.
        public static let unresponsive: UInt16 = 4011
        /// The client's full view didn't encode for `SyncLagSession.snapshotEncodeFailureLimit`
        /// resyncs in a row (a value the encoding can't carry, such as a NaN in JSON); it doesn't
        /// rejoin on its own.
        public static let unencodableView: UInt16 = 4012
        // 4013 is reserved: the TypeScript SDK sends it (`invalidRowEntry`) when a row entry
        // breaks the strict rules. A server code must not reuse it.
        /// The land the session was in was stopped (the admin API's `DELETE /admin/lands/:landID`,
        /// `LandServerProtocol.stopLand`, #102). Unlike 1001, it says this land is gone, not the
        /// server: a client doesn't retry it. A join for the same land ID gets a new instance.
        public static let landStopped: UInt16 = 4014
    }

    private static func truncated(_ reason: String) -> String {
        guard reason.utf8.count > maxReasonBytes else { return reason }
        var out = ""
        var bytes = 0
        for character in reason {
            let size = String(character).utf8.count
            if bytes + size > maxReasonBytes { break }
            out.append(character)
            bytes += size
        }
        return out
    }
}

