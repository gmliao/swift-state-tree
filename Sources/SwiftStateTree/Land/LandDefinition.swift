import Foundation

// MARK: - Land Definition

/// Type-erased definition built by the Land DSL.
///
/// It captures all the configuration, handlers, and metadata that the runtime (`LandKeeper`)
/// needs in order to operate a single land instance.
///
/// This structure acts as the blueprint for creating a `LandKeeper` actor. It decouples the
/// declarative DSL from the runtime execution logic.
public struct LandDefinition<State: StateNodeProtocol>: Sendable {
    /// Unique identifier for this Land definition (e.g., "battle-royale", "lobby").
    public let id: String
    /// The type of the root state node managed by this Land.
    public let stateType: State.Type
    /// Registry of registered client event types.
    ///
    /// These are collected via the `ClientEvents { Register(...) }` DSL and are used for
    /// schema generation and runtime validation (e.g., warnings for unregistered event types).
    public let clientEventRegistry: EventRegistry<AnyClientEvent>
    /// Registry of registered server event types.
    ///
    /// These are collected via the `ServerEvents { Register(...) }` DSL and are used for
    /// schema generation and runtime validation (e.g., warnings for unregistered event types).
    public let serverEventRegistry: EventRegistry<AnyServerEvent>
    /// Aggregated configuration (access control, lifetime, etc.).
    public let config: LandConfig
    /// List of registered action handlers.
    public let actionHandlers: [AnyActionHandler<State>]
    /// List of registered client event handlers (type-erased).
    public let eventHandlers: [AnyClientEventHandler<State>]
    /// Lifecycle handlers (join, leave, tick, shutdown).
    public let lifetimeHandlers: LifetimeHandlers<State>
}

// MARK: - Lifetime Handlers

/// Collection of lifecycle handlers extracted from the DSL.
///
/// These handlers define how the Land reacts to lifecycle events such as players joining/leaving,
/// periodic ticks, and system shutdown.
public struct LifetimeHandlers<State: StateNodeProtocol>: Sendable {
    /// Handler called before a player joins to validate the join request.
    ///
    /// This is called BEFORE the player is added to the state (read-only view).
    /// Can use resolvers to load validation data.
    public var canJoin: (@Sendable (State, PlayerSession, LandContext) throws -> JoinDecision)?
    
    /// Resolver executors for the canJoin handler (empty if no resolvers declared).
    public var canJoinResolverExecutors: [any AnyResolverExecutor]

    /// Handler called when a player successfully joins the Land.
    ///
    /// This is called after the player has been added to the authoritative state.
    /// Use this to initialize player-specific state or broadcast welcome messages.
    public var onJoin: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onJoin handler (empty if no resolvers declared).
    public var onJoinResolverExecutors: [any AnyResolverExecutor]

    /// Handler called when a player leaves the Land.
    ///
    /// This is called just before the player is removed from the authoritative state.
    /// Use this to clean up player state or broadcast departure messages.
    public var onLeave: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onLeave handler (empty if no resolvers declared).
    public var onLeaveResolverExecutors: [any AnyResolverExecutor]

    /// The interval at which the `tickHandler` should be called.
    public var tickInterval: Duration?

    /// Handler called periodically based on `tickInterval`.
    ///
    /// **Design Note**: This handler is synchronous to maintain stable tick rates.
    /// For async operations (e.g., metrics, logging), use `ctx.spawn { await ... }`.
    public var tickHandler: (@Sendable (inout State, LandContext) -> Void)?

    /// Duration to wait before destroying the Land when it becomes empty.
    public var destroyWhenEmptyAfter: Duration?

    /// Interval at which to persist the state snapshot.
    public var persistInterval: Duration?

    /// Handler called when the Land is initialized (on creation).
    ///
    /// This is called once when the Land is created, before any players join.
    /// It can use resolvers to load initial configuration or setup data.
    public var onInitialize: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onInitialize handler (empty if no resolvers declared).
    public var onInitializeResolverExecutors: [any AnyResolverExecutor]
    
    /// Handler called when the Land is finalizing (before shutdown).
    ///
    /// This is called before the Land is destroyed, while state is still mutable.
    /// It can use resolvers to save final state or perform cleanup.
    public var onFinalize: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onFinalize handler (empty if no resolvers declared).
    public var onFinalizeResolverExecutors: [any AnyResolverExecutor]
    
    /// Handler called after the Land is completely finalized (async cleanup).
    ///
    /// This is called after OnFinalize, when state is no longer mutable.
    /// Use this for async cleanup operations (e.g., closing database connections, sending metrics).
    public var afterFinalize: (@Sendable (State) async -> Void)?
    
