// Tests/SwiftStateTreeTests/ResolverValueTests.swift
//
// #769 R1: a resolver is a value. The entry's `resolvers:` closure builds it when the input is
// admitted, from the State and the input; its `resolve` sees only its fields and the land's
// services; the handler gets the outputs as typed parameters, in declaration order.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - State and payloads

@StateNodeBuilder
struct ResolverValueState: StateNodeProtocol {
    @Sync(.broadcast)
    var x: Int = 0

    /// What the last resolved handler saw: its output, or -1 for `nil`.
    @Sync(.broadcast)
    var seen: Int = 0

    @Sync(.broadcast)
    var seenSecond: Int = 0

    @Sync(.broadcast)
    var seenThird: Int = 0

    public init() {}
}

@Payload
struct ReadXAction: ActionPayload {
    typealias Response = ResolverValueAck
}

@Payload
struct SetXAction: ActionPayload {
    typealias Response = ResolverValueAck
    let value: Int
}

@Payload
struct MaybeAction: ActionPayload {
    typealias Response = ResolverValueAck
    let key: Int
    let fetch: Bool
}

@Payload
struct PairAction: ActionPayload {
    typealias Response = ResolverValueAck
}

@Payload
struct FailingAction: ActionPayload {
    typealias Response = ResolverValueAck
}

@Payload
struct ResolverValueAck: ResponsePayload {
    let ok: Bool
}

@PlainData
struct TaggedOutput: ResolverOutput {
    let value: Int
}

// MARK: - Resolvers

/// Keys for `ResolveCounts`, one per test: tests run in parallel.
enum ResolverValueKeys {
    private static let keys = KeyedGates(firstKey: 5_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
}

/// Counts `resolve` calls per key, so a test sees whether its resolver ran.
enum ResolveCounts {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var counts: [Int: Int] = [:]
    static func note(_ key: Int) { lock.withLock { counts[key, default: 0] += 1 } }
    static func count(_ key: Int) -> Int { lock.withLock { counts[key] ?? 0 } }
}

/// Returns the `x` it was built with.
@PlainData
struct ReadX: Resolver {
    typealias Dependencies = NoServices
    let x: Int

    func resolve(_ deps: NoServices) async throws -> TaggedOutput {
        TaggedOutput(value: x)
    }
}

@PlainData
struct Counted: Resolver {
    typealias Dependencies = NoServices
    let key: Int

    func resolve(_ deps: NoServices) async throws -> TaggedOutput {
        ResolveCounts.note(key)
        return TaggedOutput(value: key)
    }
}

@PlainData
struct First: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> TaggedOutput { TaggedOutput(value: 1) }
}

@PlainData
struct Second: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> TaggedOutput { TaggedOutput(value: 2) }
}

@PlainData
struct Third: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> TaggedOutput { TaggedOutput(value: 3) }
}

struct ResolverValueFailure: Error, Equatable {}

/// `Shared` and `SharedResolver` are distinct types whose outputs are both stored as `shared`.
@PlainData
struct Shared: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> TaggedOutput { TaggedOutput(value: 10) }
}

@PlainData
struct SharedResolver: Resolver {
    typealias Dependencies = NoServices
    func resolve(_ deps: NoServices) async throws -> TaggedOutput { TaggedOutput(value: 20) }
}

/// The `ContextResolver` pair with one output name: `legacyShared`.
struct LegacyShared: ContextResolver {
    static func resolve(ctx: ResolverContext) async throws -> TaggedOutput { TaggedOutput(value: 1) }
}

struct LegacySharedResolver: ContextResolver {
    static func resolve(ctx: ResolverContext) async throws -> TaggedOutput { TaggedOutput(value: 2) }
}


/// Generic over what it doesn't store: its errors name the base type, `Failing`.
@PlainData
struct Failing<D: Sendable>: Resolver {
    typealias Dependencies = D
    func resolve(_ deps: D) async throws -> TaggedOutput { throw ResolverValueFailure() }
}

// MARK: - Services

protocol HasPriceList: Sendable {
    var prices: [Int: Int] { get }
}

struct PriceServices: HasPriceList {
    let prices: [Int: Int]
}

