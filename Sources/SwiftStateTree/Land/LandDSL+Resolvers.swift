import Foundation

// The entries' resolver forms (#769 R1).
//
// An action, OnInitialize or OnFinalize declares its resolvers as a closure that builds
// `Resolver` values: it runs at the point that admits the input, reads the State, the input and a
// read-only context, and returns one optional value per resolver (`nil`: nothing is fetched).
// Each value's `Dependencies` is the land's `Services`, so a resolver that needs a capability the
// land's services lack doesn't compile. The handler gets the outputs as a typed parameter, after
// the input: one output, or a tuple of them in declaration order.
//
// CanJoin, OnJoin and OnLeave keep `ContextResolver` metatypes until #769 R3, and get their
// outputs as typed parameters too.

/// An entry with resolvers, typed by the land's services: the land body's builder takes it only
/// where `Services` is the land's, so a resolver's `Dependencies` is checked at the declaration.
public struct ResolvingNode<Node: Sendable, Services: Sendable>: Sendable {
    package let node: Node

    package init(_ node: Node) {
        self.node = node
    }
}

/// The declaration of an action's resolvers: `build` gets the State and the decoded action.
func actionResolvers<State: StateNodeProtocol, A: ActionPayload>(
    _ type: A.Type,
    names: [String],
    services: Any.Type,
    site: String,
    _ build: @escaping @Sendable (State, A, ValidateContext) -> [any AnyResolverExecutor]
) -> ResolverDeclaration<(State, Any)> {
    ResolverDeclaration(names: names, servicesType: services, site: site) { input, ctx in
        // A payload of another type is refused when the handler runs (`invalidActionType`).
        guard let action = input.1 as? A else { return [] }
        return build(input.0, action, ctx)
    }
}

/// The output of a `ContextResolver` (CanJoin, OnJoin, OnLeave, until #769 R3).
func contextResolverOutput<R: ContextResolver>(_ type: R.Type, in ctx: LandContext) -> R.Output? {
    ctx.resolverOutput(
        R.Output.self,
        named: ResolverExecutor.convertResolverTypeToPropertyName(String(describing: R.self))
    )
}


/// Registers an action handler with a resolver (#769).
///
/// `resolvers` runs when the action is admitted. It reads the State, the action and a read-only
/// context, and returns the value to resolve, or `nil` to fetch nothing. The handler runs once
/// it has resolved, with its output (`nil` for a value that wasn't built).
///
/// ```swift
/// HandleAction(UpdateCart.self,
///              resolvers: { state, action, ctx in
///                  state.productCache[action.productID] == nil ? ProductInfo(productID: action.productID) : nil
///              }) { state, action, info, ctx in
///     ...
/// }
/// ```
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> R1?,
    _ body: @escaping @Sendable (inout State, A, R1.Output?, LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            return r1.executors(value)
        },
        invoke: { state, action, ctx in body(&state, action, r1.output(in: ctx), ctx) }
    ))
}

/// The two-stage form (#586) with a resolver (#769): `validate` and `apply` both get the outputs.
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver, Plan>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> R1?,
    validate: @escaping @Sendable (State, A, R1.Output?, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, A, R1.Output?, Plan, LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            return r1.executors(value)
        },
        invoke: { state, action, ctx in
            let outputs = r1.output(in: ctx)
            let plan = try validate(state, action, outputs, ValidateContext(ctx))
            return apply(&state, action, outputs, plan, ctx)
        }
    ))
}

/// The two-stage form (#586) with a resolver and nothing to pass from `validate` to `apply` (#769).
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> R1?,
    validate: @escaping @Sendable (State, A, R1.Output?, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, A, R1.Output?, LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            return r1.executors(value)
        },
        invoke: { state, action, ctx in
            let outputs = r1.output(in: ctx)
            try validate(state, action, outputs, ValidateContext(ctx))
            return apply(&state, action, outputs, ctx)
        }
    ))
}

