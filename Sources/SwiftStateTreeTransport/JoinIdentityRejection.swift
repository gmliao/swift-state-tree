// Sources/SwiftStateTreeTransport/JoinIdentityRejection.swift
//
// Why a join request's playerID is rejected (#209).

import Foundation
import Logging
import SwiftStateTree

/// Why a join request's `playerID` is rejected (`TransportAdapter.joinIdentityRejection`).
/// Either way the client gets `JOIN_PLAYER_MISMATCH`.
public enum JoinIdentityRejection: Sendable, Equatable {
    /// The session's token is for another player.
    case tokenMismatch(tokenPlayerID: String)
    /// The land authenticates players, and the session has no token.
    case unauthenticated

    /// The join error's message.
    var message: String {
        switch self {
        case .tokenMismatch: "playerID does not match the authenticated player"
        case .unauthenticated: "playerID requires an authenticated session"
        }
    }

    func log(_ logger: Logger, sessionID: SessionID, requestedPlayerID: String?) {
        switch self {
        case .tokenMismatch(let tokenPlayerID):
            logger.warning("Join request names a player other than its token's", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "tokenPlayerID": .string(tokenPlayerID),
                "requestedPlayerID": .string(requestedPlayerID ?? ""),
            ])
        case .unauthenticated:
            logger.warning("Join request without a token names a player on a land that authenticates players", metadata: [
                "sessionID": .string(sessionID.rawValue),
                "requestedPlayerID": .string(requestedPlayerID ?? ""),
            ])
        }
    }
}
