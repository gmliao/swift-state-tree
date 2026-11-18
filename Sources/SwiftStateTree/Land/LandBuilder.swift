import Foundation

/// Thread-safe queue for warning messages to prevent concurrent write issues.
private let warningQueue = DispatchQueue(label: "com.swiftstatetree.landbuilder.warnings")

/// Helper function to warn when a handler is already defined (for LandBuilder)
///
/// Uses a serial dispatch queue to ensure thread-safe output, as multiple threads
/// may call `LandBuilder.build` concurrently when creating different lands.
/// Uses `sync` to ensure warnings are printed immediately and in order.
private func warnIfHandlerAlreadyDefined(_ handlerName: String, landID: String) {
    let message = "⚠️ [LandBuilder] \(handlerName) handler is already defined for land '\(landID)'. The previous handler will be replaced.\n"
    warningQueue.sync {
        writeStandardErrorDiagnostic(message)
    }
}

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
        var onJoin: (@Sendable (inout State, LandContext) -> Void)?
        var onJoinResolverExecutors: [any AnyResolverExecutor] = []
        var onLeave: (@Sendable (inout State, LandContext) -> Void)?
        var onLeaveResolverExecutors: [any AnyResolverExecutor] = []
        var actionHandlers: [AnyActionHandler<State>] = []
        var eventHandlers: [AnyClientEventHandler<State>] = []
        var serverInputHandlers: [String: AnyServerInputHandler<State>] = [:]
        // One handler per action, client-event and server-input type (#586): the first is kept, a later
        // one is recorded and refused by registration (and by an unregistered keeper's
        // initialization).
        var duplicateHandlers: [DuplicateHandlerDeclaration] = []
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
                    if onJoin != nil {
                        warnIfHandlerAlreadyDefined("OnJoin", landID: id)
                    }
                    onJoin = join.handler
                    onJoinResolverExecutors = join.resolverExecutors
                case let leave as OnLeaveNode<State>:
                    if onLeave != nil {
                        warnIfHandlerAlreadyDefined("OnLeave", landID: id)
                    }
                    onLeave = leave.handler
                    onLeaveResolverExecutors = leave.resolverExecutors
                case let action as AnyActionHandler<State>:
                    if let first = actionHandlers.first(where: { $0.canHandle(action.handledType) }) {
                        duplicateHandlers.append(DuplicateHandlerDeclaration(
                            kind: "action",
                            typeName: String(describing: action.handledType),
                            firstSite: first.site,
                            duplicateSite: action.site
                        ))
                    } else if let (first, name) = actionHandlers.lazy.compactMap({ other in
                        sharedActionName(other.handledType, action.handledType).map { (other, $0) }
                    }).first {
                        duplicateHandlers.append(DuplicateHandlerDeclaration(
                            kind: "action",
                            typeName: String(reflecting: action.handledType),
                            firstSite: first.site,
                            duplicateSite: action.site,
                            firstTypeName: String(reflecting: first.handledType),
                            wireName: name
                        ))
                    } else {
                        actionHandlers.append(action)
                    }
                case let handler as AnyClientEventHandler<State>:
                    if let first = eventHandlers.first(where: { $0.canHandle(handler.handledType) }) {
                        duplicateHandlers.append(DuplicateHandlerDeclaration(
                            kind: "client event",
                            typeName: String(describing: handler.handledType),
                            firstSite: first.site,
                            duplicateSite: handler.site
                        ))
                    } else {
                        eventHandlers.append(handler)
                    }
                case let handler as AnyServerInputHandler<State>:
                    if let other = serverInputHandlers[handler.typeIdentifier] {
                        // Recorded and dispatched by name: two types with one name are refused
                        // like one type declared twice (#599).
                        let distinct = ObjectIdentifier(other.inputType) != ObjectIdentifier(handler.inputType)
                        duplicateHandlers.append(DuplicateHandlerDeclaration(
                            kind: "server input",
                            typeName: distinct ? String(reflecting: handler.inputType) : handler.typeIdentifier,
                            firstSite: other.site,
                            duplicateSite: handler.site,
                            firstTypeName: distinct ? String(reflecting: other.inputType) : nil,
                            wireName: distinct ? handler.typeIdentifier : nil
                        ))
                    } else {
                        serverInputHandlers[handler.typeIdentifier] = handler
                    }
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
            syncInterval: lifetimeConfig.syncInterval,
            syncHandler: lifetimeConfig.syncHandler,
            destroyWhenEmptyAfter: lifetimeConfig.destroyWhenEmptyAfter,
            onDestroyWhenEmpty: lifetimeConfig.onDestroyWhenEmpty,
            onDestroyWhenEmptyResolverExecutors: lifetimeConfig.onDestroyWhenEmptyResolverExecutors,
            persistInterval: lifetimeConfig.persistInterval,
            onInitialize: lifetimeConfig.onInitialize,
            onInitializeResolverExecutors: lifetimeConfig.onInitializeResolverExecutors,
            onInitializeResolverFailure: lifetimeConfig.onInitializeResolverFailure,
            onFinalize: lifetimeConfig.onFinalize,
            onFinalizeResolverExecutors: lifetimeConfig.onFinalizeResolverExecutors,
            afterFinalize: lifetimeConfig.afterFinalize,
            onShutdown: lifetimeConfig.onShutdown
        )

        // The registries are keyed by event name: two registered types with one name would leave
        // one of them unreachable, so they are refused (#599). A type registered twice is kept once.
        duplicateHandlers += sharedEventNames(clientEventRegistrations, kind: "client event")
        duplicateHandlers += sharedEventNames(serverEventRegistrations, kind: "server event")

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
            serverInputHandlers: serverInputHandlers,
            duplicateHandlers: duplicateHandlers,
            lifetimeHandlers: lifetimeHandlers
        )
    }
}

/// The name an envelope could reach both action types by, if any (#599). Action intake matches an
/// envelope's `typeIdentifier` against a handler's type name, its last dotted component, or its
/// schema name (`payloadActionName`), first handler first; so two types collide exactly when
/// those name sets meet.
func sharedActionName(_ first: Any.Type, _ second: Any.Type) -> String? {
    func names(_ type: Any.Type) -> [String] {
        let full = String(describing: type)
        let last = full.split(separator: ".").last.map(String.init) ?? full
        return [full, last, payloadActionName(for: type)]
    }
    let firstNames = names(first)
    let secondNames = names(second)
    if let exact = secondNames.first(where: { firstNames.contains($0) }) { return exact }
    // Intake also matches the schema name case-insensitively (`PING` reaches `PingAction`).
    let firstSchema = firstNames[2].lowercased()
    let secondSchema = secondNames[2].lowercased()
    if secondNames.contains(where: { $0.lowercased() == firstSchema }) { return firstNames[2] }
    if firstNames.contains(where: { $0.lowercased() == secondSchema }) { return secondNames[2] }
    return nil
}

/// Two distinct registered event types with one event name (#599).
func sharedEventNames(_ types: [Any.Type], kind: String) -> [DuplicateHandlerDeclaration] {
    var byName: [String: Any.Type] = [:]
    var shared: [DuplicateHandlerDeclaration] = []
    for type in types {
        let name = payloadEventName(for: type)
        if let first = byName[name] {
            if ObjectIdentifier(first) != ObjectIdentifier(type) {
                shared.append(DuplicateHandlerDeclaration(
                    kind: kind,
                    typeName: String(reflecting: type),
                    firstSite: nil,
                    duplicateSite: nil,
                    firstTypeName: String(reflecting: first),
                    wireName: name
                ))
            }
        } else {
            byName[name] = type
        }
    }
    return shared
}
