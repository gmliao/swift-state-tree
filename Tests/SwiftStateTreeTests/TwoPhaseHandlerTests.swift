// Tests/SwiftStateTreeTests/TwoPhaseHandlerTests.swift
//
// Two-phase handlers (#586): `validate` reads the state and may throw, `apply` writes and can't.
// A refused input writes nothing; each action, client-event and server-input type has one
// handler; the inputs refused live are recorded (record format 3.5) and compared in replay, on
// tickless lands (legacy and in-turn passes) and tick lands alike, by the engine and by the
// monitor's runner.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeReevaluationMonitor

@StateNodeBuilder
struct TwoPhaseState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct TwoPhaseAck: ResponsePayload {
    let total: Int
}

@Payload
struct TwoPhaseAddAction: ActionPayload {
    typealias Response = TwoPhaseAck
    let amount: Int
    /// Refused while `TwoPhaseRefusals` holds it: a test-controlled, non-deterministic
    /// `validate`, so live and replay can be made to decide differently.
    let key: Int
}

@Payload
struct TwoPhasePlanAction: ActionPayload {
    typealias Response = TwoPhaseAck
    let amount: Int
}

@Payload
struct TwoPhaseResolvedAction: ActionPayload {
    typealias Response = TwoPhaseAck
}

@Payload
struct TwoPhaseBumpEvent: ClientEventPayload {
    let amount: Int
}

@Payload
struct TwoPhaseInput: ServerInputPayload {
    let amount: Int
}

struct TwoPhaseRefused: Error, Equatable {
    let reason: String
}

struct TwoPhaseLimitOutput: ResolverOutput {
    let limit: Int
}

struct TwoPhaseLimitResolver: ContextResolver {
    typealias Output = TwoPhaseLimitOutput
    static func resolve(ctx: ResolverContext) async throws -> TwoPhaseLimitOutput {
        TwoPhaseLimitOutput(limit: 10)
    }
}

/// A read-only service `validate` may fetch.
struct TwoPhaseCatalog: ReadOnlyLandService {
    let maxAmount: Int
}

/// Keys whose `TwoPhaseAddAction` is refused (shared by parallel tests: each uses its own keys).
enum TwoPhaseRefusals {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: Set<Int> = []
    nonisolated(unsafe) private static var next = 1_000

    static func freshKey() -> Int { lock.withLock { next += 1; return next } }
    static func refuse(_ key: Int) { lock.withLock { _ = keys.insert(key) } }
    static func allow(_ key: Int) { lock.withLock { _ = keys.remove(key) } }
    static func isRefused(_ key: Int) -> Bool { lock.withLock { keys.contains(key) } }
}

