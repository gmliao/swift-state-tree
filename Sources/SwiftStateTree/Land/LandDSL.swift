import Foundation

// MARK: - Land Node Protocol

/// A marker protocol for all components within the Land DSL.
///
/// Any element that can be used inside a `@LandDSL` block (or its sub-blocks) must conform to this protocol.
/// The `LandBuilder` uses this to recursively traverse and collect configuration.
public protocol LandNode: Sendable {}

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
    return AccessControlNode(config: config)
}

/// Defines the access control policy for the Land using a result builder.
///
/// This overload allows using the declarative syntax with `AccessControlBuilder`.
public func AccessControl(
    @AccessControlBuilder _ content: () -> [AccessControlDirective]
) -> AccessControlNode {
    var config = AccessControlConfig()
    content().forEach { $0(&config) }
    return AccessControlNode(config: config)
}

/// Sets whether the Land is publicly visible and joinable.
///
/// - Parameter allow: `true` to allow public access, `false` for private. Default is `true`.
public func AllowPublic(_ allow: Bool = true) -> AccessControlDirective {
    { $0.allowPublic = allow }
}

/// Sets the maximum number of players allowed in the Land.
///
/// - Parameter value: The maximum player count.
public func MaxPlayers(_ value: Int) -> AccessControlDirective {
    { $0.maxPlayers = value }
}

// MARK: - Rules

public struct RulesNode: LandNode {
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
public func Rules(@LandDSL _ content: () -> [LandNode]) -> RulesNode {
    RulesNode(nodes: content())
}

public struct OnJoinNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) async -> Void
}

/// Registers a handler called when a player joins the Land.
///
/// This handler is executed after the player is added to the state.
///
/// - Parameter body: The async closure to execute.
public func OnJoin<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> OnJoinNode<State> {
    OnJoinNode(handler: body)
}

public struct OnLeaveNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) async -> Void
}

/// Registers a handler called when a player leaves the Land.
///
/// This handler is executed just before the player is removed from the state.
///
/// - Parameter body: The async closure to execute.
public func OnLeave<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(handler: body)
}

public struct CanJoinNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (State, PlayerSession, LandContext) async throws -> JoinDecision
}

/// Registers a handler called before a player joins to validate the join request.
///
/// This handler is executed BEFORE the player is added to the authoritative state.
/// It receives a read-only view of the state and can perform async validation
/// (e.g., querying databases, checking player levels, etc.).
///
/// If the handler throws an error or returns `.deny`, the join is rejected.
/// If it returns `.allow(playerID)`, the player is added to the Land with that PlayerID.
///
/// Example:
/// ```swift
/// CanJoin { state, session, ctx async throws in
///     // Check room capacity
///     guard state.players.count < 8 else {
///         throw JoinError.roomIsFull
///     }
///
///     // Query player data
///     let profile = try await ctx.services.userService?.getUser(by: session.playerID)
///     guard let profile else {
///         throw JoinError.custom("User not found")
///     }
///
///     // Validate player level
///     guard profile.level >= 5 else {
///         throw JoinError.levelTooLow(required: 5)
///     }
///
///     return .allow(playerID: PlayerID(profile.id))
/// }
/// ```
///
/// - Parameter body: The async closure that validates the join request.
public func CanJoin<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (State, PlayerSession, LandContext) async throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(handler: body)
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
    AllowedClientEventsNode(allowed: Set(content()))
}

// MARK: - Lifetime

public struct LifetimeNode<State: StateNodeProtocol>: LandNode {
    public let configure: @Sendable (inout LifetimeConfig<State>) -> Void
}

public struct LifetimeConfig<State: StateNodeProtocol>: Sendable {
    public var tickInterval: Duration?
    public var destroyWhenEmptyAfter: Duration?
    public var persistInterval: Duration?
    /// Handler called periodically based on `tickInterval`.
    ///
    /// **Design Note**: This handler is synchronous to maintain stable tick rates.
    /// For async operations (e.g., flushing metrics), use `ctx.spawn { await ... }`.
    public var tickHandler: (@Sendable (inout State, LandContext) -> Void)?
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        tickInterval: Duration? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) -> Void)? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
        self.tickInterval = tickInterval
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
        self.tickHandler = tickHandler
        self.onShutdown = onShutdown
    }
}

public typealias LifetimeDirective<State: StateNodeProtocol> =
    @Sendable (inout LifetimeConfig<State>) -> Void