/// Registers an action handler with 2 resolvers (#769).
///
/// `resolvers` runs when the action is admitted. It reads the State, the action and a read-only
/// context, and returns one value per resolver, each `nil` to fetch nothing. The handler runs once
/// they have resolved, with their outputs, in declaration order (`nil` for a value that wasn't built).
///
/// ```swift
/// HandleAction(UpdateCart.self,
///              resolvers: { state, action, ctx in
///                  (state.productCache[action.productID] == nil ? ProductInfo(productID: action.productID) : nil,
///                   UserProfile(playerID: ctx.playerID))
///              }) { state, action, outputs, ctx in
///     let (info, profile) = outputs
///     ...
/// }
/// ```
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver, R2: Resolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> (R1?, R2?),
    _ body: @escaping @Sendable (inout State, A, (R1.Output?, R2.Output?), LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name, r2.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        invoke: { state, action, ctx in body(&state, action, (r1.output(in: ctx), r2.output(in: ctx)), ctx) }
    ))
}

/// The two-stage form (#586) with 2 resolvers (#769): `validate` and `apply` both get the outputs.
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver, R2: Resolver, Plan>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> (R1?, R2?),
    validate: @escaping @Sendable (State, A, (R1.Output?, R2.Output?), ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, A, (R1.Output?, R2.Output?), Plan, LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name, r2.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        invoke: { state, action, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx))
            let plan = try validate(state, action, outputs, ValidateContext(ctx))
            return apply(&state, action, outputs, plan, ctx)
        }
    ))
}

/// The two-stage form (#586) with 2 resolvers and nothing to pass from `validate` to `apply` (#769).
public func HandleAction<State: StateNodeProtocol, Services: Sendable, A: ActionPayload, R1: Resolver, R2: Resolver>(
    _ type: A.Type,
    fileID: String = #fileID,
    line: Int = #line,
    resolvers: @escaping @Sendable (State, A, ValidateContext) -> (R1?, R2?),
    validate: @escaping @Sendable (State, A, (R1.Output?, R2.Output?), ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, A, (R1.Output?, R2.Output?), LandContext) -> A.Response
) -> ResolvingNode<AnyActionHandler<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(makeActionHandler(
        type,
        site: site,
        resolvers: actionResolvers(A.self, names: [r1.name, r2.name], services: Services.self, site: site) { state, action, ctx in
            let value = resolvers(state, action, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        invoke: { state, action, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx))
            try validate(state, action, outputs, ValidateContext(ctx))
            return apply(&state, action, outputs, ctx)
        }
    ))
}

/// Registers OnInitialize with a resolver (#769).
///
/// `resolvers` runs when the land initializes, with the initial State and a read-only context
/// (`ctx.landID`; its `metadata` is empty). The body runs once it has resolved, with
/// its output. With `onResolverFailure: .continue`, a failed group gives `nil` for every output.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> R1?,
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, R1.Output?, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in body(&state, r1.output(in: ctx), ctx) }),
        resolvers: ResolverDeclaration(names: [r1.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            return r1.executors(value)
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with a resolver (#769): `validate` and `apply` both get the outputs.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, Plan>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> R1?,
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, R1.Output?, ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, R1.Output?, Plan, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = r1.output(in: ctx)
            let plan = try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, plan, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            return r1.executors(value)
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with a resolver and nothing to pass from `validate` to `apply` (#769).
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> R1?,
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, R1.Output?, ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, R1.Output?, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = r1.output(in: ctx)
            try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            return r1.executors(value)
        },
        onResolverFailure: onResolverFailure
    ))
}

/// Registers OnInitialize with 2 resolvers (#769).
///
/// `resolvers` runs when the land initializes, with the initial State and a read-only context
/// (`ctx.landID`; its `metadata` is empty). The body runs once they have resolved, with
/// their outputs. With `onResolverFailure: .continue`, a failed group gives `nil` for every output.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in body(&state, (r1.output(in: ctx), r2.output(in: ctx)), ctx) }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with 2 resolvers (#769): `validate` and `apply` both get the outputs.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver, Plan>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, (R1.Output?, R2.Output?), ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), Plan, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx))
            let plan = try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, plan, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with 2 resolvers and nothing to pass from `validate` to `apply` (#769).
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, (R1.Output?, R2.Output?), ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx))
            try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(2)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// Registers OnInitialize with 3 resolvers (#769).
