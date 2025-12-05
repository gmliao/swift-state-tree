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
    /// Can perform async validation and throw errors to reject the join.
    public var canJoin: (@Sendable (State, PlayerSession, LandContext) async throws -> JoinDecision)?

    /// Handler called when a player successfully joins the Land.
    ///
    /// This is called after the player has been added to the authoritative state.
    /// Use this to initialize player-specific state or broadcast welcome messages.
    public var onJoin: (@Sendable (inout State, LandContext) async -> Void)?

    /// Handler called when a player leaves the Land.
    ///
    /// This is called just before the player is removed from the authoritative state.
    /// Use this to clean up player state or broadcast departure messages.
    public var onLeave: (@Sendable (inout State, LandContext) async -> Void)?

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

    /// Handler called when the Land is shutting down.
    ///
    /// Use this to save final state or perform cleanup.
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        canJoin: (@Sendable (State, PlayerSession, LandContext) async throws -> JoinDecision)? = nil,
        onJoin: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        onLeave: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        tickInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) -> Void)? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
        self.canJoin = canJoin
        self.onJoin = onJoin
        self.onLeave = onLeave
        self.tickInterval = tickInterval
        self.tickHandler = tickHandler
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
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
    private let handler: @Sendable (inout State, Any, LandContext) async throws -> AnyCodable

    public init(
        type: Any.Type,
        handler: @escaping @Sendable (inout State, Any, LandContext) async throws -> AnyCodable
    ) {
        self.type = type
        self.handler = handler
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

    public func invoke<A: ActionPayload>(
        _ state: inout State,
        action: A,
        ctx: LandContext
    ) async throws -> AnyCodable {
        try await handler(&state, action, ctx)
    }
}

// MARK: - Client Event Handler Type Erasure

/// Type-erased client event handler collected from the DSL.
///
/// Wraps a strongly-typed event handler. Unlike actions, event handlers are typically
/// invoked for all matching events (or specific enum cases if using the generated helpers).
public struct AnyClientEventHandler<State: StateNodeProtocol>: LandNode {
    private let eventType: Any.Type
    private let handler: @Sendable (inout State, AnyClientEvent, LandContext) async -> Void

    public init<E: ClientEventPayload>(
        eventType: E.Type,
        handler: @escaping @Sendable (inout State, E, LandContext) async -> Void
    ) {
        self.eventType = eventType
        self.handler = { state, anyEvent, ctx in
            // Decode the event from AnyClientEvent
            let decoder = JSONDecoder()
            if let data = try? JSONEncoder().encode(anyEvent.payload),
               let event = try? decoder.decode(E.self, from: data) {
                await handler(&state, event, ctx)
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
    ) async {
        await handler(&state, event, ctx)
    }
}
