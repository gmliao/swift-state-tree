import SwiftStateTree
import SwiftStateTreeMessagePack

/// Manager for pending server events (targeted and broadcast).
///
/// This component encapsulates event queuing and filtering logic, separating concerns
/// from TransportAdapter's main orchestration logic.
///
/// **Design**: This is a value type (struct) for zero allocation overhead. All state
/// mutations happen within TransportAdapter's actor isolation domain.
struct PendingEventManager: Sendable {
    /// Pending targeted event body with membership stamp validation.
    struct TargetedEvent: Sendable {
        let target: SwiftStateTree.EventTarget
        let body: MessagePackValue
        let stamp: MembershipStamp?
    }
    
    private var targetedEvents: [TargetedEvent] = []
    private var broadcastEvents: [MessagePackValue] = []
    
    /// Whether any targeted events are queued.
    var hasTargetedEvents: Bool {
        !targetedEvents.isEmpty
    }
    
    /// Whether any events (targeted or broadcast) are queued.
    var hasAnyEvents: Bool {
        !targetedEvents.isEmpty || !broadcastEvents.isEmpty
    }
    
    // MARK: - Queueing
    
    /// Queue a targeted event for later delivery.
    mutating func queueTargeted(
        target: SwiftStateTree.EventTarget,
        body: MessagePackValue,
        stamp: MembershipStamp?
    ) {
        targetedEvents.append(TargetedEvent(target: target, body: body, stamp: stamp))
    }
    
    /// Queue a broadcast event for later delivery.
    mutating func queueBroadcast(body: MessagePackValue) {
        broadcastEvents.append(body)
    }
    
    // MARK: - Filtering
    
    /// Get pending targeted event bodies for a specific client, filtered by current membership.
    ///
    /// This method filters events based on membership stamps to prevent stale events
    /// from being delivered after leave/rejoin.
    ///
    /// - Parameters:
    ///   - sessionID: Session ID to filter for
    ///   - playerID: Player ID to filter for
    ///   - clientID: Client ID to filter for (optional)
    ///   - isSessionCurrent: Closure to check if session membership is current
    ///   - isPlayerCurrent: Closure to check if player membership is current
    /// - Returns: Array of event bodies for this client
    func pendingTargetedBodies(
        for sessionID: SessionID,
        playerID: PlayerID,
        clientID: ClientID?,
        isSessionCurrent: (SessionID, UInt64) -> Bool,
        isPlayerCurrent: (PlayerID, UInt64) -> Bool
    ) -> [MessagePackValue] {
        guard !targetedEvents.isEmpty else { return [] }
        
        var bodies: [MessagePackValue] = []
        bodies.reserveCapacity(targetedEvents.count)
        
        for event in targetedEvents {
            switch event.target {
            case .session(let s) where s == sessionID:
                guard let stamp = event.stamp,
                      isSessionCurrent(sessionID, stamp.version) else { continue }
                bodies.append(event.body)
                
            case .player(let p) where p == playerID:
                guard let stamp = event.stamp,
                      isPlayerCurrent(playerID, stamp.version) else { continue }
                bodies.append(event.body)
                
            case .client(let c):
                if clientID == c {
                    guard let stamp = event.stamp,
                          isSessionCurrent(sessionID, stamp.version) else { continue }
                    bodies.append(event.body)
                }
                
            case .players(let playerIDs):
                if playerIDs.contains(playerID) {
                    guard let stamp = event.stamp,
                          isPlayerCurrent(playerID, stamp.version) else { continue }
                    bodies.append(event.body)
                }
                
            default:
                continue
            }
        }
        
        return bodies
    }
    
    /// Get all pending broadcast event bodies.
    func pendingBroadcastBodies() -> [MessagePackValue] {
        broadcastEvents
    }
    
    // MARK: - Cleanup
    
    /// Clear all pending events (targeted and broadcast).
    mutating func clearAll() {
        targetedEvents.removeAll()
        broadcastEvents.removeAll()
    }
}
