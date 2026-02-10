import Foundation
import SwiftStateTree

/// Membership stamp for versioning (prevents stale operations after rejoin).
struct MembershipStamp: Sendable, Equatable {
    let playerID: PlayerID
    let version: UInt64
}

/// Membership coordinator for managing player sessions and membership versioning.
///
/// This component encapsulates all membership-related state and logic, including:
/// - Session to player/client mapping
/// - Membership versioning (for stale operation prevention)
/// - PlayerSlot allocation (deterministic slot assignment)
///
/// **Important**: This class is NOT an actor - it's isolated to TransportAdapter's actor.
/// All methods must be called from within TransportAdapter's actor context.
///
/// **Performance**: This is a Sendable class with no separate concurrency. All state
/// mutations happen synchronously within TransportAdapter's actor isolation domain.
final class MembershipCoordinator: Sendable {
    // Session mappings
    // Note: Using nonisolated(unsafe) because this class is isolated to TransportAdapter's actor
    nonisolated(unsafe) private var sessionToPlayer: [SessionID: PlayerID] = [:]
    nonisolated(unsafe) private var sessionToClient: [SessionID: ClientID] = [:]
    nonisolated(unsafe) private var sessionToAuthInfo: [SessionID: AuthenticatedInfo] = [:]
    
    // Membership versioning (for stale operation prevention)
    nonisolated(unsafe) private var membershipVersionByPlayer: [PlayerID: UInt64] = [:]
    nonisolated(unsafe) private var membershipVersionBySession: [SessionID: UInt64] = [:]
    
    // PlayerSlot allocation
    nonisolated(unsafe) private var slotToPlayer: [Int32: PlayerID] = [:]
    nonisolated(unsafe) private var playerToSlot: [PlayerID: Int32] = [:]
    
    init() {}
    
    // MARK: - Session Management
    
    /// Register a new client session (before join).
    func registerClient(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) {
        sessionToClient[sessionID] = clientID
        if let authInfo {
            sessionToAuthInfo[sessionID] = authInfo
        }
    }
    
    /// Register a player session (after successful join).
    func registerPlayer(
        sessionID: SessionID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?
    ) -> MembershipStamp {
        sessionToPlayer[sessionID] = playerID
        if let authInfo = authInfo {
            sessionToAuthInfo[sessionID] = authInfo
        }
        return bindMembership(sessionID: sessionID, playerID: playerID)
    }
    
    /// Unregister a session (on disconnect).
    func unregisterSession(sessionID: SessionID) {
        sessionToPlayer.removeValue(forKey: sessionID)
        sessionToClient.removeValue(forKey: sessionID)
        sessionToAuthInfo.removeValue(forKey: sessionID)
    }

    /// Remove joined player mapping for a session while keeping client connection.
    ///
    /// Used for rollback when join fails after provisional registration.
    func removeJoinedPlayer(sessionID: SessionID) {
        if let playerID = sessionToPlayer[sessionID] {
            invalidateMembership(sessionID: sessionID, playerID: playerID)
        }
        sessionToPlayer.removeValue(forKey: sessionID)
    }
    
    /// Release player slot when player leaves permanently.
    func releasePlayerSlot(playerID: PlayerID) {
        if let slot = playerToSlot[playerID] {
            slotToPlayer.removeValue(forKey: slot)
            playerToSlot.removeValue(forKey: playerID)
        }
    }
    
    // MARK: - Membership Versioning
    
    private func nextMembershipVersion(for playerID: PlayerID) -> UInt64 {
        let next = (membershipVersionByPlayer[playerID] ?? 0) + 1
        membershipVersionByPlayer[playerID] = next
        return next
    }
    
    private func bindMembership(sessionID: SessionID, playerID: PlayerID) -> MembershipStamp {
        let version = nextMembershipVersion(for: playerID)
        membershipVersionBySession[sessionID] = version
        return MembershipStamp(playerID: playerID, version: version)
    }
    
    func invalidateMembership(sessionID: SessionID, playerID: PlayerID) {
        _ = nextMembershipVersion(for: playerID)
        membershipVersionBySession.removeValue(forKey: sessionID)
    }
    
    func currentMembershipStamp(for playerID: PlayerID) -> MembershipStamp? {
        guard let version = membershipVersionByPlayer[playerID] else { return nil }
        return MembershipStamp(playerID: playerID, version: version)
    }
    
