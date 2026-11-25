import Foundation

/// The context a `ContextResolver` reads (the join entries, until #769 R3). A `Resolver` value
/// doesn't read it: its fields and its `Dependencies` are all it sees.
///
/// It holds:
/// - the request's identity (`landID`, `playerID`, `clientID`, `sessionID`);
/// - the current state, read-only, for cache checks or conditional loading;
/// - the land's services (database, cache, API access).
///
/// Example:
/// ```swift
/// struct UserProfileResolver: ContextResolver {
///     static func resolve(ctx: ResolverContext) async throws -> UserProfile {
///         // Check the cache in the current state
///         if let cached = (ctx.currentState as? GameState)?.profiles[ctx.playerID] {
///             return cached
///         }
///         guard let store = ctx.services.get(ProfileStore.self) else {
///             throw ResolverError.missingParameter("ProfileStore")
///         }
///         return try await store.profile(for: ctx.playerID)
///     }
/// }
/// ```
public struct ResolverContext: Sendable {
    /// Land identifier
    public let landID: String

    /// Player identifier (account level, user identity)
    public let playerID: PlayerID

    /// Client identifier (device level, client instance)
    public let clientID: ClientID

    /// Session identifier (connection level)
    public let sessionID: SessionID

    /// `nil` in every context the runtime builds: an action declares `Resolver` values (#769),
    /// which take what they need from the action as fields when they are built. Only a context
    /// built by hand with `init(landContext:actionPayload:eventPayload:currentState:)` can carry a
    /// value.
    public let actionPayload: (any Sendable)?

    /// `nil` in every context the runtime builds: client events take no resolvers
    /// (`HandleEvent` has no `resolvers:` parameter), so the runtime never sets it. Only a
    /// context built by hand with `init(landContext:actionPayload:eventPayload:currentState:)`
    /// can carry a value.
    public let eventPayload: (any Sendable)?

    /// Current state (read-only)
    ///
    /// Resolvers can read the current state to:
    /// - Check caches (e.g., `state.productCache[productID]`)
    /// - Make conditional loading decisions
    /// - Avoid unnecessary data loading
    public let currentState: any StateNodeProtocol

    /// Available services (database, cache, etc.)
    ///
    /// Provides access to external services in a protocol-agnostic way.
    public let services: LandServices

    /// The land's services value, for the `Resolver` values the keeper runs (#769): the one
    /// `register(_:services:)` or `LandKeeper(land:resolverServices:)` gave, or `NoServices()`.
    package var resolverServices: (any Sendable)?

    /// Create a ResolverContext from a LandContext and additional information.
    ///
    /// - Parameters:
    ///   - landContext: The base LandContext
    ///   - actionPayload: Optional action payload
    ///   - eventPayload: Optional event payload
    ///   - currentState: Current state snapshot
    public init(
        landContext: LandContext,
        actionPayload: (any Sendable)? = nil,
        eventPayload: (any Sendable)? = nil,
        currentState: any StateNodeProtocol
    ) {
        self.landID = landContext.landID
        self.playerID = landContext.playerID
        self.clientID = landContext.clientID
        self.sessionID = landContext.sessionID
        self.actionPayload = actionPayload
        self.eventPayload = eventPayload
        self.currentState = currentState
        self.services = landContext.services
    }
}

/// Errors that can occur during resolver execution.
public enum ResolverError: Error, Sendable {
    /// A required parameter is missing from the action payload.
    case missingParameter(String)

    /// Data could not be loaded from external source.
    case dataLoadFailed(String)

    /// Resolver execution was cancelled.
    case cancelled

    /// Custom error with message.
    case custom(String)
}

/// Errors that occur during resolver execution orchestration.
///
/// This error type wraps resolver-specific errors with additional context
/// about which resolver failed, making debugging easier.
public enum ResolverExecutionError: Error, Sendable {
    /// A specific resolver failed during execution.
    ///
    /// - Parameters:
    ///   - name: The name of the resolver that failed (e.g., "ProductInfoResolver")
    ///   - underlyingError: The original error thrown by the resolver
    case resolverFailed(name: String, underlyingError: Error)
    
    /// Multiple resolvers failed (if we decide to support partial failures in the future)
    case multipleResolversFailed([(name: String, error: Error)])

    /// The resolver group ran past its deadline (`RESOLVER_TIMEOUT_MS`, #104). It was cancelled,
    /// but a resolver that ignores cancellation keeps running, and its external effects with it.
    ///
    /// - Parameters:
    ///   - names: The resolvers still running at the deadline
    ///   - after: The deadline
    case timedOut(names: [String], after: Duration)

    /// Two resolvers of one group returned an output under the same name. The group fails
    /// rather than keep whichever finished last.
    ///
    /// - Parameters:
    ///   - name: The output name
    ///   - resolvers: The two resolvers, in the order their outputs arrived
    case duplicateOutput(name: String, resolvers: [String])
}

extension ResolverExecutionError {
    /// Whether `error` is a cancellation: a bare `CancellationError`, or one a resolver group
    /// wrapped (`resolverFailed`, or a `multipleResolversFailed` whose every failure is one).
    package static func isCancellation(_ error: any Error) -> Bool {
        if error is CancellationError { return true }
        switch error as? ResolverExecutionError {
        case .resolverFailed(_, let underlying)?:
            return isCancellation(underlying)
        case .multipleResolversFailed(let failures)?:
            return !failures.isEmpty && failures.allSatisfy { isCancellation($0.error) }
        case .timedOut?, .duplicateOutput?, nil:
            return false
        }
    }
}

extension ResolverExecutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .resolverFailed(let name, let error):
            return "Resolver '\(name)' failed: \(error)"
        case .multipleResolversFailed(let failures):
            let failureDescriptions = failures.map { "\($0.name): \($0.error)" }.joined(separator: "; ")
            return "Multiple resolvers failed: \(failureDescriptions)"
        case .timedOut(let names, let after):
            return "Resolvers timed out after \(after): \(names.joined(separator: ", "))"
        case .duplicateOutput(let name, let resolvers):
            return "Resolvers \(resolvers.joined(separator: " and ")) both returned an output named '\(name)'"
        }
    }
}
