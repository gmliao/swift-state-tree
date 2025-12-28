import Foundation
import Logging

/// Request-scoped context for Land handlers
///
/// LandContext is created for each Action/Event request and released after processing.
/// It follows the Request-scoped Context pattern.
///
/// Supports dynamic resolver outputs via @dynamicMemberLookup.
/// Resolver outputs are populated before Action/Event handler execution.
@dynamicMemberLookup
public struct LandContext: Sendable {
    /// Land identifier
    public let landID: String

    /// Player identifier (account level, user identity)
    public let playerID: PlayerID

    /// Client identifier (device level, client instance provided by application)
    public let clientID: ClientID

    /// Session identifier (connection level, dynamically generated for tracking)
    public let sessionID: SessionID

    /// Device identifier (optional, from PlayerSession)
    public let deviceID: String?

    /// Whether this is a guest session (not authenticated via JWT).
    public let isGuest: Bool

    /// Additional metadata from PlayerSession (e.g., connectedAt, platform, etc.)
    public let metadata: [String: String]

    /// Service abstractions (does not depend on HTTP)
    ///
    /// Provides access to external services like database, metrics, or logging
    /// in a protocol-agnostic way.
    public let services: LandServices
    
    /// Logger instance for logging in handlers
    ///
    /// Logger is synchronous and can be used directly in Action/Event handlers.
    public let logger: Logger

    /// Send event handler closure (delegates to Runtime layer without exposing Transport)
    /// Accepts AnyServerEvent (type-erased root type).
    private let sendEventHandler: @Sendable (AnyServerEvent, EventTarget) async -> Void

    /// Sync handler closure (delegates to Runtime layer without exposing Transport)
    private let syncHandler: @Sendable () async -> Void

    /// Storage for resolver outputs (dynamically populated based on @Resolvers declaration)
    private var resolverOutputs: [String: any ResolverOutput] = [:]

    /// Internal initializer for creating LandContext
    internal init(
        landID: String,
        playerID: PlayerID,
        clientID: ClientID,
        sessionID: SessionID,
        services: LandServices,
        logger: Logger,
        deviceID: String? = nil,
        isGuest: Bool = false,
        metadata: [String: String] = [:],
        sendEventHandler: @escaping @Sendable (AnyServerEvent, EventTarget) async -> Void,
        syncHandler: @escaping @Sendable () async -> Void
    ) {
        self.landID = landID
        self.playerID = playerID
        self.clientID = clientID
        self.sessionID = sessionID
        self.deviceID = deviceID
        self.isGuest = isGuest
        self.metadata = metadata
        self.services = services
        self.logger = logger
        self.sendEventHandler = sendEventHandler
        self.syncHandler = syncHandler
    }

    // MARK: - Public Methods

    /// Send event to specified target
    ///
    /// Events are sent through closure delegation, without exposing Transport details.
    /// The actual implementation is handled by the Runtime layer (LandKeeper).
    ///
    /// The event is automatically converted to `AnyServerEvent` using the type name as the event identifier.
    ///
    /// - Parameters:
    ///   - event: ServerEventPayload to send
    ///   - target: EventTarget specifying recipients
    public func sendEvent(_ event: any ServerEventPayload, to target: EventTarget) async {
        // Convert to AnyServerEvent using the type name
        let anyEvent = AnyServerEvent(event)
        await sendEventHandler(anyEvent, target)
    }

    /// Manually force immediate state synchronization (regardless of Tick configuration)
    public func syncNow() async {
        await syncHandler()
    }

    /// Spawn a background task without blocking the current handler.
    ///
    /// This method creates a new `Task` that executes asynchronously in the background,
    /// allowing the current synchronous handler to continue immediately without waiting.
    ///
    /// **Important**: This method does NOT block the current execution. The handler
    /// continues immediately after calling `spawn`, while the background task runs
    /// concurrently. This is safe to use in synchronous Action/Event handlers.
    ///
    /// This is especially useful in:
    /// - **Synchronous Action/Event handlers**: When you need to perform async operations
    ///   (like sending events) without blocking the handler execution
    /// - **OnTick handlers**: To maintain a stable tick rate while performing async I/O
    ///
    /// Example in Action handler:
    /// ```swift
    /// HandleAction(UpdateCart.self) { state, action, ctx in
    ///     // Synchronous state mutation
    ///     state.cart.items.append(item)
    ///     
    ///     // Spawn async operation without blocking
    ///     ctx.spawn {
    ///         await ctx.sendEvent(CartUpdatedEvent(), to: .all)
    ///     }
    ///     // Handler continues immediately, event is sent in background
    /// }
    /// ```
    ///
    /// Example in Event handler:
    /// ```swift
    /// HandleEvent(ChatEvent.self) { state, event, ctx in
    ///     state.messages.append(event.message)
    ///     
    ///     ctx.spawn {
    ///         await ctx.sendEvent(ChatMessageEvent(message: event.message), to: .all)
    ///     }
    /// }
    /// ```
    ///
    /// Example in OnTick handler:
    /// ```swift
    /// OnTick(every: .milliseconds(50)) { state, ctx in
    ///     state.stepSimulation()  // sync logic
    ///     
    ///     ctx.spawn {
    ///         await ctx.flushMetricsIfNeeded()  // async I/O in background
    ///     }
    /// }
    /// ```
    public func spawn(_ operation: @escaping @Sendable () async -> Void) {
        // Create a new Task that runs in the background
        // This does NOT block - the handler continues immediately
        Task {
            await operation()
        }
    }

    // MARK: - Resolver Outputs

    /// Set a resolver output (internal use by runtime)
    ///
    /// This method is called by the runtime after resolving all declared resolvers.
    /// The property name is derived from the resolver type name (e.g., "ProductInfoResolver" -> "productInfo").
    internal mutating func setResolverOutput<Output: ResolverOutput>(
        _ output: Output,
        forPropertyName propertyName: String
    ) {
        resolverOutputs[propertyName] = output
    }

    /// Get a resolver output by property name (internal use)
    internal func getResolverOutput<Output: ResolverOutput>(
        _ type: Output.Type,
        forPropertyName propertyName: String
    ) -> Output? {
        return resolverOutputs[propertyName] as? Output
    }

    // MARK: - Dynamic Member Lookup

    /// Dynamic member lookup for resolver outputs
    ///
    /// Allows accessing resolver outputs using dot notation:
    /// ```swift
    /// let productInfo = ctx.productInfo  // Returns ProductInfo?
    /// let userProfile = ctx.userProfile  // Returns UserProfileInfo?
    /// ```
    ///
    /// Property names are derived from resolver type names:
    /// - `ProductInfoResolver` -> `productInfo`
    /// - `UserProfileResolver` -> `userProfile`
    public subscript<T: ResolverOutput>(dynamicMember member: String) -> T? {
        return resolverOutputs[member] as? T
    }
}