/// Reads its price from the land's services.
@PlainData
struct Price<D: HasPriceList>: Resolver {
    typealias Dependencies = D
    let item: Int
    func resolve(_ deps: D) async throws -> TaggedOutput {
        TaggedOutput(value: deps.prices[item] ?? -1)
    }
}

@Payload
struct PriceAction: ActionPayload {
    typealias Response = ResolverValueAck
    let item: Int
}

// MARK: - Lands

private func makeLand() -> LandDefinition<ResolverValueState> {
    Land("resolver-value", using: ResolverValueState.self) {
        Rules {
            HandleAction(ReadXAction.self, resolvers: { state, _, _ in
                ReadX(x: state.x)
            }) { state, _, read, _ in
                state.seen = read?.value ?? -1
                return ResolverValueAck(ok: true)
            }
            HandleAction(SetXAction.self) { state, action, _ in
                state.x = action.value
                return ResolverValueAck(ok: true)
            }
            HandleAction(MaybeAction.self, resolvers: { _, action, _ in
                action.fetch ? Counted(key: action.key) : nil
            }) { state, _, counted, _ in
                state.seen = counted?.value ?? -1
                return ResolverValueAck(ok: true)
            }
            HandleAction(PairAction.self, resolvers: { _, _, _ in (First(), Second()) }) { state, _, resolved, _ in
                state.seen = resolved.0?.value ?? -1
                state.seenSecond = resolved.1?.value ?? -1
                return ResolverValueAck(ok: true)
            }
            HandleAction(FailingAction.self, resolvers: { _, _, _ in Failing() }) { _, _, _, _ in
                ResolverValueAck(ok: true)
            }
        }
        Lifetime {
            OnInitialize(resolvers: { _, _ in (First(), Second(), Third()) }) { state, resolved, _ in
                state.seen = resolved.0?.value ?? -1
                state.seenSecond = resolved.1?.value ?? -1
                state.seenThird = resolved.2?.value ?? -1
            }
        }
    }
}

private func makePriceLand() -> TypedLand<ResolverValueState, PriceServices> {
    Land("resolver-price", using: ResolverValueState.self, services: PriceServices.self) {
        Rules {
            HandleAction(PriceAction.self, resolvers: { _, action, _ in Price(item: action.item) }) { state, _, price, _ in
                state.seen = price?.value ?? -1
                return ResolverValueAck(ok: true)
            }
        }
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

private func envelope<A: ActionPayload>(_ action: A) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(action))
}

private func makeKeeper() async throws -> LandKeeper<ResolverValueState> {
    let keeper = LandKeeper<ResolverValueState>(
        definition: makeLand(),
        initialState: ResolverValueState(),
        autoStartLoops: false,
        landID: "resolver-value:local"
    )
    try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
    return keeper
}

// MARK: - Tests

