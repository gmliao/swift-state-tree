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
        if error.localizedDescription.localizedCaseInsensitiveContains("full") {
            return (.joinRoomFull, "Room is full")
        }
        return (.joinDenied, "\(error)")
    }
}
