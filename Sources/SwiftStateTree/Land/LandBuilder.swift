import Foundation

/// Internal builder that processes the DSL nodes and constructs a `LandDefinition`.
enum LandBuilder {
    /// Builds a `LandDefinition` from a list of `LandNode`s.
    ///
    /// This function iterates through the provided nodes, flattening nested structures (like `RulesNode`),
    /// and aggregating configuration into the final definition.
    static func build<
        State: StateNodeProtocol,
        ClientE: ClientEventPayload,
        ServerE: ServerEventPayload
    >(
        id: String,
        stateType: State.Type,
        clientEvents: ClientE.Type,
        serverEvents: ServerE.Type,
        nodes: [LandNode]
    ) -> LandDefinition<State, ClientE, ServerE> {
        var accessControl = AccessControlConfig()
        var allowedClientEvents: Set<AllowedEventIdentifier> = []
        var lifetimeConfig = LifetimeConfig<State>()
        var hasLifetimeConfig = false

        var canJoin: (@Sendable (State, PlayerSession, LandContext) async throws -> JoinDecision)?
        var onJoin: (@Sendable (inout State, LandContext) async -> Void)?
        var onLeave: (@Sendable (inout State, LandContext) async -> Void)?
        var actionHandlers: [AnyActionHandler<State>] = []
        var eventHandlers: [AnyClientEventHandler<State, ClientE>] = []

        func ingest(nodes: [LandNode]) {
            for node in nodes {
                switch node {
                case let access as AccessControlNode:
                    accessControl = access.config
                case let allowed as AllowedClientEventsNode:
                    allowedClientEvents.formUnion(allowed.allowed)
                case let rules as RulesNode:
                    ingest(nodes: rules.nodes)
                case let canJoinNode as CanJoinNode<State>:
                    canJoin = canJoinNode.handler
                case let join as OnJoinNode<State>:
                    onJoin = join.handler
                case let leave as OnLeaveNode<State>:
                    onLeave = leave.handler
                case let action as AnyActionHandler<State>:
                    actionHandlers.append(action)
                case let handler as AnyClientEventHandler<State, ClientE>:
                    eventHandlers.append(handler)
                case let lifetime as LifetimeNode<State>:
                    var cfg = lifetimeConfig
                    lifetime.configure(&cfg)
                    lifetimeConfig = cfg
                    hasLifetimeConfig = true
                default:
                    continue
                }
            }
        }

        ingest(nodes: nodes)

        let landConfig = LandConfig(
            allowPublic: accessControl.allowPublic,
            maxPlayers: accessControl.maxPlayers,
            allowedClientEvents: allowedClientEvents,
            tickInterval: hasLifetimeConfig ? lifetimeConfig.tickInterval : nil,
            destroyWhenEmptyAfter: hasLifetimeConfig ? lifetimeConfig.destroyWhenEmptyAfter : nil,
            persistInterval: hasLifetimeConfig ? lifetimeConfig.persistInterval : nil
        )

        let lifetimeHandlers = LifetimeHandlers<State>(
            canJoin: canJoin,
            onJoin: onJoin,
            onLeave: onLeave,
            tickInterval: lifetimeConfig.tickInterval,
            tickHandler: lifetimeConfig.tickHandler,
            destroyWhenEmptyAfter: lifetimeConfig.destroyWhenEmptyAfter,
            persistInterval: lifetimeConfig.persistInterval,
            onShutdown: lifetimeConfig.onShutdown
        )

        return LandDefinition(
            id: id,
            stateType: stateType,
            clientEventType: clientEvents,
            serverEventType: serverEvents,
            config: landConfig,
            actionHandlers: actionHandlers,
            eventHandlers: eventHandlers,
            lifetimeHandlers: lifetimeHandlers
        )
    }
}

