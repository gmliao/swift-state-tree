import Foundation

// MARK: - Land Node Protocol

public protocol LandNode: Sendable {}

// MARK: - Access Control

public struct AccessControlNode: LandNode {
    public let config: AccessControlConfig
}

public typealias AccessControlDirective = (inout AccessControlConfig) -> Void

@resultBuilder
public enum AccessControlBuilder {
    public static func buildBlock(_ components: AccessControlDirective...) -> [AccessControlDirective] {
        components
    }
}

public func AccessControl(
    _ configure: (inout AccessControlConfig) -> Void
) -> AccessControlNode {
    var config = AccessControlConfig()
    configure(&config)
    return AccessControlNode(config: config)
}

public func AccessControl(
    @AccessControlBuilder _ content: () -> [AccessControlDirective]
) -> AccessControlNode {
    var config = AccessControlConfig()
    content().forEach { $0(&config) }
    return AccessControlNode(config: config)
}

public func AllowPublic(_ allow: Bool = true) -> AccessControlDirective {
    { $0.allowPublic = allow }
}

public func MaxPlayers(_ value: Int) -> AccessControlDirective {
    { $0.maxPlayers = value }
}

// MARK: - Rules

public struct RulesNode: LandNode {
    public let nodes: [LandNode]
}

public func Rules(@LandDSL _ content: () -> [LandNode]) -> RulesNode {
    RulesNode(nodes: content())
}

public struct OnJoinNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) async -> Void
}

public func OnJoin<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> OnJoinNode<State> {
    OnJoinNode(handler: body)
}

public struct OnLeaveNode<State: StateNodeProtocol>: LandNode {
    public let handler: @Sendable (inout State, LandContext) async -> Void
}

public func OnLeave<State: StateNodeProtocol>(
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(handler: body)
}

public struct AllowedClientEventsNode: LandNode {
    public let allowed: Set<AllowedEventIdentifier>
}

@resultBuilder
public enum AllowedClientEventsBuilder {
    public static func buildBlock(_ components: AllowedEventIdentifier...) -> [AllowedEventIdentifier] {
        components
    }

    public static func buildExpression<E: Hashable & Sendable>(_ expression: E) -> AllowedEventIdentifier {
        AllowedEventIdentifier(expression)
    }
}

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
    public var tickHandler: (@Sendable (inout State, LandContext) async -> Void)?
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        tickInterval: Duration? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
        self.tickInterval = tickInterval
        self.destroyWhenEmptyAfter = destroyWhenEmptyAfter
        self.persistInterval = persistInterval
        self.tickHandler = tickHandler
        self.onShutdown = onShutdown
    }
}

public typealias LifetimeDirective<State: StateNodeProtocol> = @Sendable (inout LifetimeConfig<State>) -> Void

@resultBuilder
public enum LifetimeBuilder<State: StateNodeProtocol> {
    public static func buildBlock(_ components: LifetimeDirective<State>...) -> [LifetimeDirective<State>] {
        components
    }
}

public func Lifetime<State: StateNodeProtocol>(
    _ configure: @escaping @Sendable (inout LifetimeConfig<State>) -> Void
) -> LifetimeNode<State> {
    LifetimeNode(configure: configure)
}

public func Lifetime<State: StateNodeProtocol>(
    @LifetimeBuilder<State> _ directives: @escaping @Sendable () -> [LifetimeDirective<State>]
) -> LifetimeNode<State> {
    LifetimeNode { config in
        directives().forEach { $0(&config) }
    }
}

public func Tick<State: StateNodeProtocol>(
    every interval: Duration,
    _ body: @escaping @Sendable (inout State, LandContext) async -> Void
) -> LifetimeDirective<State> {
    { config in
        config.tickInterval = interval
        config.tickHandler = body
    }
}

public func DestroyWhenEmpty<State: StateNodeProtocol>(
    after duration: Duration
) -> LifetimeDirective<State> {
    { config in
        config.destroyWhenEmptyAfter = duration
    }
}

public func PersistSnapshot<State: StateNodeProtocol>(
    every interval: Duration
) -> LifetimeDirective<State> {
    { config in
        config.persistInterval = interval
    }
}

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

public func Action<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    _ body: @escaping @Sendable (inout State, A, LandContext) async throws -> some Codable & Sendable
) -> AnyActionHandler<State> {
    AnyActionHandler(
        type: type,
        handler: { state, anyAction, ctx in
            guard let action = anyAction as? A else {
                throw LandError.invalidActionType
            }
            let result = try await body(&state, action, ctx)
            return AnyCodable(result)
        }
    )
}

public func On<State: StateNodeProtocol, Event: ClientEventPayload>(
    _ type: Event.Type,
    _ body: @escaping @Sendable (inout State, Event, LandContext) async -> Void
) -> AnyClientEventHandler<State, Event> {
    AnyClientEventHandler(handler: body)
}

// MARK: - Land Entry Point

public func Land<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>(
    _ id: String,
    using stateType: State.Type,
    clientEvents: ClientE.Type,
    serverEvents: ServerE.Type,
    @LandDSL _ content: () -> [LandNode]
) -> LandDefinition<State, ClientE, ServerE> {
    LandBuilder.build(
        id: id,
        stateType: stateType,
        clientEvents: clientEvents,
        serverEvents: serverEvents,
        nodes: content()
    )
}
