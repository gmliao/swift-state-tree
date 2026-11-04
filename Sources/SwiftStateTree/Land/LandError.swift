import Foundation

/// Errors thrown during Land DSL processing or runtime execution.
public enum LandError: Error {
    /// Thrown when an action is received but no handler is registered for its type.
    case actionNotRegistered
    /// Thrown when an event is received but no handler is registered for its type.
    case eventNotRegistered
    /// Thrown when an action cannot be cast to the expected type.
    case invalidActionType
    /// Thrown when an event cannot be cast to the expected type.
    case invalidEventType
    /// Thrown when multiple AccessControl blocks are defined in the same Land.
    case duplicateAccessControl
    /// Thrown when multiple Lifetime blocks are defined in the same Land.
    case duplicateLifetime
    /// Thrown when an unsupported node type is encountered during DSL processing.
    case unsupportedNode
    /// Thrown when attempting to mutate state during sync operation.
    /// Not thrown by `LandKeeper`: mutations during a sync are allowed, and their dirty flags
    /// survive the sync because `beginSync(clearDirtyFlags:)` clears flags when it takes the snapshot.
    case syncInProgress
}

