import Foundation

// MARK: - Land Node Protocol

/// A marker protocol for all components within the Land DSL.
///
/// A land body's builder (`LandDSL<State, Services>`) takes each node through a typed
/// `buildExpression`, so a node for another State is refused where it is written, and the
/// handler closures in it get their types from the land (#771). The `LandBuilder` collects the
/// nodes into the definition.
public protocol LandNode: Sendable {}

/// The services type of a land that declares none: `Land(_:using:)`'s, and a helper's under
/// `@LandDSL<State, NoServices>`.
public struct NoServices: Sendable {
    public init() {}
}

// MARK: - Access Control

public struct AccessControlNode: LandNode {
    public let config: AccessControlConfig
}

public typealias AccessControlDirective = (inout AccessControlConfig) -> Void

@resultBuilder
public enum AccessControlBuilder {
    public static func buildBlock(_ components: AccessControlDirective...)
        -> [AccessControlDirective]
    {
        components
    }
}

/// Defines the access control policy for the Land.
///
/// Use this block to configure who can join the Land and under what conditions.
///
/// Example:
/// ```swift
/// AccessControl {
///     AllowPublic()
///     MaxPlayers(8)
/// }
/// ```
public func AccessControl(
    _ configure: (inout AccessControlConfig) -> Void
) -> AccessControlNode {
    var config = AccessControlConfig()
    configure(&config)
    return AccessControlNode(config: config)  // Multi-line: must include return
}

/// Defines the access control policy for the Land using a result builder.
///
/// This overload allows using the declarative syntax with `AccessControlBuilder`.
public func AccessControl(
    @AccessControlBuilder _ content: () -> [AccessControlDirective]
) -> AccessControlNode {
    var config = AccessControlConfig()
    content().forEach { $0(&config) }
    return AccessControlNode(config: config)  // Multi-line: must include return
}

/// Sets whether the Land is publicly visible and joinable.
///
/// - Parameter allow: `true` to allow public access, `false` for private. Default is `true`.
public func AllowPublic(_ allow: Bool = true) -> AccessControlDirective {
    { $0.allowPublic = allow }  // Single-expression: omit return
}

/// Sets the maximum number of players allowed in the Land.
///
/// - Parameter value: The maximum player count.
public func MaxPlayers(_ value: Int) -> AccessControlDirective {
    { $0.maxPlayers = value }  // Single-expression: omit return
}

// MARK: - Rules

/// A `Rules` block's nodes. The land's builder flattens it into the land's nodes, so it isn't a
/// `LandNode` itself and never reaches the `LandBuilder` (#771 §3.1).
public struct RulesNode<State: StateNodeProtocol, Services: Sendable>: Sendable {
    public let nodes: [LandNode]
}

/// Defines the rules and behaviors of the Land.
///
/// This block contains event handlers, action handlers, and other rule definitions.
///
/// Example:
/// ```swift
/// Rules {
///     OnJoin { ... }
///     HandleAction(Move.self) { ... }
/// }
/// ```
///
/// Inside a land, `Rules` takes the land's `State` and `Services`. Outside one (a helper, a
/// local), name them: `-> RulesNode<GameState, NoServices>`.
public func Rules<State: StateNodeProtocol, Services: Sendable>(
    @LandDSL<State, Services> _ content: () -> [LandNode]
) -> RulesNode<State, Services> {
    RulesNode(nodes: content())  // Single-expression: omit return
}

public struct OnJoinNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) -> Void
    public let resolverExecutors: [any AnyResolverExecutor]
    
    public init(
        handler: @escaping @Sendable (inout State, LandContext) -> Void,
        resolverExecutors: [any AnyResolverExecutor] = []
    ) {
        self.handler = handler
        self.resolverExecutors = resolverExecutors
    }
}

/// Registers a handler called when a player joins the Land.
///
/// This handler is executed after the player is added to the state. It can't throw (#586):
/// whether a player may join is `CanJoin`'s decision, made at join intake. `OnJoin` applies in a
/// later turn, so a `CanJoin` check on state that other inputs change can be stale by then (an
/// in-turn join check is #588). Keep such checks out of `CanJoin`, and handle a joiner that no
/// longer fits in `OnJoin` itself: make them a spectator, or emit an event asking them to leave.
///
/// - Parameter body: The synchronous closure to execute.
public func OnJoin<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(handler: body)  // Single-expression: omit return
}

/// Registers a handler called when a player joins the Land with resolvers.
///
/// This handler is executed after the player is added to the state.
/// Resolvers are executed in parallel before the handler runs.
///
/// - Parameters:
///   - resolvers: One or more resolver types to execute before the handler.
///   - body: The synchronous closure to execute with resolved data available via `ctx`.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: body,
        resolverExecutors: [ResolverExecutorWrapper<R1>()]
    )  // Single-expression: omit return
}

/// Registers a handler called when a player joins the Land with multiple resolvers.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: body,
        resolverExecutors: [ResolverExecutorWrapper<R1>(), ResolverExecutorWrapper<R2>()]
    )  // Single-expression: omit return
}

/// Registers a handler called when a player joins the Land with multiple resolvers.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: body,
        resolverExecutors: [
            ResolverExecutorWrapper<R1>(),
            ResolverExecutorWrapper<R2>(),
            ResolverExecutorWrapper<R3>()
        ]
    )  // Single-expression: omit return
}

public struct OnLeaveNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) -> Void
    public let resolverExecutors: [any AnyResolverExecutor]
    
    public init(
        handler: @escaping @Sendable (inout State, LandContext) -> Void,
        resolverExecutors: [any AnyResolverExecutor] = []
    ) {
        self.handler = handler
        self.resolverExecutors = resolverExecutors
    }
}

