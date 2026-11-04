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

    /// Number of queued targeted events. Events are only appended until a sync cycle removes the
    /// prefix it consumed (`removeConsumed`), so within a cycle a count taken earlier marks which
    /// events were already queued at that point.
    var targetedEventCount: Int {
        targetedEvents.count
    }

    /// Number of queued broadcast events (same append-only rule as `targetedEventCount`).
    var broadcastEventCount: Int {
        broadcastEvents.count
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
    ///   - endIndex: Stop before this index (the count a sync plan read, see
    ///     `targetedEventCount`); `nil` reads to the current end. The result covers `[0, endIndex)`.
    /// - Returns: Array of event bodies for this client
    func pendingTargetedBodies(
        for sessionID: SessionID,
        playerID: PlayerID,
        clientID: ClientID?,
        isSessionCurrent: (SessionID, UInt64) -> Bool,
        isPlayerCurrent: (PlayerID, UInt64) -> Bool,
        endingBefore endIndex: Int? = nil
    ) -> [MessagePackValue] {
        let end = endIndex ?? targetedEvents.count
        // The queue is append-only within a cycle, so a count taken earlier is never past the end.
        assert(end <= targetedEvents.count, "endIndex past the end: the targeted event queue shrank")
        guard end > 0 else { return [] }

        var bodies: [MessagePackValue] = []
        bodies.reserveCapacity(end)

        for event in targetedEvents[0..<end] {
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
    
    /// Remove the first `targeted` targeted events and the first `broadcast` broadcast events:
    /// the prefix a sync cycle read. Events queued after that stay for the next cycle.
    mutating func removeConsumed(targeted: Int, broadcast: Int) {
        assert(targeted <= targetedEvents.count, "removing more targeted events than are queued")
        assert(broadcast <= broadcastEvents.count, "removing more broadcast events than are queued")
        targetedEvents.removeFirst(min(max(targeted, 0), targetedEvents.count))
        broadcastEvents.removeFirst(min(max(broadcast, 0), broadcastEvents.count))
    }
}
