import Foundation
import SwiftStateTree
import Logging

/// A Transport implementation using WebSockets.
///
/// This is a base implementation that needs to be connected to a concrete WebSocket server
/// (e.g., Vapor, Hummingbird, or NIO).
public actor WebSocketTransport: Transport {
    public var delegate: TransportDelegate?
    
    private var sessions: [SessionID: WebSocketConnection] = [:]
    private var playerSessions: [PlayerID: Set<SessionID>] = [:]
    private var lastMissingSessionLogAt: [SessionID: Date] = [:]
    private var lastMissingPlayerLogAt: [PlayerID: Date] = [:]
    private let logger: Logger
    
    private static let missingTargetLogIntervalSeconds: TimeInterval = 2.0
    private static let missingTargetLogMapSoftLimit: Int = 5_000
    
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
    }

    /// Set delegate from outside the actor.
    public func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }
    
    public func start() async throws {
        // In a real implementation, this would start the server or bind to a port.
        logger.info("WebSocketTransport started")
    }
    
    public func stop() async throws {
        // Close all connections
        for session in sessions.values {
            try? await session.close()
        }
        sessions.removeAll()
        playerSessions.removeAll()
        logger.info("WebSocketTransport stopped")
    }
    
    public func send(_ message: Data, to target: EventTarget) async throws {
        logOutgoing(message, target: target)
        
        switch target {
        case .session(let sessionID):
            if sessions[sessionID] == nil {
                logDropMissingSession(sessionID: sessionID, bytes: message.count)
                return
            }
            try await sessions[sessionID]?.send(message)
            
        case .player(let playerID):
            if playerSessions[playerID] == nil {
                logDropMissingPlayer(playerID: playerID, bytes: message.count)
                return
            }
            if let sessionIDs = playerSessions[playerID] {
                for sessionID in sessionIDs {
                    try await sessions[sessionID]?.send(message)
                }
            }
            
        case .broadcast:
            for session in sessions.values {
                try await session.send(message)
            }
            
        case .broadcastExcept(let excludedSessionID):
            for (id, session) in sessions where id != excludedSessionID {
                try await session.send(message)
            }
        }
    }
    
    // MARK: - Connection Management (Called by the concrete server integration)
    
    public func handleConnection(sessionID: SessionID, connection: WebSocketConnection, authInfo: AuthenticatedInfo? = nil) async {
        sessions[sessionID] = connection
        lastMissingSessionLogAt.removeValue(forKey: sessionID)
        // Generate short client ID (6 characters) for better identification
        let clientIDString = String(UUID().uuidString.prefix(6))
        await delegate?.onConnect(sessionID: sessionID, clientID: ClientID(clientIDString), authInfo: authInfo)
    }
    
    public func handleDisconnection(sessionID: SessionID) async {
        sessions.removeValue(forKey: sessionID)
        // Cleanup player mapping
        for (playerID, sessionIDs) in playerSessions {
            if sessionIDs.contains(sessionID) {
                playerSessions[playerID]?.remove(sessionID)
                if playerSessions[playerID]?.isEmpty == true {
                    playerSessions.removeValue(forKey: playerID)
                }
            }
        }
        // Note: clientID is not stored, so we use a placeholder for disconnect
        // In practice, the delegate should track clientID if needed
        await delegate?.onDisconnect(sessionID: sessionID, clientID: ClientID("disconnected"))
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
    /// passed into `WebSocketTransport` (or `AppContainer`) with `.logLevel = .trace`.
    
    private func logIncoming(_ data: Data, from sessionID: SessionID) {
        let size = data.count
        
        logger.debug("WS ⇦ receive", metadata: [
            "session": .string(sessionID.rawValue),
            "bytes": .string("\(size)")
        ])
        
        // Log payload - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: data) {
            logger.trace("WS ⇦ payload", metadata: [
                "session": .string(sessionID.rawValue),
                "payload": .string(preview)
            ])
        }
    }
    
    private func logOutgoing(_ data: Data, target: EventTarget) {
        let size = data.count
        
        let targetDescription: String = {
            switch target {
            case .session(let id):
                return "session(\(id.rawValue))"
            case .player(let id):
                return "player(\(id.rawValue))"
            case .broadcast:
                return "broadcast"
            case .broadcastExcept(let id):
                return "broadcastExcept(\(id.rawValue))"
            }
        }()
        
        logger.debug("WS ⇨ send", metadata: [
            "target": .string(targetDescription),
            "bytes": .string("\(size)")
        ])
        
        // Log payload - only compute if trace logging is enabled
        if let preview = logger.safePreview(from: data) {
            logger.trace("WS ⇨ payload", metadata: [
                "target": .string(targetDescription),
                "payload": .string(preview)
            ])
        }
    }
    
    private func logDropMissingSession(sessionID: SessionID, bytes: Int) {
        if lastMissingSessionLogAt.count > Self.missingTargetLogMapSoftLimit {
            lastMissingSessionLogAt.removeAll()
        }
        
        let now = Date()
        if let last = lastMissingSessionLogAt[sessionID],
           now.timeIntervalSince(last) < Self.missingTargetLogIntervalSeconds {
            return
        }
        lastMissingSessionLogAt[sessionID] = now
        
        logger.debug("WS ⇨ drop (session not found)", metadata: [
            "session": .string(sessionID.rawValue),
            "bytes": .string("\(bytes)")
        ])
    }
    
    private func logDropMissingPlayer(playerID: PlayerID, bytes: Int) {
        if lastMissingPlayerLogAt.count > Self.missingTargetLogMapSoftLimit {
            lastMissingPlayerLogAt.removeAll()
        }
        
        let now = Date()
        if let last = lastMissingPlayerLogAt[playerID],
           now.timeIntervalSince(last) < Self.missingTargetLogIntervalSeconds {
            return
        }
        lastMissingPlayerLogAt[playerID] = now
        
        logger.debug("WS ⇨ drop (player has no sessions)", metadata: [
            "player": .string(playerID.rawValue),
            "bytes": .string("\(bytes)")
        ])
    }
}

/// Abstract interface for a WebSocket connection
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func close() async throws
}