/// Registers a handler called when a player leaves the Land.
///
/// This handler is executed just before the player is removed from the state. It can't throw
/// (#586): a leave always happens.
///
/// - Parameter body: The synchronous closure to execute.
public func OnLeave<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(handler: body)  // Single-expression: omit return
}

/// Registers a handler called when a player leaves the Land with resolvers.
///
/// This handler is executed just before the player is removed from the state.
/// Resolvers are executed in parallel before the handler runs.
///
/// - Parameters:
///   - resolvers: One or more resolver types to execute before the handler.
///   - body: The synchronous closure to execute with resolved data available via `ctx`.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: body,
        resolverExecutors: [ResolverExecutorWrapper<R1>()]
    )  // Single-expression: omit return
}

/// Registers a handler called when a player leaves the Land with multiple resolvers.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: body,
        resolverExecutors: [ResolverExecutorWrapper<R1>(), ResolverExecutorWrapper<R2>()]
    )  // Single-expression: omit return
}

/// Registers a handler called when a player leaves the Land with multiple resolvers.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: body,
        resolverExecutors: [
            ResolverExecutorWrapper<R1>(),
            ResolverExecutorWrapper<R2>(),
            ResolverExecutorWrapper<R3>()
        ]
    )  // Single-expression: omit return
}

public struct CanJoinNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision
    public let resolverExecutors: [any AnyResolverExecutor]
    
    public init(
        handler: @escaping @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision,
        resolverExecutors: [any AnyResolverExecutor] = []
    ) {
        self.handler = handler
        self.resolverExecutors = resolverExecutors
    }
}

/// Registers a handler called before a player joins to validate the join request.
///
/// This handler is executed BEFORE the player is added to the authoritative state.
/// It receives a read-only view of the state and can use resolvers to load data.
///
/// If the handler throws an error or returns `.deny`, the join is rejected.
/// If it returns `.allow(playerID)`, the player is added to the Land with that PlayerID.
///
/// Example:
/// ```swift
/// CanJoin { state, session, ctx in
///     // Check room capacity
///     guard state.players.count < 8 else {
///         throw JoinError.roomIsFull
///     }
///     
///     // Use resolver output (e.g., userProfile from UserProfileResolver)
///     if let profile = ctx.userProfile {
///         guard profile.level >= 5 else {
///             throw JoinError.levelTooLow(required: 5)
///         }
///     }
///
///     return .allow(playerID: PlayerID(session.playerID))
/// }
/// ```
///
/// - Parameter body: The synchronous closure that validates the join request.
public func CanJoin<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(handler: body)  // Single-expression: omit return
}

/// Registers a handler called before a player joins with resolvers.
///
/// - Parameters:
///   - resolvers: One or more resolver types to execute before the handler.
///   - body: The synchronous closure that validates the join request with resolved data available via `ctx`.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    _ body: @escaping @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: body,
        resolverExecutors: [ResolverExecutor.createExecutor(for: resolvers)]
    )  // Single-expression: omit return
}

/// Registers a handler called before a player joins with multiple resolvers.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    _ body: @escaping @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: body,
        resolverExecutors: [
            ResolverExecutor.createExecutor(for: resolvers.0),
            ResolverExecutor.createExecutor(for: resolvers.1)
        ]
    )  // Single-expression: omit return
}

/// Registers a handler called before a player joins with multiple resolvers.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    _ body: @escaping @Sendable (State, PlayerSession, LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: body,
        resolverExecutors: [
            ResolverExecutor.createExecutor(for: resolvers.0),
            ResolverExecutor.createExecutor(for: resolvers.1),
            ResolverExecutor.createExecutor(for: resolvers.2)
        ]
    )  // Single-expression: omit return
}

public struct AllowedClientEventsNode: LandNode {
    public let allowed: Set<AllowedEventIdentifier>
}

@resultBuilder
public enum AllowedClientEventsBuilder {
    public static func buildBlock(_ components: AllowedEventIdentifier...)
        -> [AllowedEventIdentifier]
    {
        components
    }

    public static func buildExpression<E: Hashable & Sendable>(_ expression: E)
        -> AllowedEventIdentifier
    {
        AllowedEventIdentifier(expression)
    }
}

/// explicitly lists the client events allowed to be sent to this Land.
///
/// If specified, the transport layer can reject unauthorized events early.
///
/// Example:
/// ```swift
/// AllowedClientEvents {
///     ClientEvents.move
///     ClientEvents.chat
/// }
/// ```
public func AllowedClientEvents(
    @AllowedClientEventsBuilder _ content: () -> [AllowedEventIdentifier]
) -> AllowedClientEventsNode {
    AllowedClientEventsNode(allowed: Set(content()))  // Single-expression: omit return
}

// MARK: - Lifetime

public struct LifetimeNode<State: StateNodeProtocol>: LandNode {
    public let configure: @Sendable (inout LifetimeConfig<State>) -> Void
}

// MARK: - Helper Functions for On* Handlers

/// Helper function to warn when a handler is already defined
private func warnIfHandlerAlreadyDefined(_ handlerName: String, isDefined: Bool) {
    guard isDefined else { return }
    let message = "⚠️ [LandDSL] \(handlerName) handler is already defined. The previous handler will be replaced.\n"
    writeStandardErrorDiagnostic(message)
}