///
/// `resolvers` runs when the land initializes, with the initial State and a read-only context
/// (`ctx.landID`; its `metadata` is empty). The body runs once they have resolved, with
/// their outputs. With `onResolverFailure: .continue`, a failed group gives `nil` for every output.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver, R3: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?, R3?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services, R3.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self), r3 = ResolverSlot(R3.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in body(&state, (r1.output(in: ctx), r2.output(in: ctx), r3.output(in: ctx)), ctx) }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name, r3.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(3)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            r3.append(value.2, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with 3 resolvers (#769): `validate` and `apply` both get the outputs.
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver, R3: Resolver, Plan>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?, R3?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, (R1.Output?, R2.Output?, R3.Output?), ValidateContext) throws -> Plan,
    apply: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), Plan, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services, R3.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self), r3 = ResolverSlot(R3.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx), r3.output(in: ctx))
            let plan = try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, plan, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name, r3.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(3)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            r3.append(value.2, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// OnInitialize in two stages (#593) with 3 resolvers and nothing to pass from `validate` to `apply` (#769).
public func OnInitialize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver, R3: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?, R3?),
    onResolverFailure: InitializeResolverFailure = .failLand,
    fileID: String = #fileID,
    line: Int = #line,
    validate: @escaping @Sendable (State, (R1.Output?, R2.Output?, R3.Output?), ValidateContext) throws -> Void,
    apply: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services, R3.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self), r3 = ResolverSlot(R3.self)
    return ResolvingNode(initializeDirective(
        site: site,
        InitializeHandler(invoke: { state, ctx in
            let outputs = (r1.output(in: ctx), r2.output(in: ctx), r3.output(in: ctx))
            try validate(state, outputs, ValidateContext(ctx))
            apply(&state, outputs, ctx)
        }),
        resolvers: ResolverDeclaration(names: [r1.name, r2.name, r3.name], servicesType: Services.self, site: site) { state, ctx in
            let value = resolvers(state, ctx)
            var executors: [any AnyResolverExecutor] = []
            executors.reserveCapacity(3)
            r1.append(value.0, to: &executors)
            r2.append(value.1, to: &executors)
            r3.append(value.2, to: &executors)
            return executors
        },
        onResolverFailure: onResolverFailure
    ))
}

/// Registers OnFinalize with a resolver (#769).
///
/// `resolvers` runs when the land finalizes, with its final State and a read-only context (the
/// land's ID is `ctx.landID`). The body runs once it has resolved, with its output. A
/// resolver that throws skips the body; the teardown goes on.
public func OnFinalize<State: StateNodeProtocol, Services: Sendable, R1: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> R1?,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, R1.Output?, LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self)
    let declaration = ResolverDeclaration<State>(names: [r1.name], servicesType: Services.self, site: site) { state, ctx in
        let value = resolvers(state, ctx)
        return r1.executors(value)
    }
    return ResolvingNode { config in
        guard config.claim(.onFinalize, at: site) else { return }
        config.onFinalize = { state, ctx in body(&state, r1.output(in: ctx), ctx) }
        config.onFinalizeResolvers = declaration
    }
}

/// Registers OnFinalize with 2 resolvers (#769).
///
/// `resolvers` runs when the land finalizes, with its final State and a read-only context (the
/// land's ID is `ctx.landID`). The body runs once they have resolved, with their outputs. A
/// resolver that throws skips the body; the teardown goes on.
public func OnFinalize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self)
    let declaration = ResolverDeclaration<State>(names: [r1.name, r2.name], servicesType: Services.self, site: site) { state, ctx in
        let value = resolvers(state, ctx)
        var executors: [any AnyResolverExecutor] = []
        executors.reserveCapacity(2)
        r1.append(value.0, to: &executors)
        r2.append(value.1, to: &executors)
        return executors
    }
    return ResolvingNode { config in
        guard config.claim(.onFinalize, at: site) else { return }
        config.onFinalize = { state, ctx in body(&state, (r1.output(in: ctx), r2.output(in: ctx)), ctx) }
        config.onFinalizeResolvers = declaration
    }
}