private func makeTwoPhaseDefinition(tick: Bool) -> LandDefinition<TwoPhaseState> {
    let rules: LandRules<TwoPhaseState, NoServices> = Rules {
        HandleAction(TwoPhaseAddAction.self, validate: { (_: TwoPhaseState, action: TwoPhaseAddAction, _: ValidateContext) in
            if TwoPhaseRefusals.isRefused(action.key) { throw TwoPhaseRefused(reason: "key \(action.key)") }
        }, apply: { (state: inout TwoPhaseState, action: TwoPhaseAddAction, ctx: LandContext) in
            state.total += action.amount
            state.log.append("add:\(action.amount)")
            return TwoPhaseAck(total: state.total)
        })
        // The plan carries what validate computed; apply only writes it.
        HandleAction(TwoPhasePlanAction.self, validate: { (state: TwoPhaseState, action: TwoPhasePlanAction, ctx: ValidateContext) -> Int in
            let cap = ctx.services.get(TwoPhaseCatalog.self)?.maxAmount ?? Int.max
            guard action.amount <= cap else { throw TwoPhaseRefused(reason: "over cap") }
            return state.total + action.amount
        }, apply: { (state: inout TwoPhaseState, _: TwoPhasePlanAction, newTotal: Int, _: LandContext) in
            state.total = newTotal
            state.log.append("plan:\(newTotal)")
            return TwoPhaseAck(total: newTotal)
        })
        // validate reads a resolver's output from its context.
        HandleAction(TwoPhaseResolvedAction.self, resolvers: TwoPhaseLimitResolver.self, validate: {
            (state: TwoPhaseState, _: TwoPhaseResolvedAction, ctx: ValidateContext) -> Int in
            let output: TwoPhaseLimitOutput? = ctx.twoPhaseLimit
            guard let limit = output?.limit else { throw TwoPhaseRefused(reason: "no resolver output") }
            guard state.total < limit else { throw TwoPhaseRefused(reason: "at limit") }
            return limit
        }, apply: { (state: inout TwoPhaseState, _: TwoPhaseResolvedAction, limit: Int, _: LandContext) in
            state.total = limit
            return TwoPhaseAck(total: limit)
        })
        HandleEvent(TwoPhaseBumpEvent.self, validate: { (_: TwoPhaseState, event: TwoPhaseBumpEvent, _: ValidateContext) in
            if event.amount < 0 { throw TwoPhaseRefused(reason: "negative bump") }
        }, apply: { (state: inout TwoPhaseState, event: TwoPhaseBumpEvent, _: LandContext) in
            state.total += event.amount
        })
        HandleServerInput(TwoPhaseInput.self, validate: { (_: TwoPhaseState, input: TwoPhaseInput, _: ValidateContext) in
            if input.amount < 0 { throw TwoPhaseRefused(reason: "negative input") }
        }, apply: { (state: inout TwoPhaseState, input: TwoPhaseInput, _: LandContext) in
            state.total += input.amount
            state.log.append("input:\(input.amount)")
        })
    }
    if tick {
        return Land("two-phase-tick", using: TwoPhaseState.self) {
            ClientEvents { Register(TwoPhaseBumpEvent.self) }
            rules
            Lifetime {
                // Hourly and stepped by hand: no real tick runs during a test.
                Tick(every: .seconds(3600)) { (_: inout TwoPhaseState, _: LandContext) in }
            }
        }
    }
    return Land("two-phase-tickless", using: TwoPhaseState.self) {
        ClientEvents { Register(TwoPhaseBumpEvent.self) }
        rules
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// Where an input is applied: a tickless land's legacy pass, its in-turn input turn (a transport
/// that runs the sync phase in the turn, whatever the adapter's mode), or a tick.
enum TwoPhaseMode: String, CaseIterable, Sendable {
    case tickless, ticklessInTurn, tick
    var tick: Bool { self == .tick }
}

/// A transport that runs the sync phase in the keeper's turn and sends nothing.
private final class TwoPhaseInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool,
        recording: InTurnSyncRecording?
    ) -> InTurnSyncOutput {
        InTurnSyncOutput(includeSync ? .committed(clearDirtyFlags: true) : .notRequested)
    }
    func waitForWriterDrainForInTurnSync() async {}
}

private func makeTwoPhaseKeeper(
    _ mode: TwoPhaseMode,
    recording: Bool = false,
    services: LandServices = LandServices()
) async throws -> LandKeeper<TwoPhaseState> {
    try await makeTwoPhaseKeeper(tick: mode.tick, inTurn: mode == .ticklessInTurn, recording: recording, services: services)
}

private func makeTwoPhaseKeeper(
    tick: Bool,
    inTurn: Bool = false,
    recording: Bool = false,
    services: LandServices = LandServices()
) async throws -> LandKeeper<TwoPhaseState> {
    let definition = makeTwoPhaseDefinition(tick: tick)
    // One land ID per keeper: parallel tests must not share a recorder spool.
    let landID = "\(definition.id):\(UUID().uuidString)"
    let keeper = LandKeeper<TwoPhaseState>(
        definition: definition,
        initialState: TwoPhaseState(),
        services: services,
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        landID: landID,
        transport: inTurn ? TwoPhaseInTurnTransport() : nil
    )
    // The transport decides: in-turn whatever the adapter's mode.
    #expect(await keeper.isUsingInTurnSync() == inTurn)
    if recording {
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: definition.id,
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: definition.id,
            rngSeed: DeterministicSeed.fromLandID(landID),
            version: ReevaluationRecordVersion.current
        ))
    }
    try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
    return keeper
}

