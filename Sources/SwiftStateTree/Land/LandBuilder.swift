import Foundation

/// Internal builder that processes the DSL nodes and constructs a `LandDefinition`.
enum LandBuilder {
    /// Builds a `LandDefinition` from a list of `LandNode`s.
    ///
    /// This function iterates through the provided nodes and aggregates their configuration into
    /// the final definition. `Rules` blocks arrive flattened: the land's builder splices their
    /// nodes in (`LandDSL.buildExpression(LandRules)`).
    static func build<State: StateNodeProtocol>(
        id: String,
        stateType: State.Type,
        nodes: [LandNode],
        servicesType: Any.Type? = nil
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
        // A node a land declares once (#796), by name: `AccessControl`, `CanJoin`, `OnJoin`,
        // `OnLeave`, and each `Lifetime` setting. The first is kept; a later one is recorded in
        // `duplicateHandlers` and refused the same way.
        var onceSites: [String: String?] = [:]
        func claimOnce(_ node: String, at site: String?) -> Bool {
            if let first = onceSites[node] {
                duplicateHandlers.append(DuplicateHandlerDeclaration(node: node, firstSite: first, duplicateSite: site))
                return false
            }
            onceSites[node] = site
            return true
        }
        var clientEventRegistrations: [Any.Type] = []
        var serverEventRegistrations: [Any.Type] = []
        // A node no case below matches: another State's node, or a type the builder doesn't
        // know. Dropping it would leave the land without its handlers, so registration and an
        // unregistered keeper's initialization refuse the land instead (#794).
        var unrecognizedNodes: [String] = []

        func ingest(nodes: [LandNode]) {
            for node in nodes {
                switch node {
                case let access as AccessControlNode:
                    if claimOnce("AccessControl", at: access.site) {
                        accessControl = access.config
                    }
                case let allowed as AllowedClientEventsNode:
                    allowedClientEvents.formUnion(allowed.allowed)
                case let canJoinNode as CanJoinNode<State>:
                    if claimOnce("CanJoin", at: canJoinNode.site) {
                        canJoin = canJoinNode.handler
                        canJoinResolverExecutors = canJoinNode.resolverExecutors
                    }
                case let join as OnJoinNode<State>:
                    if claimOnce("OnJoin", at: join.site) {
                        onJoin = join.handler
                        onJoinResolverExecutors = join.resolverExecutors
                    }
                case let leave as OnLeaveNode<State>:
                    if claimOnce("OnLeave", at: leave.site) {
                        onLeave = leave.handler
                        onLeaveResolverExecutors = leave.resolverExecutors
                    }
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
                    // The block runs once, on its own config: the settings it makes, with the
                    // first of any it makes twice kept and the rest recorded. Each setting no
                    // earlier block made is copied into the land's config; one another block
                    // made first is a duplicate (#796).
                    var own = LifetimeConfig<State>()
                    lifetime.configure(&own)
                    duplicateHandlers += own.repeatedSettings
                    for setting in LifetimeSetting.allCases where own.holds(setting) {
                        if claimOnce(setting.rawValue, at: own.settingSites[setting] ?? lifetime.site) {
                            lifetimeConfig.take(setting, from: own)
                        }
                    }
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
                default:
                    unrecognizedNodes.append(String(reflecting: type(of: node)))
                }
            }
        }

        ingest(nodes: nodes)

        // #771 §3.3: the land's client event registrations and its HandleEvent handlers agree.
        // A registered event without a handler, or a handled one that isn't registered, would
        // otherwise fail per event at intake; registration refuses the land instead. A type
        // registered twice is named once.
        var clientEventMismatches: [String] = []
        var seenRegistrations: Set<ObjectIdentifier> = []
        for type in clientEventRegistrations where seenRegistrations.insert(ObjectIdentifier(type)).inserted {
            if !eventHandlers.contains(where: { $0.canHandle(type) }) {
                clientEventMismatches.append("\(String(reflecting: type)): registered, no HandleEvent")
            }
        }
        for handler in eventHandlers where !seenRegistrations.contains(ObjectIdentifier(handler.handledType)) {
            clientEventMismatches.append("\(String(reflecting: handler.handledType)): handled, not in ClientEvents")
        }

        // #769: each declaration's resolvers depend on the land's services, and no two in one
        // declaration share a base type (the record names an output by it until R2 keys them by
        // position).
        let landServices = servicesType ?? NoServices.self
        var resolverDeclarationProblems: [String] = []
        func check(_ entry: String, _ names: [String], _ services: Any.Type, _ site: String) {
            if ObjectIdentifier(services) != ObjectIdentifier(landServices) {
                resolverDeclarationProblems.append(
                    "\(entry) at \(site): its resolvers depend on \(String(reflecting: services)), the land's services are \(String(reflecting: landServices))"
                )
            }
            var seen: Set<String> = []
            for name in names where !seen.insert(name).inserted {
                resolverDeclarationProblems.append(
                    "\(entry) at \(site): two resolvers of type \(name); one declaration resolves each type once"
                )
            }
        }
        for handler in actionHandlers {
            if let declaration = handler.resolvers {
                check("HandleAction(\(String(describing: handler.handledType)))", declaration.names, declaration.servicesType, declaration.site)
            }
        }
        if let declaration = lifetimeConfig.onInitializeResolvers {
            check("OnInitialize", declaration.names, declaration.servicesType, declaration.site)
        }
        if let declaration = lifetimeConfig.onFinalizeResolvers {
            check("OnFinalize", declaration.names, declaration.servicesType, declaration.site)
        }

        let landConfig = LandConfig(
            allowPublic: accessControl.allowPublic,
            maxPlayers: accessControl.maxPlayers,
            allowedClientEvents: allowedClientEvents,
            tickInterval: hasLifetimeConfig ? lifetimeConfig.tickInterval : nil,
            destroyWhenEmptyAfter: hasLifetimeConfig ? lifetimeConfig.destroyWhenEmptyAfter : nil,
            persistInterval: hasLifetimeConfig ? lifetimeConfig.persistInterval : nil
        )

        var lifetimeHandlers = LifetimeHandlers<State>(
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
            onInitializeResolverFailure: lifetimeConfig.onInitializeResolverFailure,
            onFinalize: lifetimeConfig.onFinalize,
            afterFinalize: lifetimeConfig.afterFinalize
        )
        lifetimeHandlers.onInitializeResolvers = lifetimeConfig.onInitializeResolvers
        lifetimeHandlers.onFinalizeResolvers = lifetimeConfig.onFinalizeResolvers

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
            clientEventMismatches: clientEventMismatches,
            unrecognizedNodes: unrecognizedNodes,
            resolverDeclarationProblems: resolverDeclarationProblems,
            lifetimeHandlers: lifetimeHandlers,
            servicesType: servicesType
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
    // The name a client sends that reaches both: the other type's own name.
    if let name = secondNames.first(where: { $0.lowercased() == firstSchema }) { return name }
    return firstNames.first { $0.lowercased() == secondSchema }
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
