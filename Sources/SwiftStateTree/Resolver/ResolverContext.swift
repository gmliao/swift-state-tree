import Foundation

/// Context provided to resolvers during resolution.
///
/// ResolverContext provides all the information a resolver needs to load data:
/// - Action/Event payloads to extract parameters
/// - Current state for cache checking or conditional loading
/// - Services for database, cache, API access
/// - Request metadata (playerID, clientID, sessionID, etc.)
///
/// Example:
/// ```swift
/// public struct ProductInfoResolver: ContextResolver {
///     public typealias Output = ProductInfo
///
///     public static func resolve(
///         ctx: ResolverContext
///     ) async throws -> ProductInfo {
///         // Extract productID from action payload
///         let action = ctx.actionPayload as? UpdateCartAction
///         guard let productID = action?.productID else {
///             throw ResolverError.missingParameter("productID")
///         }
///
///         // Check cache in current state
///         let state = ctx.currentState as? GameState
///         if let cachedProduct = state?.productCache[productID] {
///             return cachedProduct
///         }
///
///         // Load from external system
///         let data = try await ctx.services.database.fetchProduct(by: productID)
///         return ProductInfo(id: data.id, name: data.name, price: data.price, stock: data.stock)
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

    /// Action payload (if this is an Action handler context)
    ///
    /// Resolvers can extract parameters from the action payload.
    /// Example: `let action = ctx.actionPayload as? UpdateCartAction`
    public let actionPayload: (any Sendable)?

    /// Event payload (if this is an Event handler context)
    ///
    /// Resolvers can extract parameters from the event payload.
    /// Example: `let event = ctx.eventPayload as? UserProfileRequestEvent`
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
    /// A required parameter is missing from the action/event payload.
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
}

extension ResolverExecutionError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .resolverFailed(let name, let error):
            return "Resolver '\(name)' failed: \(error)"
        case .multipleResolversFailed(let failures):
            let failureDescriptions = failures.map { "\($0.name): \($0.error)" }.joined(separator: "; ")
            return "Multiple resolvers failed: \(failureDescriptions)"
        }
    }
}
