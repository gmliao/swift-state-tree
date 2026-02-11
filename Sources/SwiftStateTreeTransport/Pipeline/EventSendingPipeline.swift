import Foundation
import SwiftStateTree
import SwiftStateTreeMessagePack
import Logging

/// Pipeline component for sending server events.
///
/// This component centralizes event sending logic, supporting two strategies:
/// - **Queue mode** (opcode 107): Events are queued and merged with next state update (no await)
/// - **Immediate mode**: Events are encoded and sent immediately (async)
///
/// **Performance**: This is a value type (struct) with zero allocation overhead.
/// Queue operations are synchronous (no actor hopping). Immediate sends are async.
struct EventSendingPipeline: Sendable {
    let messageEncoder: any TransportMessageEncoder
    let codec: any TransportCodec
    let landID: String
    let logger: Logger
    
    /// Send decision result.
    enum SendDecision {
        /// Event was queued for later delivery (no await occurred).
        case queued
        
        /// Event needs immediate delivery (caller should await transport.send).
        case immediate(data: Data, target: EventTarget, description: String)
    }
    
    /// Queue event for merged sending (synchronous, no await).
    ///
    /// This path is used when opcode 107 is enabled. Events are queued and will be
    /// merged with the next state update, avoiding separate frame sends.
    ///
    /// - Parameters:
    ///   - eventBody: Pre-encoded event body (MessagePackValue)
    ///   - target: Event target
    ///   - pendingEventManager: Manager to queue the event
    ///   - membershipCoordinator: Coordinator to get membership stamps
    func queueForMergedSend(
        eventBody: MessagePackValue,
        target: SwiftStateTree.EventTarget,
        pendingEventManager: inout PendingEventManager,
        membershipCoordinator: MembershipCoordinator
    ) {
        switch target {
        case .all:
            pendingEventManager.queueBroadcast(body: eventBody)
            
        case .players(let playerIDs):
            for playerID in playerIDs {
                let stamp = membershipCoordinator.currentMembershipStamp(for: playerID)
                pendingEventManager.queueTargeted(target: .player(playerID), body: eventBody, stamp: stamp)
            }
            
        case .client(let clientID):
            if let sessionID = membershipCoordinator.sessionID(for: clientID) {
                let stamp = membershipCoordinator.currentMembershipStamp(for: sessionID)
                pendingEventManager.queueTargeted(target: .session(sessionID), body: eventBody, stamp: stamp)
            } else {
                logger.warning("No session found for client: \(clientID.rawValue)")
            }
            
        default:
            let stamp = membershipCoordinator.currentMembershipStamp(for: target)
            pendingEventManager.queueTargeted(target: target, body: eventBody, stamp: stamp)
        }
    }
    
    /// Prepare event for immediate sending (encodes and validates).
    ///
    /// This path is used when opcode 107 is disabled or encoding fails.
    /// Returns send decision with encoded data ready for transport.
    ///
    /// - Parameters:
    ///   - event: Server event to send
    ///   - target: Event target
    ///   - membershipCoordinator: Coordinator to validate membership
    /// - Returns: Send decision (nil if target is invalid)
    func prepareImmediateSend(
        event: AnyServerEvent,
        target: SwiftStateTree.EventTarget,
        membershipCoordinator: MembershipCoordinator
    ) throws -> SendDecision? {
        let transportMsg = TransportMessage.event(event: .fromServer(event: event))
        let data = try messageEncoder.encode(transportMsg)
        
        // Convert SwiftStateTree.EventTarget to SwiftStateTreeTransport.EventTarget
        let transportTarget: EventTarget
        let targetDescription: String
        
        switch target {
        case .all:
            transportTarget = .broadcast
            targetDescription = "broadcast(all)"
            
        case .player(let playerID):
            guard let stamp = membershipCoordinator.currentMembershipStamp(for: playerID),
                  membershipCoordinator.isPlayerCurrent(playerID, expected: stamp.version) else {
                return nil
            }
            transportTarget = .player(playerID)
            targetDescription = "player(\(playerID.rawValue))"
            
        case .client(let clientID):
            guard let sessionID = membershipCoordinator.sessionID(for: clientID) else {
                logger.warning("No session found for client: \(clientID.rawValue)")
                return nil
            }
            guard let stamp = membershipCoordinator.currentMembershipStamp(for: sessionID),
                  membershipCoordinator.isSessionCurrent(sessionID, expected: stamp.version) else {
                return nil
            }
            transportTarget = .session(sessionID)
            targetDescription = "client(\(clientID.rawValue)) -> session(\(sessionID.rawValue))"
            
        case .session(let sessionID):
            guard let stamp = membershipCoordinator.currentMembershipStamp(for: sessionID),
                  membershipCoordinator.isSessionCurrent(sessionID, expected: stamp.version) else {
                return nil
            }
            transportTarget = .session(sessionID)
            targetDescription = "session(\(sessionID.rawValue))"
            
        case .players(let playerIDs):
            // Special case: send to multiple players individually
            // This is handled separately in the caller
            transportTarget = .broadcast
            targetDescription = "players(\(playerIDs.count))"
        }
        
        return .immediate(data: data, target: transportTarget, description: targetDescription)
    }
}