private func send(_ keeper: LandKeeper<TwoPhaseState>, _ action: any ActionPayload) async throws -> AnyCodable {
    try await keeper.handleActionEnvelope(
        ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action)),
        playerID: p1, clientID: c1, sessionID: s1
    )
}

/// The ack's total in an action's response, nil when there is none.
private func ackTotal(_ response: AnyCodable) -> Int? {
    let ack = (response.base as? TwoPhaseAck) ?? ((response.base as? AnyCodable)?.base as? TwoPhaseAck)
    return ack?.total
}

/// Sends `action` and applies it: a tick land needs a tick to apply its inputs.
private func sendAndApply(_ keeper: LandKeeper<TwoPhaseState>, tick: Bool, _ action: any ActionPayload) async -> Result<AnyCodable, any Error> {
    let result: Result<AnyCodable, any Error>
    do { result = .success(try await send(keeper, action)) } catch { result = .failure(error) }
    if tick { await keeper.stepTickOnce() }
    return result
}

/// The record's JSON view at a temporary path (removed by the caller), after `edit` changed it.
private func saveJSONRecord(
    _ keeper: LandKeeper<TwoPhaseState>,
    edit: (inout [String: Any]) throws -> Void = { _ in }
) async throws -> String {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory.appendingPathComponent("two-phase-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    try ReevaluationRecordFile.convertToJSONViewForTesting(atPath: path)
    let jsonPath = path + ".json"
    try FileManager.default.moveItem(atPath: path, toPath: jsonPath)
    var object = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: jsonPath))) as? [String: Any])
    try edit(&object)
    try JSONSerialization.data(withJSONObject: object).write(to: URL(fileURLWithPath: jsonPath))
    return jsonPath
}

/// The tick of the frame that recorded input `sequence`.
private func tickOf(_ sequence: Int64, in path: String) async throws -> Int64 {
    let json = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? JSONReevaluationSource)
    return try #require(await json.getAllFrames().first { $0.actions.contains { $0.sequence == sequence } }).tickId
}

/// The monitor's runner (admin and monitor replays) over the whole record: its pass mismatches.
/// `initialState` picks the initializer that takes the state (each reads the record's version).
private func runnerMismatches(_ path: String, tick: Bool, initialState: Bool = false) async throws -> [Int64: String] {
    let definition = makeTwoPhaseDefinition(tick: tick)
    let runner = initialState
        ? try await ConcreteReevaluationRunner(definition: definition, initialState: TwoPhaseState(), recordFilePath: path)
        : try await ConcreteReevaluationRunner(definition: definition, recordFilePath: path)
    var mismatches: [Int64: String] = [:]
    while let step = try await runner.step() {
        if let mismatch = step.recordedPassMismatch { mismatches[step.tickId] = mismatch }
    }
    return mismatches
}

private func replay(_ path: String, tick: Bool) async throws -> ReevaluationEngine.RunResult {
    try await ReevaluationEngine.run(
        definition: makeTwoPhaseDefinition(tick: tick),
        initialState: TwoPhaseState(),
        recordFilePath: path
    )
}