public struct LifetimeConfig<State: StateNodeProtocol>: Sendable {
    public var tickInterval: Duration?
    public var destroyWhenEmptyAfter: Duration?
    public var persistInterval: Duration?
    /// Handler called periodically based on `tickInterval`.
    ///
    /// **Design Note**: This handler is synchronous and is used for game gameplay logic.
    /// Use this for game state updates, physics simulation, AI logic, etc.
    /// Unlike `sync`, this handler can modify state and is the only source of state mutations
    /// for replay functionality. Network synchronization is handled separately by the `sync` mechanism.
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
    
    /// Handler called when the Land is initialized (on creation): a body that can't fail, or
    /// `validate` and `apply` (#593).
    public var onInitialize: InitializeHandler<State>?
    /// Resolver executors for the onInitialize handler.
    public var onInitializeResolverExecutors: [any AnyResolverExecutor] = []
    /// What a throwing OnInitialize resolver does (#238).
    public var onInitializeResolverFailure: InitializeResolverFailure = .failLand
    
    /// Handler called when the Land is finalizing (before shutdown).
    public var onFinalize: (@Sendable (inout State, LandContext) -> Void)?
    /// Resolver executors for the onFinalize handler.
    public var onFinalizeResolverExecutors: [any AnyResolverExecutor] = []
    
    /// Handler called after the Land is completely finalized (async cleanup).
    public var afterFinalize: (@Sendable (State, LandContext) async -> Void)?
    
    /// Handler called when the Land is being destroyed due to being empty.
    ///
    /// This is called specifically when the Land is destroyed because it became empty
    /// (after the `destroyWhenEmptyAfter` delay). It is executed before `OnFinalize`.
    /// Use this to perform cleanup actions specific to empty-room destruction.
    public var onDestroyWhenEmpty: (@Sendable (inout State, LandContext) -> Void)?
    
    /// Resolver executors for the onDestroyWhenEmpty handler.
    public var onDestroyWhenEmptyResolverExecutors: [any AnyResolverExecutor] = []
    
    /// Handler called when the Land is shutting down.
    ///
    /// **Deprecated**: Use `OnFinalize` (sync, supports resolvers) and `AfterFinalize` (async) instead.
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        tickInterval: Duration? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) -> Void)? = nil,
        syncInterval: Duration? = nil,
        syncHandler: (@Sendable (State, LandContext) -> Void)? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
        self.tickInterval = tickInterval
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
        self.tickHandler = tickHandler
        self.syncInterval = syncInterval
        self.syncHandler = syncHandler
        self.onShutdown = onShutdown
    }
}

public typealias LifetimeDirective<State: StateNodeProtocol> =
    @Sendable (inout LifetimeConfig<State>) -> Void

@resultBuilder
public enum LifetimeBuilder<State: StateNodeProtocol> {
    /// Typed, so a directive's closures (`Tick(every:) { state, ctx in }`) get the land's State
    /// without annotations (#771 D0 result 2).
    public static func buildExpression(_ directive: @escaping LifetimeDirective<State>) -> [LifetimeDirective<State>] {
        [directive]
    }

    public static func buildBlock(_ components: [LifetimeDirective<State>]...) -> [LifetimeDirective<State>] {
        components.flatMap { $0 }
    }
}

/// Defines the lifetime and periodic behaviors of the Land.
///
/// Use this block to configure ticks, auto-destruction, and persistence.
///
/// Example:
/// ```swift
/// Lifetime {
///     Tick(every: .milliseconds(50)) { ... }
///     DestroyWhenEmpty(after: .minutes(5))
/// }
/// ```
public func Lifetime<State: StateNodeProtocol>(
    _ configure: @escaping @Sendable (inout LifetimeConfig<State>) -> Void
) -> LifetimeNode<State> {
    LifetimeNode(configure: configure)  // Single-expression: omit return
}

/// Defines the lifetime and periodic behaviors of the Land using a result builder.
public func Lifetime<State: StateNodeProtocol>(
    @LifetimeBuilder<State> _ directives: @escaping @Sendable () -> [LifetimeDirective<State>]
) -> LifetimeNode<State> {
    LifetimeNode { config in
        directives().forEach { $0(&config) }
    }  // Single-expression: omit return
}

/// Configures a periodic tick handler for game gameplay logic.
///
/// **Design Note**: The tick handler is synchronous and is used for game gameplay logic.
/// Use this for game state updates, physics simulation, AI logic, etc.
/// The tick handler is the only source of state mutations for replay functionality.
/// Network synchronization is handled separately by the `Sync` mechanism.
/// If you need to emit server events or force a sync, use `ctx.emitEvent(...)` and
/// `ctx.requestSyncNow()` / `ctx.requestSyncBroadcastOnly()`.
///
/// Example:
/// ```swift
/// Tick(every: .milliseconds(50)) { state, ctx in
///     state.updatePhysics()  // Game gameplay logic
///     state.updateAI()       // AI updates
/// }
/// ```
///
/// - Parameters:
///   - interval: The duration between ticks.
///   - body: The synchronous handler to execute on each tick (for gameplay logic).
public func Tick<State: StateNodeProtocol>(
    every interval: Duration,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    return { config in
        config.tickInterval = interval
        config.tickHandler = body
    }
}

/// Configures a periodic tick handler without a handler closure.
///
/// This overload allows setting the tick interval without providing a handler.
/// Useful when you only need to configure the tick rate but don't need to execute
/// any logic on each tick.
///
/// Example:
/// ```swift
/// Lifetime {
///     Tick(every: .milliseconds(100))
/// }
/// ```
///
/// - Parameter interval: The duration between ticks.
public func Tick<State: StateNodeProtocol>(
    every interval: Duration
) -> LifetimeDirective<State> {
    return { config in
        config.tickInterval = interval
        config.tickHandler = nil
    }
}

