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
    /// List of registered action handlers, one per action type (#586): a later declaration for a
    /// type is kept in `duplicateHandlers`, not here.
    public let actionHandlers: [AnyActionHandler<State>]
    /// List of registered client event handlers (type-erased), one per event type (#586): a
    /// later declaration for a type is kept in `duplicateHandlers`, not here.
    public let eventHandlers: [AnyClientEventHandler<State>]
    /// Server input handlers (`HandleServerInput`), one per type identifier. Not part of the
    /// client schema.
    let serverInputHandlers: [String: AnyServerInputHandler<State>]
    /// Handlers declared for an action, client-event or server-input type that already had one
    /// (#586).
    /// Registration refuses such a land (`LandRegistrationError.duplicateHandlers`), and so does
    /// a keeper built without registration, at initialization.
    package let duplicateHandlers: [DuplicateHandlerDeclaration]
    /// Lifecycle handlers (join, leave, tick, shutdown).
    public let lifetimeHandlers: LifetimeHandlers<State>
    /// This definition's record schema fingerprint, computed once (#521 D15). A copy of the
    /// definition shares it; a definition built again computes its own.
    let schemaFingerprintCache = SchemaFingerprintCache()
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
    public var onJoin: (@Sendable (inout State, LandContext) -> Void)?
    
    /// Resolver executors for the onJoin handler (empty if no resolvers declared).
    public var onJoinResolverExecutors: [any AnyResolverExecutor]

    /// Handler called when a player leaves the Land.
    ///
    /// This is called just before the player is removed from the authoritative state.
    /// Use this to clean up player state or broadcast departure messages.
    public var onLeave: (@Sendable (inout State, LandContext) -> Void)?
    
    /// Resolver executors for the onLeave handler (empty if no resolvers declared).
    public var onLeaveResolverExecutors: [any AnyResolverExecutor]

    /// The interval at which the `tickHandler` should be called.
    public var tickInterval: Duration?

    /// Handler called periodically based on `tickInterval`.
    ///
    /// **Design Note**: This handler is synchronous and is used for game gameplay logic.
    /// Use this for game state updates, physics simulation, AI logic, etc.
    /// The tick handler is the only source of state mutations for replay functionality.
    /// Network synchronization is handled separately by the `syncInterval` mechanism.
    /// For deterministic outputs, use `ctx.emitEvent(...)` and `ctx.requestSyncNow()`.
    /// Avoid performing async I/O inside handlers; use out-of-band pipelines instead.
    public var tickHandler: (@Sendable (inout State, LandContext) -> Void)?
    
    /// The interval at which network synchronization should be triggered.
    ///
    /// **Design Note**: Sync is read-only and does not modify state. It only triggers
    /// the synchronization mechanism to send state updates to connected clients.
    /// The optional callback is read-only and can be used for logging, metrics, or other read-only operations.
    public var syncInterval: Duration?
    
    /// Optional read-only callback executed during sync operations.
    ///
    /// **Design Note**: This callback is read-only and should NOT modify state.
    /// The `State` parameter is passed as a value (not `inout`) to emphasize its read-only nature.
    /// Use this callback for logging, metrics collection, or other read-only operations during sync.
    public var syncHandler: (@Sendable (State, LandContext) -> Void)?

    /// Duration to wait before destroying the Land when it becomes empty.
    public var destroyWhenEmptyAfter: Duration?
    
    /// Handler called when the Land is being destroyed due to being empty.
    ///
    /// This is called specifically when the Land is destroyed because it became empty
    /// (after the `destroyWhenEmptyAfter` delay). It is executed before `OnFinalize`.
    /// Use this to perform cleanup actions specific to empty-room destruction.
    public var onDestroyWhenEmpty: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onDestroyWhenEmpty handler (empty if no resolvers declared).
    public var onDestroyWhenEmptyResolverExecutors: [any AnyResolverExecutor]

    /// Interval at which to persist the state snapshot.
    public var persistInterval: Duration?

    /// Handler called when the Land is initialized (on creation).
    ///
    /// This is called once when the Land is created, before any players join.
    /// It can use resolvers to load initial configuration or setup data.
    public var onInitialize: (@Sendable (inout State, LandContext) throws -> Void)?
    
    /// Resolver executors for the onInitialize handler (empty if no resolvers declared).
    public var onInitializeResolverExecutors: [any AnyResolverExecutor]

    /// What a throwing OnInitialize resolver does (#238); `.failLand` by default.
    public var onInitializeResolverFailure: InitializeResolverFailure
    
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
    public var afterFinalize: (@Sendable (State, LandContext) async -> Void)?
    
    /// Handler called when the Land is shutting down.
    ///
    /// **Deprecated**: Use `OnFinalize` (sync, supports resolvers) and `AfterFinalize` (async) instead.
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        canJoin: (@Sendable (State, PlayerSession, LandContext) throws -> JoinDecision)? = nil,
        canJoinResolverExecutors: [any AnyResolverExecutor] = [],
        onJoin: (@Sendable (inout State, LandContext) -> Void)? = nil,
        onJoinResolverExecutors: [any AnyResolverExecutor] = [],
        onLeave: (@Sendable (inout State, LandContext) -> Void)? = nil,
        onLeaveResolverExecutors: [any AnyResolverExecutor] = [],
        tickInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) -> Void)? = nil,
        syncInterval: Duration? = nil,
        syncHandler: (@Sendable (State, LandContext) -> Void)? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        onDestroyWhenEmpty: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onDestroyWhenEmptyResolverExecutors: [any AnyResolverExecutor] = [],
        persistInterval: Duration? = nil,
        onInitialize: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onInitializeResolverExecutors: [any AnyResolverExecutor] = [],
        onInitializeResolverFailure: InitializeResolverFailure = .failLand,
        onFinalize: (@Sendable (inout State, LandContext) throws -> Void)? = nil,
        onFinalizeResolverExecutors: [any AnyResolverExecutor] = [],
        afterFinalize: (@Sendable (State, LandContext) async -> Void)? = nil,
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
        self.syncInterval = syncInterval
        self.syncHandler = syncHandler
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.onDestroyWhenEmpty = onDestroyWhenEmpty
        self.onDestroyWhenEmptyResolverExecutors = onDestroyWhenEmptyResolverExecutors
        self.persistInterval = persistInterval
        self.onInitialize = onInitialize
        self.onInitializeResolverExecutors = onInitializeResolverExecutors
        self.onInitializeResolverFailure = onInitializeResolverFailure
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
    /// Where the handler was declared (`HandleAction`'s `fileID:line`), for the duplicate check.
    package let site: String?
    /// The handler's checks and its write, as one call: it throws only from the payload type
    /// check or `validate`, before anything is written (#586).
    private let handler: @Sendable (inout State, Any, LandContext) throws -> AnyCodable
    /// Resolver executors for this action handler (empty if no resolvers declared)
    public let resolverExecutors: [any AnyResolverExecutor]

    /// A handler in two stages (#586): `validate` reads the state, may throw, and returns the
    /// plan; `apply` writes, can't throw, and returns the action's declared `Response` (#561).
    /// There is no public form that takes a throwing body or answers with another type.
    public init<A: ActionPayload, Plan>(
        _ type: A.Type,
        validate: @escaping @Sendable (State, A, ValidateContext) throws -> Plan,
        apply: @escaping @Sendable (inout State, A, Plan, LandContext) -> A.Response,
        resolverExecutors: [any AnyResolverExecutor] = [],
        fileID: String = #fileID,
        line: Int = #line
    ) {
        self.init(
            type: type,
            responseType: A.Response.self,
            site: "\(fileID):\(line)",
            invoke: { state, anyAction, ctx in
                guard let action = anyAction as? A else {
                    throw LandError.invalidActionType
                }
                let plan = try validate(state, action, ValidateContext(ctx))
                return AnyCodable(apply(&state, action, plan, ctx))
            },
            resolverExecutors: resolverExecutors
        )
    }

    /// The DSL's form: `invoke` may throw only before it writes (the payload type check, or
    /// `validate`), and answers with `responseType`.
    package init(
        type: Any.Type,
        responseType: Any.Type?,
        site: String? = nil,
        invoke: @escaping @Sendable (inout State, Any, LandContext) throws -> AnyCodable,
        resolverExecutors: [any AnyResolverExecutor]
    ) {
        self.type = type
        self.responseType = responseType
        self.site = site
        self.handler = invoke
        self.resolverExecutors = resolverExecutors
    }

    /// The action type, for the one-handler-per-type check.
    package var handledType: Any.Type { type }

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
    /// Where the handler was declared (`HandleEvent`'s `fileID:line`), for the duplicate check.
    package let site: String?
    /// Throws only before it writes: from `validate` (#586).
    private let handler: @Sendable (inout State, AnyClientEvent, LandContext) throws -> Void

    /// A handler in two stages (#586): `validate` reads the state, may throw, and returns the
    /// plan; `apply` writes and can't throw. There is no public form that takes a throwing body.
    public init<E: ClientEventPayload, Plan>(
        eventType: E.Type,
        validate: @escaping @Sendable (State, E, ValidateContext) throws -> Plan,
        apply: @escaping @Sendable (inout State, E, Plan, LandContext) -> Void
    ) {
        self.init(eventType: eventType, site: nil, invoke: { state, event, ctx in
            let plan = try validate(state, event, ValidateContext(ctx))
            apply(&state, event, plan, ctx)
        })
    }

    /// The DSL's form: `invoke` may throw only before it writes (`validate`).
    package init<E: ClientEventPayload>(
        eventType: E.Type,
        site: String?,
        invoke: @escaping @Sendable (inout State, E, LandContext) throws -> Void
    ) {
        self.eventType = eventType
        self.site = site
        self.handler = { state, anyEvent, ctx in
            // Decode the event from AnyClientEvent
            let decoder = JSONDecoder()
            if let event = try? InboundPayloadDecoding.decode(E.self, from: anyEvent.payload, decoder: decoder) {
                try invoke(&state, event, ctx)
            }
        }
    }

    /// The event type this handler handles.
    package var handledType: Any.Type { eventType }

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