/// Every frame's and pass's `rejected` lists, edited by `change`.
private func editRejected(_ object: inout [String: Any], tick: Bool, _ change: ([Int64]) -> [Int64]?) throws {
    var frames = try #require(object["tickFrames"] as? [[String: Any]])
    for index in frames.indices {
        if tick {
            guard !((frames[index]["actions"] as? [Any])?.isEmpty ?? true) else { continue }
            let current = (frames[index]["rejected"] as? [NSNumber])?.map(\.int64Value) ?? []
            frames[index]["rejected"] = change(current)
        } else {
            guard var passes = frames[index]["passes"] as? [[String: Any]] else { continue }
            for p in passes.indices where !((passes[p]["inputs"] as? [Any])?.isEmpty ?? true) {
                let current = (passes[p]["rejected"] as? [NSNumber])?.map(\.int64Value) ?? []
                passes[p]["rejected"] = change(current)
            }
            frames[index]["passes"] = passes
        }
    }
    object["tickFrames"] = frames
}

@Suite("Two-phase handlers: validate, then apply (#586)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct TwoPhaseHandlerTests {
    @Test("A refusing validate writes nothing and isn't run again; its caller gets the error (a tick land's its intake ACK); the next input applies", arguments: TwoPhaseMode.allCases)
    func refusedActionWritesNothing(mode: TwoPhaseMode) async throws {
        let tick = mode.tick
        let keeper = try await makeTwoPhaseKeeper(mode)
        let key = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(key)
        defer { TwoPhaseRefusals.allow(key) }
        let refused = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        let state = await keeper.currentState()
        #expect(state.total == 0 && state.log.isEmpty, "a refused input wrote: \(state)")
        if tick {
            // Returned at intake, before the tick ran: the ACK, never a handler's response.
            #expect((try? refused.get())?.base is Void, "a tick land's caller keeps its intake ACK: \(refused)")
        } else {
            #expect(throws: TwoPhaseRefused(reason: "key \(key)")) { try refused.get() }
        }
        // Allowed from now on: a refused input left in the queue would apply in the next tick or
        // pass and show in the total.
        TwoPhaseRefusals.allow(key)
        if tick { await keeper.stepTickOnce() }
        #expect(await keeper.currentState().total == 0, "the refused input ran again")
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 2, key: TwoPhaseRefusals.freshKey()))
        #expect(await keeper.currentState().total == 2)
    }

    @Test("validate's plan reaches apply, and validate reads a read-only service")
    func planAndService() async throws {
        var services = LandServices()
        services.register(TwoPhaseCatalog(maxAmount: 50), as: TwoPhaseCatalog.self)
        let keeper = try await makeTwoPhaseKeeper(tick: false, services: services)
        #expect(ackTotal(try await send(keeper, TwoPhasePlanAction(amount: 7))) == 7)
        await #expect(throws: TwoPhaseRefused(reason: "over cap")) { _ = try await send(keeper, TwoPhasePlanAction(amount: 51)) }
        #expect(await keeper.currentState().log == ["plan:7"])
    }

    @Test("validate reads a resolver's output from its context")
    func resolverOutputInValidate() async throws {
        let keeper = try await makeTwoPhaseKeeper(tick: false)
        #expect(ackTotal(try await send(keeper, TwoPhaseResolvedAction())) == 10)
        await #expect(throws: TwoPhaseRefused(reason: "at limit")) { _ = try await send(keeper, TwoPhaseResolvedAction()) }
    }

    @Test("A refused client event and server input write nothing; the land goes on", arguments: [false, true])
    func refusedEventAndServerInput(tick: Bool) async throws {
        let keeper = try await makeTwoPhaseKeeper(tick: tick)
        let bump = { (amount: Int) in
            AnyClientEvent(TwoPhaseBumpEvent(amount: amount))
        }
        try? await keeper.handleClientEvent(bump(-1), playerID: p1, clientID: c1, sessionID: s1)
        _ = await keeper.submitServerInput(TwoPhaseInput(amount: -3))
        try? await keeper.handleClientEvent(bump(4), playerID: p1, clientID: c1, sessionID: s1)
        _ = await keeper.submitServerInput(TwoPhaseInput(amount: 6))
        if tick { await keeper.stepTickOnce() }
        await keeper.waitForInFlightWorkForTesting()
        let state = await keeper.currentState()
        #expect(state.total == 10)
        #expect(state.log == ["input:6"])
    }

    // MARK: One handler per type (M1)

    @Test("Two handlers for one client event type are refused at registration, naming both sites")
    func duplicateEventHandlerRefused() throws {
        let definition = Land("dup-event", using: TwoPhaseState.self) {
            ClientEvents { Register(TwoPhaseBumpEvent.self) }
            Rules {
                HandleEvent(TwoPhaseBumpEvent.self) { (_: inout TwoPhaseState, _: TwoPhaseBumpEvent, _: LandContext) in }
                HandleEvent(TwoPhaseBumpEvent.self) { (_: inout TwoPhaseState, _: TwoPhaseBumpEvent, _: LandContext) in }
            }
        }
        #expect(definition.eventHandlers.count == 1, "the first is kept")
        do {
            try definition.validateForRegistration(context: .encodingIndependent)
            Issue.record("a land with two handlers for one event type was registered")
        } catch let error as LandRegistrationError {
            let duplicate = try #require(error.duplicateHandlers.first)
            #expect(error.duplicateHandlers.count == 1)
            #expect(duplicate.kind == "client event")
            #expect(duplicate.typeName == String(describing: TwoPhaseBumpEvent.self))
            let first = try #require(duplicate.firstSite), second = try #require(duplicate.duplicateSite)
            #expect(first.hasPrefix("SwiftStateTreeTests/TwoPhaseHandlerTests.swift:"))
            #expect(first != second)
            #expect(error.description.contains(first) && error.description.contains(second))
        }
    }

    @Test("Two handlers for one server input type are refused at registration")
    func duplicateServerInputHandlerRefused() throws {
        let definition = Land("dup-input", using: TwoPhaseState.self) {
            Rules {
                HandleServerInput(TwoPhaseInput.self) { (_: inout TwoPhaseState, _: TwoPhaseInput, _: LandContext) in }
                HandleServerInput(TwoPhaseInput.self) { (_: inout TwoPhaseState, _: TwoPhaseInput, _: LandContext) in }
            }
        }
        let error = try #require(throws: LandRegistrationError.self) {
            try definition.validateForRegistration(context: .encodingIndependent)
        }
        #expect(error.duplicateHandlers.map(\.kind) == ["server input"])
        #expect(error.duplicateHandlers.map(\.typeName) == [String(describing: TwoPhaseInput.self)])
    }

    @Test("Two handlers for one action type, in any forms, are refused at registration, naming both sites")
    func duplicateActionHandlerRefused() throws {
        let definition = Land("dup-action", using: TwoPhaseState.self) {
            Rules {
                HandleAction(TwoPhasePlanAction.self) { (state: inout TwoPhaseState, action: TwoPhasePlanAction, _: LandContext) in
                    TwoPhaseAck(total: state.total)
                }
                HandleAction(TwoPhasePlanAction.self, validate: { (_: TwoPhaseState, _: TwoPhasePlanAction, _: ValidateContext) in
                }, apply: { (state: inout TwoPhaseState, _: TwoPhasePlanAction, _: LandContext) in
                    TwoPhaseAck(total: state.total)
                })
            }
        }
        #expect(definition.actionHandlers.count == 1, "the first is kept")
        let error = try #require(throws: LandRegistrationError.self) {
            try definition.validateForRegistration(context: .encodingIndependent)
        }
        let duplicate = try #require(error.duplicateHandlers.first)
        #expect(error.duplicateHandlers.map(\.kind) == ["action"])
        #expect(duplicate.typeName == String(describing: TwoPhasePlanAction.self))
        let first = try #require(duplicate.firstSite), second = try #require(duplicate.duplicateSite)
        #expect(first.hasPrefix("SwiftStateTreeTests/TwoPhaseHandlerTests.swift:") && first != second)
    }

    @Test("AnyActionHandler's public two-stage init answers with the action's Response and is refused as a duplicate too")
    func erasedActionHandlerInit() async throws {
        let handler = AnyActionHandler<TwoPhaseState>(TwoPhasePlanAction.self, validate: { (state: TwoPhaseState, action: TwoPhasePlanAction, _: ValidateContext) -> Int in
            guard action.amount > 0 else { throw TwoPhaseRefused(reason: "not positive") }
            return state.total + action.amount
        }, apply: { (state: inout TwoPhaseState, _: TwoPhasePlanAction, total: Int, _: LandContext) in
            state.total = total
            return TwoPhaseAck(total: total)
        })
        #expect(handler.getResponseType() == TwoPhaseAck.self)
        #expect(handler.site?.hasPrefix("SwiftStateTreeTests/TwoPhaseHandlerTests.swift:") == true)
        let definition = Land("erased-action", using: TwoPhaseState.self) {
            Rules {
                handler
                HandleAction(TwoPhasePlanAction.self) { (state: inout TwoPhaseState, _: TwoPhasePlanAction, _: LandContext) in
                    TwoPhaseAck(total: state.total)
                }
            }
        }
        let error = try #require(throws: LandRegistrationError.self) {
            try definition.validateForRegistration(context: .encodingIndependent)
        }
        #expect(error.duplicateHandlers.map(\.kind) == ["action"])
    }

    @Test("A keeper built without registration refuses duplicate handlers of every kind at initialization")
    func duplicateHandlersFailUnregisteredKeeper() async throws {
        let definition = Land("dup-keeper", using: TwoPhaseState.self) {
            ClientEvents { Register(TwoPhaseBumpEvent.self) }
            Rules {
                HandleAction(TwoPhasePlanAction.self) { (state: inout TwoPhaseState, _: TwoPhasePlanAction, _: LandContext) in TwoPhaseAck(total: state.total) }
                HandleAction(TwoPhasePlanAction.self) { (state: inout TwoPhaseState, _: TwoPhasePlanAction, _: LandContext) in TwoPhaseAck(total: -1) }
                HandleEvent(TwoPhaseBumpEvent.self) { (state: inout TwoPhaseState, _: TwoPhaseBumpEvent, _: LandContext) in state.total += 1 }
                HandleEvent(TwoPhaseBumpEvent.self) { (state: inout TwoPhaseState, _: TwoPhaseBumpEvent, _: LandContext) in state.total += 100 }
                HandleServerInput(TwoPhaseInput.self) { (state: inout TwoPhaseState, _: TwoPhaseInput, _: LandContext) in state.total += 1 }
                HandleServerInput(TwoPhaseInput.self) { (state: inout TwoPhaseState, _: TwoPhaseInput, _: LandContext) in state.total += 100 }
            }
        }
        let keeper = LandKeeper<TwoPhaseState>(definition: definition, initialState: TwoPhaseState(), autoStartLoops: false)
        let failure = try await #require(throws: LandInitializationError.self) {
            try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        }
        let registration = try #require(failure.underlying as? LandRegistrationError)
        #expect(registration.landType == "dup-keeper")
        #expect(registration.sync == nil)
        #expect(registration.duplicateHandlers.map(\.kind) == ["action", "client event", "server input"])
    }

    // MARK: The rejected marker (D1)

    @Test("A live refusal is recorded: on the pass of a tickless land (legacy or in-turn), on the frame of a tick land", arguments: TwoPhaseMode.allCases)
    func rejectedIsRecorded(mode: TwoPhaseMode) async throws {
        let tick = mode.tick
        let keeper = try await makeTwoPhaseKeeper(mode, recording: true)
        let key = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(key)
        defer { TwoPhaseRefusals.allow(key) }
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 1, key: TwoPhaseRefusals.freshKey()))
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        let refused = try #require(frames.flatMap(\.actions).last).sequence
        if tick {
            #expect(frames.flatMap(\.rejected) == [refused])
            #expect(frames.flatMap(\.passes).isEmpty)
        } else {
            #expect(frames.flatMap(\.rejected).isEmpty)
            #expect(frames.flatMap(\.passes).compactMap(\.rejected) == [[refused]])
        }
        // Replay refuses it the same way: no mismatch.
        let path = try await saveJSONRecord(keeper)
        defer { try? FileManager.default.removeItem(atPath: path) }
        TwoPhaseRefusals.refuse(key)
        #expect(try await replay(path, tick: tick).recordedPassMismatches.isEmpty)
    }

    @Test("Two refusals in one tick are both recorded on its frame, in order, and replay matches")
    func twoRefusalsInOneTick() async throws {
        let keeper = try await makeTwoPhaseKeeper(tick: true, recording: true)
        let first = TwoPhaseRefusals.freshKey(), second = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(first)
        TwoPhaseRefusals.refuse(second)
        defer { TwoPhaseRefusals.allow(first); TwoPhaseRefusals.allow(second) }
        _ = try await send(keeper, TwoPhaseAddAction(amount: 1, key: first))
        _ = try await send(keeper, TwoPhaseAddAction(amount: 2, key: TwoPhaseRefusals.freshKey()))
        _ = try await send(keeper, TwoPhaseAddAction(amount: 4, key: second))
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().total == 2)
        await keeper.waitForRecorderSubmissionsForTesting()
        let frames = await (try #require(await keeper.getReevaluationRecorder())).getAllFrames()
        let actions = frames.flatMap(\.actions).map(\.sequence)
        #expect(actions.count == 3)
        #expect(frames.flatMap(\.rejected) == [actions[0], actions[2]])
        let path = try await saveJSONRecord(keeper)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(try await replay(path, tick: true).recordedPassMismatches.isEmpty)
    }

    @Test("Rejected live, applied in replay: reported for the input's tick, naming its sequence", arguments: TwoPhaseMode.allCases)
    func rejectedLiveAppliedInReplay(mode: TwoPhaseMode) async throws {
        let tick = mode.tick
        let keeper = try await makeTwoPhaseKeeper(mode, recording: true)
        let key = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(key)
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        let path = try await saveJSONRecord(keeper)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let json = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? JSONReevaluationSource)
        let sequence = try #require(await json.getAllFrames().flatMap(\.actions).last).sequence
        let tickId = try await tickOf(sequence, in: path)
        TwoPhaseRefusals.allow(key)
        let mismatches = try await replay(path, tick: tick).recordedPassMismatches
        #expect(Array(mismatches.keys) == [tickId], "\(mismatches)")
        #expect(mismatches[tickId]?.contains("input \(sequence) was rejected live and applied in replay") == true, "\(mismatches)")
    }

    @Test("Applied live, rejected in replay: reported for the input's tick, naming its sequence", arguments: TwoPhaseMode.allCases)
    func appliedLiveRejectedInReplay(mode: TwoPhaseMode) async throws {
        let tick = mode.tick
        let keeper = try await makeTwoPhaseKeeper(mode, recording: true)
        let key = TwoPhaseRefusals.freshKey()
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        let path = try await saveJSONRecord(keeper)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let json = try #require(try ReevaluationRecordFile.openSource(filePath: path) as? JSONReevaluationSource)
        let sequence = try #require(await json.getAllFrames().flatMap(\.actions).last).sequence
        let tickId = try await tickOf(sequence, in: path)
        TwoPhaseRefusals.refuse(key)
        defer { TwoPhaseRefusals.allow(key) }
        let mismatches = try await replay(path, tick: tick).recordedPassMismatches
        #expect(Array(mismatches.keys) == [tickId], "\(mismatches)")
        #expect(mismatches[tickId]?.contains("input \(sequence) was applied live and rejected in replay") == true, "\(mismatches)")
    }

    @Test("The monitor's runner compares the rejected list too (its 3.5 gate)", arguments: [false, true])
    func runnerComparesRejected(tick: Bool) async throws {
        let keeper = try await makeTwoPhaseKeeper(tick: tick, recording: true)
        let key = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(key)
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        let path = try await saveJSONRecord(keeper)
        defer { try? FileManager.default.removeItem(atPath: path) }
        // Refused again in replay: the runner reports nothing.
        #expect(try await runnerMismatches(path, tick: tick).isEmpty)
        TwoPhaseRefusals.allow(key)
        let mismatches = try await runnerMismatches(path, tick: tick)
        #expect(mismatches.count == 1, "\(mismatches)")
        #expect(mismatches.values.first?.contains("was rejected live and applied in replay") == true, "\(mismatches)")
    }

    @Test("A malformed rejected list (an unknown or repeated sequence) is reported", arguments: [false, true])
    func malformedRejectedIsReported(tick: Bool) async throws {
        for (name, change) in [
            ("unknown", { (_: [Int64]) -> [Int64]? in [999_999] }),
            ("repeated", { (_: [Int64]) -> [Int64]? in nil }),
        ] {
            let keeper = try await makeTwoPhaseKeeper(tick: tick, recording: true)
            let key = TwoPhaseRefusals.freshKey()
            TwoPhaseRefusals.refuse(key)
            defer { TwoPhaseRefusals.allow(key) }
            _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
            let path = try await saveJSONRecord(keeper) { object in
                try editRejected(&object, tick: tick) { current in
                    name == "repeated" ? current + current : change(current)
                }
            }
            defer { try? FileManager.default.removeItem(atPath: path) }
            let mismatches = try await replay(path, tick: tick).recordedPassMismatches
            let expected = name == "repeated" ? "as rejected more than once" : "which is not one of its inputs"
            #expect(mismatches.values.contains { $0.contains(expected) }, "\(name): \(mismatches)")
        }
    }

    /// A 3.4 record has no rejected list, and no schema fingerprint either: replay refuses it
    /// before the first step (#521 D15), through the engine and both runner initializers, rather
    /// than replaying it without the comparison.
    @Test("A 3.4 record has no rejected list, and is refused as having no schema fingerprint", arguments: [false, true])
    func olderRecordIsNotCompared(tick: Bool) async throws {
        let keeper = try await makeTwoPhaseKeeper(tick: tick, recording: true)
        let key = TwoPhaseRefusals.freshKey()
        TwoPhaseRefusals.refuse(key)
        defer { TwoPhaseRefusals.allow(key) }
        _ = await sendAndApply(keeper, tick: tick, TwoPhaseAddAction(amount: 5, key: key))
        // As a 3.4 writer wrote it: no rejected lists, version 3.4 (the fingerprint, which a 3.4
        // writer didn't write, is dropped too).
        let path = try await saveJSONRecord(keeper) { object in
            try editRejected(&object, tick: tick) { _ in nil }
            var metadata = try #require(object["recordMetadata"] as? [String: Any])
            metadata["version"] = "3.4"
            metadata["schemaFingerprint"] = nil
            object["recordMetadata"] = metadata
        }
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        #expect(try await source.getMetadata().version == "3.4")
        await #expect(throws: ReevaluationRecordFingerprintError.missing(recordedVersion: "3.4")) {
            _ = try await replay(path, tick: tick)
        }
        // The runner's gate too, through both of its initializers.
        for initialState in [false, true] {
            do {
                _ = try await runnerMismatches(path, tick: tick, initialState: initialState)
                Issue.record("initialState \(initialState): expected the runner to refuse the record")
            } catch ReevaluationReplayCompatibilityError.schemaFingerprintMissing(let recorded) {
                #expect(recorded == "3.4")
            }
        }
    }
}
