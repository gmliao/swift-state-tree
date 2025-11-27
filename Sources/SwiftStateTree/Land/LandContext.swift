// Sources/SwiftStateTree/Land/LandContext.swift

import Foundation

/// Request-scoped context for Land handlers
/// 
/// LandContext is created for each Action/Event request and released after processing.
/// It follows the Request-scoped Context pattern (similar to NestJS Request Context).
/// 
/// **Key Points:**
/// - ✅ **Request-level**: A new LandContext is created for each Action/Event request
/// - ✅ **Non-persistent**: Released after processing, not stored in memory
/// - ✅ **Information centralization**: Request-related info (playerID, clientID, sessionID) is centralized
/// - ✅ **Request isolation**: Each request has an independent context, preventing interference
/// 
/// **Design Principle**: LandContext should NOT know about Transport.
/// WebSocket details should not be exposed to the StateTree layer.
/// 
/// Example:
/// ```swift
/// Action(GameAction.join) { state, (id, name), ctx -> ActionResult in
///     state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
///     await ctx.syncNow()
///     await ctx.sendEvent(.fromServer(.gameEvent(.playerJoined(id))), to: .all)
///     return .success(.joinResult(JoinResponse(landID: ctx.landID, state: snapshot)))
/// }
/// ```
public struct LandContext: Sendable {
    /// Land identifier
    public let landID: String
    
    /// Player identifier (account level, user identity)
    public let playerID: PlayerID
    
    /// Client identifier (device level, client instance provided by application)
    public let clientID: ClientID
    
    /// Session identifier (connection level, dynamically generated for tracking)
    public let sessionID: SessionID
    
    /// Service abstractions (does not depend on HTTP)
    public let services: LandServices
    
    /// Send event handler closure (delegates to Runtime layer without exposing Transport)
    private let sendEventHandler: @Sendable (GameEvent, EventTarget) async -> Void
    
    /// Sync handler closure (delegates to Runtime layer without exposing Transport)
    private let syncHandler: @Sendable () async -> Void
    
    /// Internal initializer for creating LandContext
    /// 
    /// This initializer is used by the Runtime layer (LandActor) to create contexts.
    /// The closures delegate to the Runtime layer, which handles Transport details.
    /// 
    /// - Parameters:
    ///   - landID: Land identifier
    ///   - playerID: Player identifier
    ///   - clientID: Client identifier
    ///   - sessionID: Session identifier
    ///   - services: Service abstractions
    ///   - sendEventHandler: Closure for sending events (implemented in Runtime layer)
    ///   - syncHandler: Closure for syncing state (implemented in Runtime layer)
    internal init(
        landID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        sendEventHandler: @escaping @Sendable (GameEvent, EventTarget) async -> Void,
        syncHandler: @escaping @Sendable () async -> Void
    ) {
        self.landID = landID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.services = services
        self.sendEventHandler = sendEventHandler
        self.syncHandler = syncHandler
    }
    
    // MARK: - Public Methods
    
    /// Send event to specified target
    /// 
    /// Events are sent through closure delegation, without exposing Transport details.
    /// The actual implementation is handled by the Runtime layer (LandActor).
    /// 
    /// - Parameters:
    ///   - event: GameEvent to send
    ///   - target: EventTarget specifying recipients
    /// 
    /// Example:
    /// ```swift
    /// await ctx.sendEvent(.fromServer(.gameEvent(.playerJoined(id))), to: .all)
    /// await ctx.sendEvent(.fromServer(.systemMessage("Hello")), to: .player(playerID))
    /// ```
    public func sendEvent(_ event: GameEvent, to target: EventTarget) async {
        await sendEventHandler(event, target)
    }
    
    /// Manually force immediate state synchronization (regardless of Tick configuration)
    /// 
    /// In Event-driven mode, this triggers immediate synchronization.
    /// In Tick-based mode, this can be used to force immediate sync for important operations.
    /// 
    /// Example:
    /// ```swift
    /// state.players[id] = PlayerState(name: name, hpCurrent: 100, hpMax: 100)
    /// await ctx.syncNow()  // Force immediate sync for important operations
    /// ```
    public func syncNow() async {
        await syncHandler()
    }
}

