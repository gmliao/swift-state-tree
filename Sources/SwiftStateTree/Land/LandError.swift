import Foundation

/// Errors thrown during Land DSL processing or runtime execution.
public enum LandError: Error {
    case actionNotRegistered
    case eventNotRegistered
    case invalidActionType
    case invalidEventType
    case duplicateAccessControl
    case duplicateLifetime
    case unsupportedNode
}