// MARK: - Duplicate handlers (#586)

/// A handler declared for an action, client-event or server-input type that already had one
/// (#586), or a type whose wire name another type of the same kind already has (#599). An input
/// runs exactly one `validate` and one `apply`, and is dispatched by name, so a land declares one
/// handler per type and gives each type its own name.
public struct DuplicateHandlerDeclaration: Sendable, Equatable, CustomStringConvertible {
    /// `"action"`, `"client event"`, `"server input"` or `"server event"` (a registered server
    /// event type, named on the wire like a client event).
    public let kind: String
    /// The type's name: the duplicate's, or for a shared wire name the second type's.
    public let typeName: String
    /// For a shared wire name: the first type that has it.
    public let firstTypeName: String?
    /// For a shared wire name: the name both types are matched by (#599); nil for one type
    /// declared twice.
    public let wireName: String?
    /// Where the kept handler and the duplicate were declared (`fileID:line`), when known.
    public let firstSite: String?
    public let duplicateSite: String?

    package init(
        kind: String,
        typeName: String,
        firstSite: String?,
        duplicateSite: String?,
        firstTypeName: String? = nil,
        wireName: String? = nil
    ) {
        self.kind = kind
        self.typeName = typeName
        self.firstTypeName = firstTypeName
        self.wireName = wireName
        self.firstSite = firstSite
        self.duplicateSite = duplicateSite
    }

    public var description: String {
        let sites = "at \(firstSite ?? "unknown") and \(duplicateSite ?? "unknown")"
        if let wireName {
            // Event registrations carry no declaration site.
            let located = firstSite == nil && duplicateSite == nil ? "" : " (\(sites))"
            return "\(kind) types \(firstTypeName ?? "unknown") and \(typeName) are both matched by the name \(wireName)\(located); give each type its own name"
        }
        return "\(kind) \(typeName) has two handlers (\(sites)); declare one handler per type"
    }
}