/// Registers OnFinalize with 3 resolvers (#769).
///
/// `resolvers` runs when the land finalizes, with its final State and a read-only context (the
/// land's ID is `ctx.landID`). The body runs once they have resolved, with their outputs. A
/// resolver that throws skips the body; the teardown goes on.
public func OnFinalize<State: StateNodeProtocol, Services: Sendable, R1: Resolver, R2: Resolver, R3: Resolver>(
    resolvers: @escaping @Sendable (State, ValidateContext) -> (R1?, R2?, R3?),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), LandContext) -> Void
) -> ResolvingNode<LifetimeDirective<State>, Services> where R1.Dependencies == Services, R2.Dependencies == Services, R3.Dependencies == Services {
    let site = "\(fileID):\(line)"
    let r1 = ResolverSlot(R1.self), r2 = ResolverSlot(R2.self), r3 = ResolverSlot(R3.self)
    let declaration = ResolverDeclaration<State>(names: [r1.name, r2.name, r3.name], servicesType: Services.self, site: site) { state, ctx in
        let value = resolvers(state, ctx)
        var executors: [any AnyResolverExecutor] = []
        executors.reserveCapacity(3)
        r1.append(value.0, to: &executors)
        r2.append(value.1, to: &executors)
        r3.append(value.2, to: &executors)
        return executors
    }
    return ResolvingNode { config in
        guard config.claim(.onFinalize, at: site) else { return }
        config.onFinalize = { state, ctx in body(&state, (r1.output(in: ctx), r2.output(in: ctx), r3.output(in: ctx)), ctx) }
        config.onFinalizeResolvers = declaration
    }
}

/// Registers a handler called when a player joins, with a resolver. Its output arrives as a
/// typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, R1.Output?, LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: { state, ctx in body(&state, contextResolverOutput(R1.self, in: ctx), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self)]
    )
}

/// Registers a handler called when a player leaves, with a resolver. Its output arrives as
/// a typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, R1.Output?, LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: { state, ctx in body(&state, contextResolverOutput(R1.self, in: ctx), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self)]
    )
}

/// Registers a join check with a resolver. Its output arrives as a typed parameter
/// (#769). `ContextResolver` metatypes stay here until #769 R3.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver>(
    resolvers: R1.Type,
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (State, PlayerSession, R1.Output?, LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: { state, session, ctx in try body(state, session, contextResolverOutput(R1.self, in: ctx), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self)]
    )
}

/// Registers a handler called when a player joins, with 2 resolvers. Its outputs arrive as a
/// typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: { state, ctx in body(&state, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self)]
    )
}

/// Registers a handler called when a player leaves, with 2 resolvers. Its outputs arrive as
/// a typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?), LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: { state, ctx in body(&state, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self)]
    )
}

/// Registers a join check with 2 resolvers. Its outputs arrive as a typed parameter
/// (#769). `ContextResolver` metatypes stay here until #769 R3.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver>(
    resolvers: (R1.Type, R2.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (State, PlayerSession, (R1.Output?, R2.Output?), LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: { state, session, ctx in try body(state, session, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self)]
    )
}

/// Registers a handler called when a player joins, with 3 resolvers. Its outputs arrive as a
/// typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), LandContext) -> Void
) -> OnJoinNode<State> {
    OnJoinNode(
        handler: { state, ctx in body(&state, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx), contextResolverOutput(R3.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self), ResolverExecutor.createExecutor(for: R3.self)]
    )
}

/// Registers a handler called when a player leaves, with 3 resolvers. Its outputs arrive as
/// a typed parameter (#769). `ContextResolver` metatypes stay here until #769 R3.
public func OnLeave<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (inout State, (R1.Output?, R2.Output?, R3.Output?), LandContext) -> Void
) -> OnLeaveNode<State> {
    OnLeaveNode(
        handler: { state, ctx in body(&state, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx), contextResolverOutput(R3.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self), ResolverExecutor.createExecutor(for: R3.self)]
    )
}

/// Registers a join check with 3 resolvers. Its outputs arrive as a typed parameter
/// (#769). `ContextResolver` metatypes stay here until #769 R3.
public func CanJoin<State: StateNodeProtocol, R1: ContextResolver, R2: ContextResolver, R3: ContextResolver>(
    resolvers: (R1.Type, R2.Type, R3.Type),
    fileID: String = #fileID,
    line: Int = #line,
    _ body: @escaping @Sendable (State, PlayerSession, (R1.Output?, R2.Output?, R3.Output?), LandContext) throws -> JoinDecision
) -> CanJoinNode<State> {
    CanJoinNode(
        handler: { state, session, ctx in try body(state, session, (contextResolverOutput(R1.self, in: ctx), contextResolverOutput(R2.self, in: ctx), contextResolverOutput(R3.self, in: ctx)), ctx) },
        site: "\(fileID):\(line)",
        resolverExecutors: [ResolverExecutor.createExecutor(for: R1.self), ResolverExecutor.createExecutor(for: R2.self), ResolverExecutor.createExecutor(for: R3.self)]
    )
}
