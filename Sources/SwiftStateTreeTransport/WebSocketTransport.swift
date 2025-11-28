import Foundation
import SwiftStateTree

/// A Transport implementation using WebSockets.
///
/// This is a base implementation that needs to be connected to a concrete WebSocket server
/// (e.g., Vapor, Hummingbird, or NIO).
public actor WebSocketTransport: Transport {
    public var delegate: TransportDelegate?
    
    private var sessions: [SessionID: WebSocketConnection] = [:]
    private var playerSessions: [PlayerID: Set<SessionID>] = [:]
    
    public init() {}

    /// Set delegate from outside the actor.
    public func setDelegate(_ delegate: TransportDelegate?) {
        self.delegate = delegate
    }
    
    public func start() async throws {
        // In a real implementation, this would start the server or bind to a port.
        print("WebSocketTransport started")
    }
    
    public func stop() async throws {
        // Close all connections
        for session in sessions.values {
            try? await session.close()
        }
        sessions.removeAll()
        playerSessions.removeAll()
        print("WebSocketTransport stopped")
    }
    
    public func send(_ message: Data, to target: EventTarget) async throws {
        switch target {
        case .session(let sessionID):
            try await sessions[sessionID]?.send(message)
            
        case .player(let playerID):
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
    
    public func handleConnection(sessionID: SessionID, connection: WebSocketConnection) async {
        sessions[sessionID] = connection
        await delegate?.onConnect(sessionID: sessionID, clientID: ClientID("unknown")) // ClientID negotiation needed
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
        await delegate?.onDisconnect(sessionID: sessionID, clientID: ClientID("unknown"))
    }
    
    public func handleIncomingMessage(sessionID: SessionID, data: Data) async {
        await delegate?.onMessage(data, from: sessionID)
    }
    
    public func registerSession(_ sessionID: SessionID, for playerID: PlayerID) {
        playerSessions[playerID, default: []].insert(sessionID)
    }
}

/// Abstract interface for a WebSocket connection
public protocol WebSocketConnection: Sendable {
    func send(_ data: Data) async throws
    func close() async throws
}