@Suite("Resolvers are values (#769 R1)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct ResolverValueTests {
    @Test("The value is built when the action is admitted: a change to State before its job runs doesn't reach it")
    func builtAtAdmission() async throws {
        let keeper = try await makeKeeper()
        let gate = WatermarkGate()
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.actionJobStart) { await gate.enterAndWait() })
        let read = Task { try await keeper.handleActionEnvelope(envelope(ReadXAction()), playerID: p1, clientID: c1, sessionID: s1) }
        guard await gate.waitUntilEntered("the action's job holds before its resolvers") else { return }

        // Admitted with x == 0; x changes before the job runs its resolvers.
        _ = try await keeper.handleActionEnvelope(envelope(SetXAction(value: 5)), playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.currentState().x == 5)

        gate.release()
        _ = try await read.value
        #expect(await keeper.currentState().seen == 0)
    }

    @Test("A nil value fetches nothing, and the handler gets nil")
    func nilSkips() async throws {
        let keeper = try await makeKeeper()
        let skipped = ResolverValueKeys.freshKey()
        _ = try await keeper.handleActionEnvelope(envelope(MaybeAction(key: skipped, fetch: false)), playerID: p1, clientID: c1, sessionID: s1)
        #expect(ResolveCounts.count(skipped) == 0)
        #expect(await keeper.currentState().seen == -1)

        // The control: a built value is resolved, and its output arrives.
        let fetched = ResolverValueKeys.freshKey()
        _ = try await keeper.handleActionEnvelope(envelope(MaybeAction(key: fetched, fetch: true)), playerID: p1, clientID: c1, sessionID: s1)
        #expect(ResolveCounts.count(fetched) == 1)
        #expect(await keeper.currentState().seen == fetched)
    }

    @Test("Two resolvers' outputs reach the handler in declaration order")
    func twoOutputsInOrder() async throws {
        let keeper = try await makeKeeper()
        _ = try await keeper.handleActionEnvelope(envelope(PairAction()), playerID: p1, clientID: c1, sessionID: s1)
        let state = await keeper.currentState()
        #expect(state.seen == 1)
        #expect(state.seenSecond == 2)
    }

    @Test("OnInitialize's three outputs reach its body in declaration order")
    func threeOutputsInOrder() async throws {
        let keeper = try await makeKeeper()
        let state = await keeper.currentState()
        #expect(state.seen == 1)
        #expect(state.seenSecond == 2)
        #expect(state.seenThird == 3)
    }

    @Test("A generic resolver's failure names its base type")
    func failureNamesBaseType() async throws {
        let keeper = try await makeKeeper()
        do {
            _ = try await keeper.handleActionEnvelope(envelope(FailingAction()), playerID: p1, clientID: c1, sessionID: s1)
            Issue.record("Expected the resolver's failure")
        } catch ResolverExecutionError.resolverFailed(let name, let underlying) {
            #expect(name == "Failing")
            #expect(underlying is ResolverValueFailure)
        }
    }

    @Test("A land with services: its resolvers get the value the typed keeper was given")
    func typedKeeperGivesServices() async throws {
        let keeper = LandKeeper(
            land: makePriceLand(),
            resolverServices: PriceServices(prices: [7: 70]),
            initialState: ResolverValueState(),
            autoStartLoops: false,
            landID: "resolver-price:local"
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        _ = try await keeper.handleActionEnvelope(envelope(PriceAction(item: 7)), playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.currentState().seen == 70)
    }

    @Test("A live keeper built from a services land's definition alone fails its initialization: the join is refused, and a leave gets the registration error")
    func definitionAloneRefusesJoin() async throws {
        let keeper = LandKeeper<ResolverValueState>(
            definition: makePriceLand().definition,
            initialState: ResolverValueState(),
            autoStartLoops: false,
            landID: "resolver-price:untyped"
        )
        let refusal = await #expect(throws: JoinError.self) {
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        }
        guard case .landShuttingDown? = refusal else {
            Issue.record("Expected landShuttingDown, got \(String(describing: refusal))")
            return
        }
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        }
        let registration = try #require(failure.underlying as? LandRegistrationError)
        #expect(registration.missingServices == String(reflecting: PriceServices.self))
    }

    @Test("A live keeper given services of another type fails its initialization, before any input")
    func wrongServicesFailInitialization() async throws {
        // What an erased factory (`LandManager(resolverServicesFactory:)`) can hand the keeper.
        let keeper = LandKeeper<ResolverValueState>(
            definition: makePriceLand().definition,
            resolverServices: NoServices(),
            initialState: ResolverValueState(),
            autoStartLoops: false,
            landID: "resolver-price:wrong"
        )
        let refusal = await #expect(throws: JoinError.self) {
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        }
        guard case .landShuttingDown? = refusal else {
            Issue.record("Expected landShuttingDown, got \(String(describing: refusal))")
            return
        }
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        }
        let registration = try #require(failure.underlying as? LandRegistrationError)
        #expect(registration.missingServices == nil)
        #expect(registration.wrongServices
            == "declared \(String(reflecting: PriceServices.self)), given \(String(reflecting: NoServices.self))")

        // The right type initializes.
        let right = LandKeeper<ResolverValueState>(
            definition: makePriceLand().definition,
            resolverServices: PriceServices(prices: [:]),
            initialState: ResolverValueState(),
            autoStartLoops: false,
            landID: "resolver-price:right"
        )
        try await right.join(playerID: p1, clientID: c1, sessionID: s1)
    }

    @Test("Registration without services refuses a services land; the schema's and a replay's checks don't")
    func registrationWithoutServicesRefuses() throws {
        let definition = makePriceLand().definition
        #expect(throws: LandRegistrationError.self) {
            try definition.validateForRegistration(context: LandRegistrationContext(servicesProvided: false))
        }
        try definition.validateForRegistration(context: LandRegistrationContext(servicesProvided: true))
        try definition.validateForRegistration(context: .encodingIndependent)
    }

    @Test("Two resolvers of one base type in one declaration are refused at registration")
    func duplicateBaseTypeRefused() throws {
        let definition = Land("resolver-duplicate", using: ResolverValueState.self) {
            Rules {
                HandleAction(PairAction.self, resolvers: { _, _, _ in (First(), First()) }) { _, _, _, _ in
                    ResolverValueAck(ok: true)
                }
            }
        }
        do {
            try definition.validateForRegistration(context: .encodingIndependent)
            Issue.record("Expected the land to be refused")
        } catch let error as LandRegistrationError {
            #expect(error.resolverDeclarations.count == 1)
            #expect(error.resolverDeclarations.first?.contains("two resolvers of type First both store their output as `first`") == true)
        }
    }

    @Test("Two resolver types that store their outputs under one name are refused, a skipped one too")
    func sharedOutputNameRefused() throws {
        // Without the refusal, the skipped `Shared` slot would read `SharedResolver`'s output.
        let definition = Land("resolver-shared-output", using: ResolverValueState.self) {
            Rules {
                HandleAction(
                    PairAction.self,
                    resolvers: { _, _, _ -> (Shared?, SharedResolver?) in (nil, SharedResolver()) }
                ) { _, _, _, _ in
                    ResolverValueAck(ok: true)
                }
            }
        }
        do {
            try definition.validateForRegistration(context: .encodingIndependent)
            Issue.record("Expected the land to be refused")
        } catch let error as LandRegistrationError {
            #expect(error.resolverDeclarations.count == 1)
            #expect(error.resolverDeclarations.first?.contains("resolvers Shared and SharedResolver both store their output as `shared`") == true)
        }
    }

    @Test("The ContextResolver groups refuse two types that store their outputs under one name")
    func contextResolverSharedOutputNameRefused() throws {
        let definition = Land("resolver-shared-output-join", using: ResolverValueState.self) {
            Rules {
                CanJoin(resolvers: (LegacyShared.self, LegacySharedResolver.self)) { _, session, _, _ in
                    .allow(playerID: PlayerID(session.playerID))
                }
                OnJoin(resolvers: (LegacyShared.self, LegacySharedResolver.self)) { _, _, _ in }
                OnLeave(resolvers: (LegacyShared.self, LegacySharedResolver.self)) { _, _, _ in }
            }
        }
        do {
            try definition.validateForRegistration(context: .encodingIndependent)
            Issue.record("Expected the land to be refused")
        } catch let error as LandRegistrationError {
            #expect(error.resolverDeclarations == ["CanJoin", "OnJoin", "OnLeave"].map {
                "\($0): resolvers LegacyShared and LegacySharedResolver both store their output as `legacyShared`; one declaration resolves each output once"
            })
        }
    }

    @Test("A resolver node built under other services and spliced in by hand is refused")
    func foreignServicesNodeRefused() throws {
        // The handler alone, out of its node: what a hand-built splice would put in a land.
        let resolving: ResolvingNode<AnyActionHandler<ResolverValueState>, PriceServices> =
            HandleAction(PriceAction.self, resolvers: { _, action, _ in Price(item: action.item) }) { _, _, _, _ in
                ResolverValueAck(ok: true)
            }
        let foreign = resolving.node
        let definition = Land("resolver-foreign", using: ResolverValueState.self) {
            Rules { foreign }
        }
        do {
            try definition.validateForRegistration(context: .encodingIndependent)
            Issue.record("Expected the land to be refused")
        } catch let error as LandRegistrationError {
            #expect(error.resolverDeclarations.count == 1)
            #expect(error.resolverDeclarations.first?.contains(String(reflecting: PriceServices.self)) == true)
        }
    }
}
