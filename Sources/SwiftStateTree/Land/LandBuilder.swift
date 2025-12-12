import Foundation

/// Internal builder that processes the DSL nodes and constructs a `LandDefinition`.
enum LandBuilder {
    /// Builds a `LandDefinition` from a list of `LandNode`s.
    ///
    /// This function iterates through the provided nodes, flattening nested structures (like `RulesNode`),
    /// and aggregating configuration into the final definition.
    static func build<State: StateNodeProtocol>(
        id: String,
        stateType: State.Type,
        nodes: [LandNode]
    ) -> LandDefinition<State> {
        var accessControl = AccessControlConfig()
        var allowedClientEvents: Set<AllowedEventIdentifier> = []
        var lifetimeConfig = LifetimeConfig<State>()
        var hasLifetimeConfig = false

        var canJoin: (@Sendable (State, PlayerSession, LandContext) throws -> JoinDecision)?
        var canJoinResolverExecutors: [any AnyResolverExecutor] = []
        var onJoin: (@Sendable (inout State, LandContext) throws -> Void)?
        var onJoinResolverExecutors: [any AnyResolverExecutor] = []
        var onLeave: (@Sendable (inout State, LandContext) throws -> Void)?
        var onLeaveResolverExecutors: [any AnyResolverExecutor] = []
        var actionHandlers: [AnyActionHandler<State>] = []
        var eventHandlers: [AnyClientEventHandler<State>] = []
        var clientEventRegistrations: [Any.Type] = []
        var serverEventRegistrations: [Any.Type] = []

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
                    canJoinResolverExecutors = canJoinNode.resolverExecutors
                case let join as OnJoinNode<State>:
                    onJoin = join.handler
                    onJoinResolverExecutors = join.resolverExecutors
                case let leave as OnLeaveNode<State>:
                    onLeave = leave.handler
                    onLeaveResolverExecutors = leave.resolverExecutors
                case let action as AnyActionHandler<State>:
                    actionHandlers.append(action)
                case let handler as AnyClientEventHandler<State>:
                    eventHandlers.append(handler)
                case let lifetime as LifetimeNode<State>:
                    var cfg = lifetimeConfig
                    lifetime.configure(&cfg)
                    lifetimeConfig = cfg
                    hasLifetimeConfig = true
                case let clientEvents as ClientEventsNode:
                    // Collect all registrations from ClientEvents block
                    for registration in clientEvents.registrations {
                        clientEventRegistrations.append(registration.type)
                    }
                case let serverEvents as ServerEventsNode:
                    // Collect all registrations from ServerEvents block
                    for registration in serverEvents.registrations {
                        serverEventRegistrations.append(registration.type)
                    }
                case let serverEvent as ServerEventNode:
                    // Legacy ServerEvent(_:) support - collect for backward compatibility
                    serverEventRegistrations.append(serverEvent.type)
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
            canJoinResolverExecutors: canJoinResolverExecutors,
            onJoin: onJoin,
            onJoinResolverExecutors: onJoinResolverExecutors,
            onLeave: onLeave,
            onLeaveResolverExecutors: onLeaveResolverExecutors,
            tickInterval: lifetimeConfig.tickInterval,
            tickHandler: lifetimeConfig.tickHandler,
            destroyWhenEmptyAfter: lifetimeConfig.destroyWhenEmptyAfter,
            persistInterval: lifetimeConfig.persistInterval,
            onInitialize: lifetimeConfig.onInitialize,
            onInitializeResolverExecutors: lifetimeConfig.onInitializeResolverExecutors,
            onFinalize: lifetimeConfig.onFinalize,
            onFinalizeResolverExecutors: lifetimeConfig.onFinalizeResolverExecutors,
            afterFinalize: lifetimeConfig.afterFinalize,
            onShutdown: lifetimeConfig.onShutdown
        )

        // Build client EventRegistry from registrations
        var clientRegistry = EventRegistry<AnyClientEvent>(registered: [])
        for eventType in clientEventRegistrations {
            // Register the type (it should already be validated as ClientEventPayload in the DSL)
            clientRegistry = clientRegistry.registerClientEventErased(eventType)
        }

        // Build server EventRegistry from registrations
        var serverRegistry = EventRegistry<AnyServerEvent>(registered: [])
        for eventType in serverEventRegistrations {
            // Register the type (it should already be validated as ServerEventPayload in the DSL)
            serverRegistry = serverRegistry.registerErased(eventType)
        }

        return LandDefinition(
            id: id,
            stateType: stateType,
            clientEventRegistry: clientRegistry,
            serverEventRegistry: serverRegistry,
            config: landConfig,
            actionHandlers: actionHandlers,
            eventHandlers: eventHandlers,
            lifetimeHandlers: lifetimeHandlers
        )
    }
}