@resultBuilder
public enum LifetimeBuilder<State: StateNodeProtocol> {
    public static func buildBlock(_ components: LifetimeDirective<State>...) -> [LifetimeDirective<
        State
    >] {
        components
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
    LifetimeNode(configure: configure)
}

/// Defines the lifetime and periodic behaviors of the Land using a result builder.
public func Lifetime<State: StateNodeProtocol>(
    @LifetimeBuilder<State> _ directives: @escaping @Sendable () -> [LifetimeDirective<State>]
) -> LifetimeNode<State> {
    LifetimeNode { config in
        directives().forEach { $0(&config) }
    }
}

/// Configures a periodic tick handler.
///
/// **Design Note**: The tick handler is synchronous to ensure stable and predictable
/// tick rates. If you need to perform async operations (e.g., flushing metrics to a
/// remote service), use `ctx.spawn` to execute them in the background without blocking
/// the tick loop.
///
/// Example:
/// ```swift
/// Tick(every: .milliseconds(50)) { state, ctx in
///     state.stepSimulation()  // Synchronous game logic
///
///     ctx.spawn {
///         await ctx.flushMetricsIfNeeded()  // Async I/O in background
///     }
/// }
/// ```
///
/// - Parameters:
///   - interval: The duration between ticks.
///   - body: The synchronous handler to execute on each tick.
public func Tick<State: StateNodeProtocol>(
    every interval: Duration,
    _ body: @escaping @Sendable (inout State, LandContext) -> Void
) -> LifetimeDirective<State> {
    { config in
        config.tickInterval = interval
        config.tickHandler = body
    }
}

/// Configures the Land to automatically destroy itself when empty.
///
/// - Parameter duration: The duration to wait after the last player leaves before destroying.
public func DestroyWhenEmpty<State: StateNodeProtocol>(
    after duration: Duration
) -> LifetimeDirective<State> {
    { config in
        config.destroyWhenEmptyAfter = duration
    }
}

/// Configures the interval for persisting state snapshots.
///
/// - Parameter interval: The duration between snapshots.
public func PersistSnapshot<State: StateNodeProtocol>(
    every interval: Duration
) -> LifetimeDirective<State> {
    { config in
        config.persistInterval = interval
    }
}

/// Registers a handler called when the Land is shutting down.
///
/// - Parameter body: The async closure to execute.
public func OnShutdown<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (State) async -> Void
) -> LifetimeDirective<State> {
    { config in
        config.onShutdown = body
    }
}

// MARK: - Land DSL Builder

@resultBuilder
public enum LandDSL {
    public static func buildBlock(_ components: LandNode...) -> [LandNode] {
        components
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

/// Registers an action handler for a specific Action type.
///
/// - Parameters:
///   - type: The Action type to handle.
///   - body: The handler closure. It receives the state, the action, and the context.
///           It must return a `Codable & Sendable` response.
/// - Returns: A type-erased `AnyActionHandler`.
public func HandleAction<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    _ body:
        @escaping @Sendable (inout State, A, LandContext) async throws -> some Codable & Sendable
) -> AnyActionHandler<State> {
    // Extract Response type from ActionPayload using macro-generated method
    // The @Payload macro generates getResponseType() for ActionPayload types
    let responseType = A.getResponseType()
    
    return AnyActionHandler(
        type: type,
        responseType: responseType,
        handler: { state, anyAction, ctx in
            guard let action = anyAction as? A else {
                throw LandError.invalidActionType
            }
            let result = try await body(&state, action, ctx)
            return AnyCodable(result)
        }
    )
}

/// Registers an event handler for a specific event payload type.
///
/// This is the base function for event handling. Typically, you might use generated helpers
/// like `OnReady` or `OnChat` which wrap this function.
///
/// - Parameters:
///   - type: The Client Event type to handle.
///   - body: The handler closure.
/// - Returns: A type-erased `AnyClientEventHandler`.
public func HandleEvent<State: StateNodeProtocol, E: ClientEventPayload>(
    _ type: E.Type,
    _ body: @escaping @Sendable (inout State, E, LandContext) async -> Void
) -> AnyClientEventHandler<State> {
    AnyClientEventHandler(eventType: type, handler: body)
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
    ServerEventNode(type: type)
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
    ServerEventRegistrationNode(type: type)
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
    ClientEventRegistrationNode(type: type)
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
    ServerEventsNode(registrations: content())
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
    ClientEventsNode(registrations: content())
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
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State> {
    LandBuilder.build(
        id: id,
        stateType: stateType,
        nodes: content()
    )
}