/// Configures periodic state synchronization with a read-only callback.
///
/// **Design Note**: State sync is read-only and does not modify state. It only triggers
/// the synchronization mechanism to send state updates to connected clients.
/// The callback is read-only and will be called during sync operations.
/// Use this callback for logging, metrics collection, or other read-only operations.
/// Use `Tick` for game gameplay logic that modifies state.
///
/// Example:
/// ```swift
/// Lifetime {
///     Tick(every: .milliseconds(50)) { state, ctx in
///         state.updatePhysics()  // Game gameplay logic
///     }
///     StateSync(every: .milliseconds(100)) { state, ctx in
///         // Read-only callback - will be called during sync
///         // Do NOT modify state here - use Tick for state mutations
///         print("Syncing at tick \(ctx.tickId ?? -1)")
///     }
/// }
/// ```
///
/// - Parameters:
///   - interval: The duration between sync operations.
///   - body: A read-only callback to execute when sync is triggered.
public func StateSync<State: StateNodeProtocol>(
    every interval: Duration,
    _ body: @escaping @Sendable (State, LandContext) -> Void
) -> LifetimeDirective<State> {
    return { config in
        config.syncInterval = interval
        config.syncHandler = body
    }
}

/// Configures periodic state synchronization without a callback.
///
/// **Note**: This version requires explicit type specification in some contexts.
/// For better type inference, use the version with a callback parameter.
///
/// Example:
/// ```swift
/// Lifetime {
///     Tick(every: .milliseconds(50)) { state, ctx in
///         state.updatePhysics()
///     }
///     StateSync<GameState>(every: .milliseconds(100))  // Explicit type required
/// }
/// ```
///
/// - Parameter interval: The duration between sync operations.
public func StateSync<State: StateNodeProtocol>(
    every interval: Duration
) -> LifetimeDirective<State> {
    return { config in
        config.syncInterval = interval
    }
}

/// Configures the Land to automatically destroy itself when empty.
///
/// - Parameter duration: The duration to wait after the last player leaves before destroying.
public func DestroyWhenEmpty<State: StateNodeProtocol>(
    after duration: Duration
) -> LifetimeDirective<State> {
    return { config in
        config.destroyWhenEmptyAfter = duration
    }
}

/// Configures the Land to automatically destroy itself when empty with a cleanup handler.
///
/// The handler is executed when the Land is being destroyed due to being empty.
/// This provides a convenient way to perform cleanup actions specific to empty-room destruction.
/// The handler is executed before `OnFinalize`, allowing you to distinguish between
/// different destruction scenarios.
///
/// - Parameters:
///   - duration: The duration to wait after the last player leaves before destroying.
///   - handler: The cleanup handler to execute before destruction. It can't throw (#593), as
///     `OnFinalize`'s body can't.
public func DestroyWhenEmpty<State: StateNodeProtocol>(
    after duration: Duration,
    _ handler: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    return { config in
        config.destroyWhenEmptyAfter = duration
        config.onDestroyWhenEmpty = handler
    }
}


/// Configures the interval for persisting state snapshots.
///
/// - Parameter interval: The duration between snapshots.
public func PersistSnapshot<State: StateNodeProtocol>(
    every interval: Duration
) -> LifetimeDirective<State> {
    return { config in
        config.persistInterval = interval
    }
}

/// Installs OnInitialize's handler and its resolvers in the config: every form goes through here.
private func initializeDirective<State: StateNodeProtocol>(
    _ handler: InitializeHandler<State>,
    executors: [any AnyResolverExecutor],
    onResolverFailure: InitializeResolverFailure
) -> LifetimeDirective<State> {
    return { config in
        warnIfHandlerAlreadyDefined("OnInitialize", isDefined: config.onInitialize != nil)
        config.onInitialize = handler
        config.onInitializeResolverExecutors = executors
        config.onInitializeResolverFailure = onResolverFailure
    }
}

/// Registers a handler called when the Land is initialized (on creation).
///
/// This handler is executed once when the Land is created, before any players join.
/// It can use resolvers to load initial configuration or setup data.
///
/// The body can't throw (#593). An initialization that can be refused uses
/// `OnInitialize(validate:apply:)`: a `validate` throw fails the initialization with nothing
/// written.
///
/// - Parameter body: The synchronous closure to execute.
public func OnInitialize<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(InitializeHandler(body), executors: [], onResolverFailure: .failLand)
}

/// What a land does when one of its OnInitialize resolvers throws (#238). A timeout
/// (`RESOLVER_INIT_TIMEOUT_MS`) always fails the initialization, whatever the choice.
public enum InitializeResolverFailure: Sendable, Equatable {
    /// The initialization fails, as for a timeout: OnInitialize doesn't run, every call that
    /// waits for the initialization gets `LandInitializationError` (a join: `JOIN_DENIED`,
    /// retryable), and the land is torn down without its destroy handlers. The default.
    case failLand
    /// OnInitialize runs without the resolvers' outputs: none of the group's, not only the
    /// failing resolver's (the behaviour before #238). The handler must check every output it
    /// reads.
    case `continue`
}

/// Registers a handler called when the Land is initialized with resolvers.
///
/// - Parameters:
///   - resolvers: One or more resolver types to execute before the handler.
///   - onResolverFailure: What a throwing resolver does (`.failLand` by default).
///   - body: The synchronous closure to execute with resolved data available via `ctx`. It
///     can't throw (#593); with `.continue`, a check of the outputs that may refuse belongs in
///     `OnInitialize(resolvers:onResolverFailure:validate:apply:)`'s `validate`.
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    onResolverFailure: InitializeResolverFailure = .failLand,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(body),
        executors: [ResolverExecutor.createExecutor(for: resolvers)],
        onResolverFailure: onResolverFailure
    )
}

