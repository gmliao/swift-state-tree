// Sources/SwiftStateTree/Runtime/LandInitializationError.swift

/// A land's initialization failed: its OnInitialize resolvers ran past
/// `RESOLVER_INIT_TIMEOUT_MS` (#104). Every call that awaits the initialization (join, leave,
/// action, client event) throws it, a join as `JoinError.landShuttingDown`, and the land is
/// torn down without running its destroy handlers: OnInitialize never ran, so there is no state
/// for them to save.
public struct LandInitializationError: Error, Sendable, CustomStringConvertible {
    /// The OnInitialize resolvers' error (`ResolverExecutionError.timedOut`).
    public let underlying: any Error

    public var description: String {
        "Land initialization failed: \(underlying)"
    }
}