    /// Handler called when the Land is shutting down.
    ///
    /// **Deprecated**: Use `OnFinalize` (sync, supports resolvers) and `AfterFinalize` (async) instead.
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        canJoin: (@Sendable (State, PlayerSession, LandContext) throws -> JoinDecision)? = nil,
        canJoinResolverExecutors: [any AnyResolverExecutor] = [],
        onJoin: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onJoinResolverExecutors: [any AnyResolverExecutor] = [],
        onLeave: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onLeaveResolverExecutors: [any AnyResolverExecutor] = [],
        tickInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) -> Void)? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        onInitialize: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onInitializeResolverExecutors: [any AnyResolverExecutor] = [],
        onFinalize: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onFinalizeResolverExecutors: [any AnyResolverExecutor] = [],
        afterFinalize: (@Sendable (State) async -> Void)? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
        self.canJoin = canJoin
        self.canJoinResolverExecutors = canJoinResolverExecutors
        self.onJoin = onJoin
        self.onJoinResolverExecutors = onJoinResolverExecutors
        self.onLeave = onLeave
        self.onLeaveResolverExecutors = onLeaveResolverExecutors
        self.tickInterval = tickInterval
        self.tickHandler = tickHandler
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
        self.onInitialize = onInitialize
        self.onInitializeResolverExecutors = onInitializeResolverExecutors
        self.onFinalize = onFinalize
        self.onFinalizeResolverExecutors = onFinalizeResolverExecutors
        self.afterFinalize = afterFinalize
        self.onShutdown = onShutdown
    }
}

// MARK: - Action Handler Type Erasure

/// Type-erased action handler collected from the DSL.
///
/// Wraps a strongly-typed action handler into a generic form that can be stored and invoked
/// by the runtime. The runtime uses `canHandle` to check if this handler supports a specific
/// action type.
public struct AnyActionHandler<State: StateNodeProtocol>: LandNode {
    private let type: Any.Type
    private let responseType: Any.Type?
    private let handler: @Sendable (inout State, Any, LandContext) throws -> AnyCodable
    /// Resolver executors for this action handler (empty if no resolvers declared)
    public let resolverExecutors: [any AnyResolverExecutor]

    public init(
        type: Any.Type,
        responseType: Any.Type? = nil,
        handler: @escaping @Sendable (inout State, Any, LandContext) throws -> AnyCodable,
        resolverExecutors: [any AnyResolverExecutor] = []
    ) {
        self.type = type
        self.responseType = responseType
        self.handler = handler
        self.resolverExecutors = resolverExecutors
    }

    public func canHandle(_ actionType: Any.Type) -> Bool {
        actionType == type
    }
    
    /// Get the action type that this handler can handle.
    ///
    /// This is useful for schema generation and introspection.
    public func getActionType() -> Any.Type {
        return type
    }
    
    /// Get the response type for this action handler.
    ///
    /// This is useful for schema generation.
    public func getResponseType() -> Any.Type? {
        return responseType
    }

    public func invoke<A: ActionPayload>(
        _ state: inout State,
        action: A,
        ctx: LandContext
    ) throws -> AnyCodable {
        try handler(&state, action, ctx)
    }
    
    /// Invoke using an already type-erased action payload.
    public func invokeErased(
        _ state: inout State,
        action: Any,
        ctx: LandContext
    ) throws -> AnyCodable {
        try handler(&state, action, ctx)
    }
}

// MARK: - Client Event Handler Type Erasure

/// Type-erased client event handler collected from the DSL.
///
/// Wraps a strongly-typed event handler. Unlike actions, event handlers are typically
/// invoked for all matching events (or specific enum cases if using the generated helpers).
public struct AnyClientEventHandler<State: StateNodeProtocol>: LandNode {
    private let eventType: Any.Type
    private let handler: @Sendable (inout State, AnyClientEvent, LandContext) throws -> Void

    public init<E: ClientEventPayload>(
        eventType: E.Type,
        handler: @escaping @Sendable (inout State, E, LandContext) throws -> Void
    ) {
        self.eventType = eventType
        self.handler = { state, anyEvent, ctx in
            // Decode the event from AnyClientEvent
            let decoder = JSONDecoder()
            if let data = try? JSONEncoder().encode(anyEvent.payload),
               let event = try? decoder.decode(E.self, from: data) {
                try handler(&state, event, ctx)
            }
        }
    }

    public func canHandle(_ eventType: Any.Type) -> Bool {
        self.eventType == eventType
    }

    public func invoke(
        _ state: inout State,
        event: AnyClientEvent,
        ctx: LandContext
    ) throws {
        try handler(&state, event, ctx)
    }
}