/// Registers a handler called when the Land is initialized with multiple resolvers.
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(body),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// Registers a handler called when the Land is initialized with multiple resolvers.
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(body),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1),
        ResolverExecutor.createExecutor(for: resolvers.2)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// Registers OnInitialize in two stages (#593): `validate` reads the state and may throw;
/// `apply` writes the plan `validate` returned and can't throw.
///
/// A `validate` throw fails the initialization, as an OnInitialize resolver that throws with
/// `.failLand` does: nothing is written, the land is torn down without its destroy handlers, and
/// a waiting join gets the retryable `JOIN_DENIED`.
///
/// Example:
/// ```swift
/// OnInitialize(
///     validate: { (state: RoomState, ctx: ValidateContext) throws -> Int in
///         guard state.maxPlayers == 0 else { throw RoomSetupError.alreadySetUp }
///         return 4
///     },
///     apply: { (state: inout RoomState, maxPlayers: Int, ctx: LandContext) in
///         state.maxPlayers = maxPlayers
///     })
/// ```
public func OnInitialize<State: StateNodeProtocol, Plan>(
    validate: @escaping @Sendable (State, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, Plan, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(InitializeHandler(validate: validate, apply: apply), executors: [], onResolverFailure: .failLand)
}

/// OnInitialize in two stages with nothing to pass from `validate` to `apply` (#593).
public func OnInitialize<State: StateNodeProtocol>(
    validate: @escaping @Sendable (State, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(InitializeHandler(validate: validate, apply: apply), executors: [], onResolverFailure: .failLand)
}

/// OnInitialize in two stages with a resolver (#593): `validate` reads its output from the
/// context. With `.continue`, `validate` runs without the group's outputs and may refuse.
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, Plan>(
    resolvers: R1.Type,
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, Plan, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [ResolverExecutor.createExecutor(for: resolvers)],
        onResolverFailure: onResolverFailure
    )
}

/// The two-stage form with a resolver and nothing to pass from `validate` to `apply` (#593).
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [ResolverExecutor.createExecutor(for: resolvers)],
        onResolverFailure: onResolverFailure
    )
}

/// OnInitialize in two stages with two resolvers (#593).
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, Plan>(
    resolvers: (R1.Type, R2.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, Plan, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// The two-stage form with two resolvers and nothing to pass from `validate` to `apply` (#593).
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// OnInitialize in two stages with three resolvers (#593).
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver, Plan>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, Plan, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1),
        ResolverExecutor.createExecutor(for: resolvers.2)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// The two-stage form with three resolvers and nothing to pass from `validate` to `apply` (#593).
public func OnInitialize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    onResolverFailure: InitializeResolverFailure = .failLand,
    validate: @escaping @Sendable (State, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    initializeDirective(
        InitializeHandler(validate: validate, apply: apply),
        executors: [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1),
        ResolverExecutor.createExecutor(for: resolvers.2)
    ],
        onResolverFailure: onResolverFailure
    )
}

/// Registers a handler called when the Land is finalizing (before shutdown).
///
/// This handler is executed before the Land is destroyed, while state is still mutable.
/// It can use resolvers to save final state or perform cleanup.
///
/// The body can't throw (#593): the land is ending, so nothing would act on a refusal, and a
/// body that calls throwing code handles its errors itself. A resolver that throws skips the
/// body; the land's teardown goes on.
///
/// - Parameter body: The synchronous closure to execute.
public func OnFinalize<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    return { config in
        warnIfHandlerAlreadyDefined("OnFinalize", isDefined: config.onFinalize != nil)
        config.onFinalize = body
    }
}

/// Registers a handler called when the Land is finalizing with resolvers.
///
/// - Parameters:
///   - resolvers: One or more resolver types to execute before the handler.
///   - body: The synchronous closure to execute with resolved data available via `ctx`.
public func OnFinalize<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    let executors = [ResolverExecutor.createExecutor(for: resolvers)]
    return { config in
        warnIfHandlerAlreadyDefined("OnFinalize", isDefined: config.onFinalize != nil)
        config.onFinalize = body
        config.onFinalizeResolverExecutors = executors
    }
}

/// Registers a handler called when the Land is finalizing with multiple resolvers.
public func OnFinalize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    let executors = [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1)
    ]
    return { config in
        warnIfHandlerAlreadyDefined("OnFinalize", isDefined: config.onFinalize != nil)
        config.onFinalize = body
        config.onFinalizeResolverExecutors = executors
    }
}

/// Registers a handler called when the Land is finalizing with multiple resolvers.
public func OnFinalize<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    let executors = [
        ResolverExecutor.createExecutor(for: resolvers.0),
        ResolverExecutor.createExecutor(for: resolvers.1),
        ResolverExecutor.createExecutor(for: resolvers.2)
    ]
    return { config in
        warnIfHandlerAlreadyDefined("OnFinalize", isDefined: config.onFinalize != nil)
        config.onFinalize = body
        config.onFinalizeResolverExecutors = executors
    }
}

/// Registers a handler called after the Land is completely finalized.
///
/// This handler is executed after OnFinalize, when state is no longer mutable.
/// Use this for async cleanup operations (e.g., closing database connections, sending metrics).
///
/// - Parameter body: The async closure to execute with state snapshot and context.
public func AfterFinalize<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (State, LandContext) async -> Void
) -> LifetimeDirective<State> {
    return { config in
        config.afterFinalize = body
    }
}

