import Foundation
import SwiftStateTree

extension TransportAdapter {
    public func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo? = nil) async {
        await _onConnectImpl(sessionID: sessionID, clientID: clientID, authInfo: authInfo)
    }

    public func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        await _onDisconnectImpl(sessionID: sessionID, clientID: clientID)
    }

    public func registerSession(
        sessionID: SessionID,
        clientID: ClientID,
        playerID: PlayerID,
        authInfo: AuthenticatedInfo?
    ) async {
        await _registerSessionImpl(
            sessionID: sessionID,
            clientID: clientID,
            playerID: playerID,
            authInfo: authInfo
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