    func currentMembershipStamp(for sessionID: SessionID) -> MembershipStamp? {
        guard let playerID = sessionToPlayer[sessionID],
              let version = membershipVersionBySession[sessionID] else { return nil }
        return MembershipStamp(playerID: playerID, version: version)
    }
    
    func currentMembershipStamp(for target: SwiftStateTree.EventTarget) -> MembershipStamp? {
        switch target {
        case .player(let playerID):
            return currentMembershipStamp(for: playerID)
        case .session(let sessionID):
            return currentMembershipStamp(for: sessionID)
        case .client(let clientID):
            guard let sessionID = sessionID(for: clientID) else { return nil }
            return currentMembershipStamp(for: sessionID)
        default:
            return nil
        }
    }
    
    func isSessionCurrent(_ sessionID: SessionID, expected: UInt64) -> Bool {
        membershipVersionBySession[sessionID] == expected
    }
    
    func isPlayerCurrent(_ playerID: PlayerID, expected: UInt64) -> Bool {
        membershipVersionByPlayer[playerID] == expected
    }
    
    // MARK: - PlayerSlot Allocation
    
    /// Allocate a deterministic playerSlot for a player based on accountKey.
    ///
    /// Uses a hash-based slot allocation strategy to ensure the same player
    /// always gets the same slot (deterministic for client prediction).
    ///
    /// - Parameters:
    ///   - accountKey: Unique account identifier (e.g., JWT sub, playerID)
    ///   - playerID: Player ID
    /// - Returns: Allocated player slot
    func allocatePlayerSlot(accountKey: String, for playerID: PlayerID) -> Int32 {
        // Check if player already has a slot
        if let existingSlot = playerToSlot[playerID] {
            return existingSlot
        }
        
        // Hash-based slot allocation
        let hash = accountKey.hashValue
        let candidateSlot = Int32(abs(hash) % 1000)
        
        // Find first available slot starting from candidate
        var slot = candidateSlot
        while slotToPlayer[slot] != nil {
            slot = (slot + 1) % 1000
            if slot == candidateSlot {
                // Wrapped around, use any available slot
                slot = 0
                while slotToPlayer[slot] != nil {
                    slot += 1
                }
                break
            }
        }
        
        // Allocate slot
        slotToPlayer[slot] = playerID
        playerToSlot[playerID] = slot
        return slot
    }
    
    /// Get the playerSlot for an existing player.
    func getPlayerSlot(for playerID: PlayerID) -> Int32? {
        playerToSlot[playerID]
    }

    /// Get the player for an allocated slot.
    func getPlayerID(for slot: Int32) -> PlayerID? {
        slotToPlayer[slot]
    }
    
    // MARK: - Queries
    
    func playerID(for sessionID: SessionID) -> PlayerID? {
        sessionToPlayer[sessionID]
    }
    
    func clientID(for sessionID: SessionID) -> ClientID? {
        sessionToClient[sessionID]
    }
    
    func authInfo(for sessionID: SessionID) -> AuthenticatedInfo? {
        sessionToAuthInfo[sessionID]
    }
    
    func sessionID(for clientID: ClientID) -> SessionID? {
        sessionToClient.first(where: { $0.value == clientID })?.key
    }
    
    func sessionIDs(for playerID: PlayerID) -> [SessionID] {
        sessionToPlayer.filter { $0.value == playerID }.map { $0.key }
    }
    
    func hasClient(sessionID: SessionID) -> Bool {
        sessionToClient[sessionID] != nil
    }
    
    func hasPlayer(sessionID: SessionID) -> Bool {
        sessionToPlayer[sessionID] != nil
    }
    
    var connectedSessions: Set<SessionID> {
        Set(sessionToClient.keys).subtracting(Set(sessionToPlayer.keys))
    }
    
    var joinedSessions: Set<SessionID> {
        Set(sessionToPlayer.keys)
    }
    
    var isEmpty: Bool {
        sessionToPlayer.isEmpty
    }

    // Transitional snapshots for in-place TransportAdapter migration.
    var sessionToPlayerSnapshot: [SessionID: PlayerID] {
        sessionToPlayer
    }

    var sessionToClientSnapshot: [SessionID: ClientID] {
        sessionToClient
    }

    var sessionToAuthInfoSnapshot: [SessionID: AuthenticatedInfo] {
        sessionToAuthInfo
    }
}
