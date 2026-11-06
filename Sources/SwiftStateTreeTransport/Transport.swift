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