/// Registers a handler called when the Land is shutting down.
///
/// **Deprecated**: Use `OnFinalize` (sync, supports resolvers) and `AfterFinalize` (async) instead.
///
/// - Parameter body: The async closure to execute.
public func OnShutdown<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (State) async -> Void
) -> LifetimeDirective<State> {
    return { config in
        config.onShutdown = body
    }
}

// MARK: - Land DSL Builder

/// A land body's builder, generic over the land's `State` and `Services` (#771 §3.1). Each node
/// type has its own `buildExpression`, so the closures in a node get the land's types, and a
/// node for another State doesn't compile.
///
/// A helper that returns nodes for a land is written under the builder by name, and spliced into
/// a land or a `Rules` like a node:
///
/// ```swift
/// @LandDSL<GameState, NoServices>
/// func movementRules() -> [LandNode] {
///     HandleAction(Move.self) { state, action, ctx in ... }
/// }
/// ```
@resultBuilder
public enum LandDSL<State: StateNodeProtocol, Services: Sendable> {
    public static func buildExpression(_ node: AnyActionHandler<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: AnyClientEventHandler<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: AnyServerInputHandler<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: CanJoinNode<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: OnJoinNode<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: OnLeaveNode<State>) -> [LandNode] { [node] }
    public static func buildExpression(_ node: LifetimeNode<State>) -> [LandNode] { [node] }
    /// Flattened here: a `Rules` block's nodes become the enclosing block's.
    public static func buildExpression(_ node: RulesNode<State, Services>) -> [LandNode] { node.nodes }
    public static func buildExpression(_ node: AccessControlNode) -> [LandNode] { [node] }
    public static func buildExpression(_ node: AllowedClientEventsNode) -> [LandNode] { [node] }
    public static func buildExpression(_ node: ClientEventsNode) -> [LandNode] { [node] }
    public static func buildExpression(_ node: ServerEventsNode) -> [LandNode] { [node] }
    public static func buildExpression(_ node: ServerEventNode) -> [LandNode] { [node] }
    /// Nodes built elsewhere: a helper under `@LandDSL<State, Services>`, or the `@Land` macro's
    /// `body` (#771 D-Q5). Each node in it was checked by the builder that made it.
    public static func buildExpression(_ nodes: [LandNode]) -> [LandNode] { nodes }

    public static func buildBlock(_ components: [LandNode]...) -> [LandNode] {
        components.flatMap { $0 }
    }

    public static func buildArray(_ components: [[LandNode]]) -> [LandNode] {
        components.flatMap { $0 }
    }

    public static func buildOptional(_ component: [LandNode]?) -> [LandNode] {
        component ?? []
    }

    public static func buildEither(first component: [LandNode]) -> [LandNode] {
        component
    }

    public static func buildEither(second component: [LandNode]) -> [LandNode] {
        component
    }
}

// MARK: - DSL Helpers

// Action and event handlers can't throw after they write (#586). The single-closure forms take
// a non-throwing body. An input that can be refused declares `validate:` and `apply:`:
// `validate` reads the state (a constant), may throw, and returns a plan; `apply` writes it and
// can't throw. They run in the same turn, back to back, so the check can't go stale before the
// write. A `validate` throw fails the input alone with nothing written: an action's caller gets
// the error (`ACTION_HANDLER_ERROR`; a tick land's caller had its ACK at intake).

/// The type-erased action handler both forms build: `invoke` throws only from the payload type
/// check or `validate`, before anything is written.
private func makeActionHandler<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    site: String,
    executors: [any AnyResolverExecutor],
    invoke: @escaping @Sendable (inout State, A, LandContext) throws -> A.Response
) -> AnyActionHandler<State> {
    // The associated type, which every conformance has: `getResponseType()`'s default ends the
    // process for a type without `@Payload` (#521).
    AnyActionHandler(
        type: type,
        responseType: A.Response.self,
        site: site,
        invoke: { state, anyAction, ctx in
            guard let action = anyAction as? A else {
                throw LandError.invalidActionType
            }
            return AnyCodable(try invoke(&state, action, ctx))
        },
        resolverExecutors: executors
    )
}

/// Registers an action handler that can't fail.
///
/// - Parameters:
///   - type: The Action type to handle.
///   - body: The handler closure. It receives the state, the action, and the context, and
///           returns the action's declared response (`A.Response`). It can't throw (#586): an
///           action that can be refused uses `HandleAction(_:validate:apply:)`.
/// - Returns: A type-erased `AnyActionHandler`.
///
/// One handler per action type: a second `HandleAction` for the same type, in any form, is
/// refused at registration (`LandRegistrationError.duplicateHandlers`).
public func HandleAction<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [], invoke: body)
}

/// Registers an action handler with resolvers for a specific Action type.
///
/// This version allows declaring resolvers that will be executed in parallel before
/// the action handler runs. Resolver outputs are available synchronously in the handler
/// via `ctx.resolverOutputName`.
///
/// Example:
/// ```swift
/// HandleAction(UpdateCart.self, resolvers: ProductInfoResolver.self) { state, action, ctx in
///     let productInfo = ctx.productInfo  // Available synchronously
///     // Use resolver outputs...
/// }
/// ```
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: R1.Type,
    _ body: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [ResolverExecutor.createExecutor(for: resolvers)], invoke: body)
}

/// Registers an action handler with multiple resolvers.
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver, R2: ContextResolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: (R1.Type, R2.Type),
    _ body: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(
        type,
        site: "\(fileID):\(line)",
        executors: [ResolverExecutor.createExecutor(for: resolvers.0), ResolverExecutor.createExecutor(for: resolvers.1)],
        invoke: body
    )
}

