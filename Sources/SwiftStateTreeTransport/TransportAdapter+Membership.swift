import Foundation
import SwiftStateTree

extension TransportAdapter {
    public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        await _onConnectImpl(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        await _onDisconnectImpl(sessionID: sessionID, clientID: clientID)
    }

    /// Registers a joined session directly, without the admission (`performJoin` does both).
    /// Use it only for a session whose keeper join the caller already did.
    ///
    /// The realtime adapter's rule applies, as for a join: newest wins, and the player's older
    /// sessions are logged out (superseded and closed, #92, #531). It runs in the adapter's
    /// membership queue, ordered with joins and disconnects. When the keeper's entry for the
    /// player names another session or client (a newer keeper join), the registration is
    /// refused and the session closed.
    ///
    /// - Parameter connectionGeneration: The transport connection generation read when the
    ///   session's connection was accepted; `nil` reads the current one.
    public func registerSession(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?,
        connectionGeneration: UInt64? = nil
    ) async {
        await _registerSessionQueued(
            sessionID: sessionID,
            clientID: clientID,
            playerID: playerID,
            authInfo: authInfo,
            acceptedConnectionGeneration: connectionGeneration
        )
    }

    public func isConnected(sessionID: SessionID) -> Bool {
        _isConnectedImpl(sessionID: sessionID)
    }

    public func isJoined(sessionID: SessionID) -> Bool {
        _isJoinedImpl(sessionID: sessionID)
    }

    public func getPlayerID(for sessionID: SessionID) -> PlayerID? {
        _getPlayerIDImpl(for: sessionID)
    }

    public func getSessions(for playerID: PlayerID) -> [SessionID] {
        _getSessionsImpl(for: playerID)
    }
}
