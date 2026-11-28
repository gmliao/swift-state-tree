// Sources/SwiftStateTree/Runtime/LandInitializationError.swift

/// A land's initialization failed: its OnInitialize resolvers ran past
/// `RESOLVER_INIT_TIMEOUT_MS` (#104), or threw with `onResolverFailure: .failLand`, the default
/// (#238), or its state type fails the registration check that no entry point ran (#535: a
/// keeper built directly), or the land's drain had started when its OnInitialize resolvers
/// returned (#946: a failure the transport reported during them; the keeper's drain doesn't
/// wait for the initialization, and OnInitialize never applies, whatever the resolvers
/// return). Every call that awaits the initialization (join, leave,
/// action, client event) throws it, a join as `JoinError.landShuttingDown`, and the land is
/// torn down without running its destroy handlers: OnInitialize never ran, so there is no state
/// for them to save.
public struct LandInitializationError: Error, Sendable, CustomStringConvertible {
    /// The registration check's `LandRegistrationError`, or the OnInitialize resolvers' error:
    /// `ResolverExecutionError.timedOut`, or the error the
    /// group threw (`ResolverExecutionError.resolverFailed`), or, for a land that failed during
    /// those resolvers, its `LandFailure` (#946).
    public let underlying: any Error

    public var description: String {
        "Land initialization failed: \(underlying)"
    }
}