/// Registers an action handler in two stages (#586).
///
/// Example:
/// ```swift
/// HandleAction(BuyAction.self,
///     validate: { (state: ShopState, action: BuyAction, ctx: ValidateContext) throws -> BuyPlan in
///         guard let item = state.shop[action.itemID] else { throw ShopError.notFound }
///         guard (state.players[ctx.playerID]?.gold ?? 0) >= item.price else { throw ShopError.noGold }
///         return BuyPlan(item: item)
///     },
///     apply: { (state: inout ShopState, action: BuyAction, plan: BuyPlan, ctx: LandContext) -> BuyResponse in
///         state.players[ctx.playerID]?.gold -= plan.item.price
///         state.players[ctx.playerID]?.items.append(plan.item)
///         return BuyResponse(ok: true)
///     })
/// ```
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, Plan>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, A, Plan, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [], invoke: twoStage(validate, apply))
}

/// The two-stage form with nothing to pass from `validate` to `apply` (#586).
public func HandleAction<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [], invoke: twoStage(validate, apply))
}

/// The two-stage form with a resolver (#586): `validate` reads its output from the context.
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver, Plan>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: R1.Type,
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, A, Plan, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [ResolverExecutor.createExecutor(for: resolvers)], invoke: twoStage(validate, apply))
}

/// The two-stage form with a resolver and nothing to pass from `validate` to `apply` (#586).
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: R1.Type,
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(type, site: "\(fileID):\(line)", executors: [ResolverExecutor.createExecutor(for: resolvers)], invoke: twoStage(validate, apply))
}

/// The two-stage form with two resolvers (#586).
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver, R2: ContextResolver, Plan>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: (R1.Type, R2.Type),
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, A, Plan, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(
        type,
        site: "\(fileID):\(line)",
        executors: [ResolverExecutor.createExecutor(for: resolvers.0), ResolverExecutor.createExecutor(for: resolvers.1)],
        invoke: twoStage(validate, apply)
    )
}

/// The two-stage form with two resolvers and nothing to pass from `validate` to `apply` (#586).
public func HandleAction<State: StateNodeProtocol, A: ActionPayload, R1: ContextResolver, R2: ContextResolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: (R1.Type, R2.Type),
    validate: @escaping @Sendable (State, A, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, A, LandContext) -> A.Response
) -> AnyActionHandler<State> {
    makeActionHandler(
        type,
        site: "\(fileID):\(line)",
        executors: [ResolverExecutor.createExecutor(for: resolvers.0), ResolverExecutor.createExecutor(for: resolvers.1)],
        invoke: twoStage(validate, apply)
    )
}

/// `validate` then `apply`, as one call that throws only from `validate`.
private func twoStage<State, Input, Plan, Output>(
    _ validate: @escaping @Sendable (State, Input, ValidateContext) throws -> Plan,
    _ apply: @escaping @Sendable (inout State, Input, Plan, LandContext) -> Output
) -> @Sendable (inout State, Input, LandContext) throws -> Output {
    { state, input, ctx in
        let plan = try validate(state, input, ValidateContext(ctx))
        return apply(&state, input, plan, ctx)
    }
}

/// `validate` then `apply`, with no plan.
private func twoStage<State, Input, Output>(
    _ validate: @escaping @Sendable (State, Input, ValidateContext) throws -> Void,
    _ apply: @escaping @Sendable (inout State, Input, LandContext) -> Output
) -> @Sendable (inout State, Input, LandContext) throws -> Output {
    { state, input, ctx in
        try validate(state, input, ValidateContext(ctx))
        return apply(&state, input, ctx)
    }
}

/// Registers an event handler that can't fail, for a specific event payload type.
///
/// - Parameters:
///   - type: The Client Event type to handle.
///   - body: The handler closure. It can't throw (#586): an event that can be refused uses
///           `HandleEvent(_:validate:apply:)`.
/// - Returns: A type-erased `AnyClientEventHandler`.
///
/// Client events are fire-and-forget and take no resolvers; load data an event needs in an
/// action instead. One handler per event type: a second `HandleEvent` for the same type is
/// refused at registration (`LandRegistrationError.duplicateHandlers`).
public func HandleEvent<State: StateNodeProtocol, E: ClientEventPayload>(
    _ type: E.Type,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, E, LandContext) -> Void
) -> AnyClientEventHandler<State> {
    AnyClientEventHandler(eventType: type, site: "\(fileID):\(line)", invoke: body)
}

/// Registers an event handler in two stages (#586). A `validate` throw fails the event alone with
/// nothing written. On a tickless land the error goes back to the client as an error payload; on
/// a tick land it is only logged.
public func HandleEvent<State: StateNodeProtocol, E: ClientEventPayload, Plan>(
    _ type: E.Type,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, E, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, E, Plan, LandContext) -> Void
) -> AnyClientEventHandler<State> {
    AnyClientEventHandler(eventType: type, site: "\(fileID):\(line)", invoke: twoStage(validate, apply))
}

/// The two-stage form with nothing to pass from `validate` to `apply` (#586).
public func HandleEvent<State: StateNodeProtocol, E: ClientEventPayload>(
    _ type: E.Type,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, E, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, E, LandContext) -> Void
) -> AnyClientEventHandler<State> {
    AnyClientEventHandler(eventType: type, site: "\(fileID):\(line)", invoke: twoStage(validate, apply))
}

// MARK: - Server Event Registration

/// Land node that represents a registered server event payload type.
/// @deprecated: Use ServerEvents { Register(...) } instead.
public struct ServerEventNode: LandNode {
    public let type: Any.Type
    
    public init(type: Any.Type) {
        self.type = type
    }
}

