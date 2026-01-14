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
    // MARK: - System IDs
    
    /// System player ID used for system operations (Tick, OnInitialize, OnFinalize, AfterFinalize).
    ///
    /// Use this to identify system-initiated operations in handlers.
    /// Example: `if ctx.playerID == LandContext.systemPlayerID { ... }`
    public static let systemPlayerID = PlayerID("_system")
    
    /// System client ID used for system operations.
    public static let systemClientID = ClientID("_system")
    
    /// System session ID used for system operations.
    public static let systemSessionID = SessionID("_system")
    
    /// Invalid player slot constant (used when player slot is not available).
    ///
    /// This value is returned when:
    /// - The context is for a system operation (not a real player)
    /// - The transport layer doesn't support player slots
    /// - The player hasn't been assigned a slot yet
    ///
    /// Example usage:
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     let slot = ctx.playerSlot ?? LandContext.invalidPlayerSlot
    ///     if slot != LandContext.invalidPlayerSlot {
    ///         print("Player has valid slot: \(slot)")
    ///     }
    /// }
    /// ```
    public static let invalidPlayerSlot: Int32 = -1
    
    // MARK: - Instance Properties
    
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

    /// Tick ID for deterministic replay (0-based, increments with each tick).
    ///
    /// **In tick handlers**: Represents the current tick number being executed.
    /// **In action/event handlers**: Represents the last committed tick ID (the most recent
    /// tick that has completed execution). This represents the world state's current committed
    /// tick, not the next tick that will execute. This allows actions/events to be bound to
    /// the committed world state for replay logging.
    ///
    /// **Replay logging format**: `tickId:action` or `tickId:event`
    /// This allows replay systems to record and replay actions/events in tick order.
    ///
    /// **Semantic clarity**:
    /// - Tick handler: `tickId` is the ID of the tick being executed (e.g., tick 100)
    /// - Action/Event handler: `tickId` is the last committed tick (e.g., tick 100 if executed
    ///   after tick 100 completes but before tick 101 starts)
    ///
    /// **Type**: `Int64` for long-running servers and replay compatibility.
    /// At 60 Hz, Int64 can run for ~4.9 million years before overflow.
    ///
    /// To calculate deterministic time, use: `tickId * tickInterval`
    ///
    /// Example in tick handler:
    /// ```swift
    /// Tick(every: .milliseconds(50)) { state, ctx in
    ///     // Use tickId for deterministic logic
    ///     if let tickId = ctx.tickId {
    ///         let gameTime = Double(tickId) * 0.05  // 50ms = 0.05s
    ///         state.position += state.velocity * 0.05  // Deterministic movement
    ///     }
    /// }
    /// ```
    ///
    /// Example in action handler (for replay logging):
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     // tickId is available for replay logging
    ///     // Log format: tickId:action (e.g., "42:AttackAction")
    ///     state.applyAttack(action, atTick: ctx.tickId)
    /// }
    /// ```
    public let tickId: Int64?

    /// Player slot for the current player (deterministic Int32 identifier for transport encoding).
    ///
    /// This is a deterministic slot number allocated for the current player, used for efficient
    /// transport encoding (e.g., in opcode-based state updates). The slot is allocated when the
    /// player joins and remains stable for the duration of their session.
    ///
    /// **Availability**:
    /// - Available in Action/Event handlers (for joined players)
    /// - `nil` for system operations (Tick, OnInitialize, OnFinalize, etc.)
    /// - `nil` if transport layer doesn't support player slots
    ///
    /// Example usage:
    /// ```swift
    /// HandleAction(AttackAction.self) { state, action, ctx in
    ///     if let slot = ctx.playerSlot {
    ///         print("Player \(ctx.playerID) has slot \(slot)")
    ///     }
    /// }
    /// ```
    public let playerSlot: Int32?

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
        tickId: Int64? = nil,
        playerSlot: Int32? = nil,
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
        self.tickId = tickId
        self.playerSlot = playerSlot
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
