import Foundation
import SwiftStateTree

/// The error code and message an action or a join failure is answered with.
enum AdapterErrorMapping {
    /// Map action error to error code and message.
    static func mapActionError(_ error: Error, actionType: String) -> (code: ErrorCode, message: String) {
        if let landError = error as? LandError {
            switch landError {
            case .actionNotRegistered:
                return (.actionNotRegistered, "Action not registered: \(actionType)")
            default:
                return (.actionHandlerError, "\(error)")
            }
        } else {
            return (.actionHandlerError, "\(error)")
        }
    }

    static func mapJoinFailure(_ error: Error) -> (ErrorCode, String) {
        // The router's message for it (`LandRouter.joinErrorResponse`), not the case's name.
        if case .superseded? = error as? JoinError {
            return (.joinDenied, "Join superseded by a newer join of the player")
        }
        if error.localizedDescription.localizedCaseInsensitiveContains("full") {
            return (.joinRoomFull, "Room is full")
        }
        return (.joinDenied, "\(error)")
    }
}