/// Register a server event payload type for schema/code generation.
/// @deprecated: Use ServerEvents { Register(...) } instead.
///
/// Example:
/// ```swift
/// ServerEvent(DemoServerEvent.self)
/// ```
public func ServerEvent<E: ServerEventPayload>(
    _ type: E.Type
) -> ServerEventNode {
    ServerEventNode(type: type)  // Single-expression: omit return
}

// MARK: - Server Events Registration DSL

/// Land node that represents a registered server event type.
public struct ServerEventRegistrationNode: LandNode {
    public let type: Any.Type
    
    public init<E: ServerEventPayload>(type: E.Type) {
        self.type = type
    }
}

/// Register a server event payload type.
///
/// Example:
/// ```swift
/// ServerEvents {
///     Register(WelcomeEvent.self)
///     Register(ChatMessageEvent.self)
/// }
/// ```
public func Register<E: ServerEventPayload>(
    _ type: E.Type
) -> ServerEventRegistrationNode {
    ServerEventRegistrationNode(type: type)  // Single-expression: omit return
}

/// Register a client event payload type.
///
/// Example:
/// ```swift
/// ClientEvents {
///     Register(ChatEvent.self)
///     Register(PingEvent.self)
/// }
/// ```
public func Register<E: ClientEventPayload>(
    _ type: E.Type
) -> ClientEventRegistrationNode {
    ClientEventRegistrationNode(type: type)  // Single-expression: omit return
}

/// Land node that contains multiple server event registrations.
public struct ServerEventsNode: LandNode {
    public let registrations: [ServerEventRegistrationNode]
    
    public init(registrations: [ServerEventRegistrationNode]) {
        self.registrations = registrations
    }
}

@resultBuilder
public enum ServerEventsBuilder {
    public static func buildBlock(_ components: ServerEventRegistrationNode...) -> [ServerEventRegistrationNode] {
        components
    }
}

/// Register multiple server event types for schema generation and runtime validation.
///
/// Example:
/// ```swift
/// ServerEvents {
///     Register(WelcomeEvent.self)
///     Register(ChatMessageEvent.self)
///     Register(PongEvent.self)
/// }
/// ```
public func ServerEvents(
    @ServerEventsBuilder _ content: () -> [ServerEventRegistrationNode]
) -> ServerEventsNode {
    ServerEventsNode(registrations: content())  // Single-expression: omit return
}

// MARK: - Client Events Registration DSL

/// Land node that represents a registered client event type.
public struct ClientEventRegistrationNode: LandNode {
    public let type: Any.Type
    
    public init<E: ClientEventPayload>(type: E.Type) {
        self.type = type
    }
}

/// Land node that contains multiple client event registrations.
public struct ClientEventsNode: LandNode {
    public let registrations: [ClientEventRegistrationNode]
    
    public init(registrations: [ClientEventRegistrationNode]) {
        self.registrations = registrations
    }
}

@resultBuilder
public enum ClientEventsBuilder {
    public static func buildBlock(_ components: ClientEventRegistrationNode...) -> [ClientEventRegistrationNode] {
        components
    }
}

/// Register multiple client event types for schema generation and runtime validation.
///
/// Example:
/// ```swift
/// ClientEvents {
///     Register(ChatEvent.self)
///     Register(PingEvent.self)
/// }
/// ```
public func ClientEvents(
    @ClientEventsBuilder _ content: () -> [ClientEventRegistrationNode]
) -> ClientEventsNode {
    ClientEventsNode(registrations: content())  // Single-expression: omit return
}

// MARK: - Land Entry Point

/// The main entry point for defining a Land.
///
/// This function creates a `LandDefinition` by collecting all the configuration nodes
/// defined in the DSL block.
///
/// - Parameters:
///   - id: The unique identifier for this Land.
///   - stateType: The type of the root state node.
///   - content: The DSL block containing `AccessControl`, `Rules`, `Lifetime`, `ClientEvents`, `ServerEvents`, etc.
/// - Returns: A complete `LandDefinition`.
///
/// Client and server events are now registered via the `ClientEvents { Register(...) }` and
/// `ServerEvents { Register(...) }` DSL blocks instead of being passed as generic parameters.
public func Land<State: StateNodeProtocol>(
    _ id: String,
    using stateType: State.Type,
    @LandDSL<State, NoServices> _ content: () -> [LandNode]
) -> LandDefinition<State> {
    LandBuilder.build(
        id: id,
        stateType: stateType,
        nodes: content()
    )  // Single-expression: omit return
}

/// A land that declares the services its handlers use (#769 §3.4, #771 §3.1). Its body's builder
/// is `LandDSL<State, Services>`, and `definition` records the services type.
///
/// Until #769 R1 nothing reads the services type: register `definition` as any other land's.
public struct TypedLand<State: StateNodeProtocol, Services: Sendable>: Sendable {
    public let definition: LandDefinition<State>
}

/// Defines a land that declares its services type.
///
/// - Parameters:
///   - id: The unique identifier for this Land.
///   - stateType: The type of the root state node.
///   - services: The type of the services value the land's handlers use.
///   - content: The DSL block, under `LandDSL<State, Services>`.
/// - Returns: The land, typed by its State and Services.
public func Land<State: StateNodeProtocol, Services: Sendable>(
    _ id: String,
    using stateType: State.Type,
    services: Services.Type,
    @LandDSL<State, Services> _ content: () -> [LandNode]
) -> TypedLand<State, Services> {
    TypedLand(definition: LandBuilder.build(
        id: id,
        stateType: stateType,
        nodes: content(),
        servicesType: services
    ))
}
