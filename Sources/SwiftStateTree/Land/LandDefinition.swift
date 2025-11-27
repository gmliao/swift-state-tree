import Foundation

// MARK: - Land Definition

/// Type-erased definition built by the Land DSL.
///
/// It captures all the configuration, handlers, and metadata that the runtime (`LandKeeper`)
/// needs in order to operate a single land instance.
public struct LandDefinition<
    State: StateNodeProtocol,
    ClientE: ClientEventPayload,
    ServerE: ServerEventPayload
>: Sendable {
    public let id: String
    public let stateType: State.Type
    public let clientEventType: ClientE.Type
    public let serverEventType: ServerE.Type
    public let config: LandConfig
    public let actionHandlers: [AnyActionHandler<State>]
    public let eventHandlers: [AnyClientEventHandler<State, ClientE>]
    public let lifetimeHandlers: LifetimeHandlers<State>
}

// MARK: - Lifetime Handlers

/// Collection of lifecycle handlers extracted from the DSL.
public struct LifetimeHandlers<State: StateNodeProtocol>: Sendable {
    public var onJoin: (@Sendable (inout State, LandContext) async -> Void)?
    public var onLeave: (@Sendable (inout State, LandContext) async -> Void)?
    public var tickInterval: Duration?
    public var tickHandler: (@Sendable (inout State, LandContext) async -> Void)?
    public var destroyWhenEmptyAfter: Duration?
    public var persistInterval: Duration?
    public var onShutdown: (@Sendable (State) async -> Void)?

    public init(
        onJoin: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        onLeave: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        tickInterval: Duration? = nil,
        tickHandler: (@Sendable (inout State, LandContext) async -> Void)? = nil,
        destroyWhenEmptyAfter: Duration? = nil,
        persistInterval: Duration? = nil,
        onShutdown: (@Sendable (State) async -> Void)? = nil
    ) {
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
public struct AnyClientEventHandler<State: StateNodeProtocol, ClientE: ClientEventPayload>: LandNode {
    private let handler: @Sendable (inout State, ClientE, LandContext) async -> Void

    public init(
        handler: @escaping @Sendable (inout State, ClientE, LandContext) async -> Void
    ) {
        self.handler = handler
    }

    public func invoke(
        _ state: inout State,
        event: ClientE,
        ctx: LandContext
    ) async {
        await handler(&state, event, ctx)
    }
}
