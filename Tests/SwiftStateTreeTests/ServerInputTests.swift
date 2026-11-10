// Tests/SwiftStateTreeTests/ServerInputTests.swift
//
// Server-originated turn inputs (#387): `LandKeeper.submitServerInput` sequences an input at
// submit, the keeper applies it in a turn with the system identity, records it, and replay
// reproduces it from the record. Interleavings are forced with freezes and hand-stepped ticks,
// never timing.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ServerInputTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

struct SIProgress: ServerInputPayload {
    let tag: String
}

struct SIFailing: ServerInputPayload {
    let tag: String
}

struct SIUndeclared: ServerInputPayload {
    let tag: String
}

/// A payload whose live value differs from its record form unless live applies the record
/// form: a fractional `Date` (the record holds whole seconds) and a whole `Double`.
struct SIDated: ServerInputPayload {
    let at: Date
    let ratio: Double
    let count: Int
}

/// The canonical record encoding refuses a `Set`.
struct SIUnencodable: ServerInputPayload {
    let ids: Set<Int>
}

/// A different type with the declared type's name: never the declared one.
enum SIElsewhere {
    struct SIProgress: ServerInputPayload {
        let tag: String
    }
}

/// Arrays nested `depth` deep, for the record's depth limit.
struct SIDeep: ServerInputPayload {
    let depth: Int

    init(depth: Int) { self.depth = depth }

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        for _ in 1..<depth { container = container.nestedUnkeyedContainer() }
    }

    init(from decoder: Decoder) throws {
        var container = try decoder.unkeyedContainer()
        var depth = 1
        while !container.isAtEnd {
            container = try container.nestedUnkeyedContainer()
            depth += 1
        }
        self.depth = depth
    }
}

@Payload
struct SINoteEvent: ClientEventPayload {
    let tag: String
}

/// Emitted with the log after each applied input, so a tickless replay (no state hash) that
/// misses or reorders an input fails on the events.
@Payload
struct SILogged: ServerEventPayload {
    let entry: String
    let length: Int
}

struct SIError: Error {}

/// The submitter a handler saw, taken out of the land by a test.
final class SISubmitterBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: ServerInputSubmitter?
    var value: ServerInputSubmitter? {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

private func appendEntry(_ entry: String, to state: inout ServerInputTestState, ctx: LandContext) {
    state.log.append(entry)
    ctx.emitEvent(SILogged(entry: entry, length: state.log.count), to: .all)
}

private func makeDefinition(ticking: Bool, box: SISubmitterBox? = nil) -> LandDefinition<ServerInputTestState> {
    let id = ticking ? "server-input-tick" : "server-input-tickless"
    if ticking {
        return Land(id, using: ServerInputTestState.self) {
            ClientEvents { Register(SINoteEvent.self) }
            ServerEvents { Register(SILogged.self) }
            Rules {
                OnJoin { (_: inout ServerInputTestState, ctx: LandContext) in box?.value = ctx.serverInputs }
                HandleEvent(SINoteEvent.self) { (state: inout ServerInputTestState, event: SINoteEvent, ctx: LandContext) in
                    appendEntry("client:\(event.tag)", to: &state, ctx: ctx)
                }
                HandleServerInput(SIProgress.self) { (state: inout ServerInputTestState, input: SIProgress, ctx: LandContext) in
                    appendEntry("server:\(input.tag):\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
                }
                HandleServerInput(SIFailing.self) { (state: inout ServerInputTestState, input: SIFailing, ctx: LandContext) in
                    appendEntry("failing:\(input.tag)", to: &state, ctx: ctx)
                    throw SIError()
                }
                HandleServerInput(SIDated.self) { (state: inout ServerInputTestState, input: SIDated, ctx: LandContext) in
                    appendEntry("dated:\(input.at.timeIntervalSince1970):\(input.ratio):\(input.count)", to: &state, ctx: ctx)
                }
                HandleServerInput(SIUnencodable.self) { (_: inout ServerInputTestState, _: SIUnencodable, _: LandContext) in }
                HandleServerInput(SIDeep.self) { (state: inout ServerInputTestState, input: SIDeep, ctx: LandContext) in
                    appendEntry("deep:\(input.depth)", to: &state, ctx: ctx)
                }
            }
            Lifetime {
                // Hourly and stepped by hand: no real tick runs during a test.
                Tick(every: .seconds(3600)) { (_: inout ServerInputTestState, _: LandContext) in }
            }
        }
    }
    return Land(id, using: ServerInputTestState.self) {
        ClientEvents { Register(SINoteEvent.self) }
        ServerEvents { Register(SILogged.self) }
        Rules {
            OnJoin { (_: inout ServerInputTestState, ctx: LandContext) in box?.value = ctx.serverInputs }
            HandleEvent(SINoteEvent.self) { (state: inout ServerInputTestState, event: SINoteEvent, ctx: LandContext) in
                appendEntry("client:\(event.tag)", to: &state, ctx: ctx)
            }
            HandleServerInput(SIProgress.self) { (state: inout ServerInputTestState, input: SIProgress, ctx: LandContext) in
                appendEntry("server:\(input.tag):\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
            }
        }
    }
}

/// The tick land without any `HandleServerInput`: replaying a record that holds server inputs
/// with it must fail.
private func makeTickDefinitionWithoutServerInputs() -> LandDefinition<ServerInputTestState> {
    Land("server-input-tick", using: ServerInputTestState.self) {
        ClientEvents { Register(SINoteEvent.self) }
        ServerEvents { Register(SILogged.self) }
        Rules {
            HandleEvent(SINoteEvent.self) { (state: inout ServerInputTestState, event: SINoteEvent, ctx: LandContext) in
                appendEntry("client:\(event.tag)", to: &state, ctx: ctx)
            }
        }
        Lifetime {
            Tick(every: .seconds(3600)) { (_: inout ServerInputTestState, _: LandContext) in }
        }
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")

/// Reports in-turn sync for every keeper, so a tickless keeper attached to it applies inputs in
/// input turns (`usesInTurnSync`) whatever `IN_TURN_SYNC` says. Counts the server events each
/// path delivered: in a turn's sync phase, or through the legacy send.
private final class SIInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var inTurn = 0
    private var legacy = 0
    var counts: (inTurn: Int, legacy: Int) { lock.withLock { (inTurn, legacy) } }
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {
        lock.withLock { legacy += 1 }
    }
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        lock.withLock { inTurn += events.count }
        return includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

/// Counts the keeper's input drain ends (its in-turn probe), so a test can wait for a drain
/// that is running to finish without polling.
private final class SIDrainEnds: @unchecked Sendable {
    private let lock = NSLock()
    private var ends = 0
    private var waiters: [(after: Int, continuation: CheckedContinuation<Void, Never>)] = []

    var count: Int { lock.withLock { ends } }

    func signal() {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            ends += 1
            let ready = waiters.filter { ends > $0.after }.map(\.continuation)
            waiters.removeAll { ends > $0.after }
            return ready
        }
        ready.forEach { $0.resume() }
    }

    /// Returns once more than `after` drains have ended.
    func wait(after: Int) async {
        await withCheckedContinuation { continuation in
            let now = lock.withLock { () -> Bool in
                if ends > after { return true }
                waiters.append((after, continuation))
                return false
            }
            if now { continuation.resume() }
        }
    }

    /// Waits until `keeper` has no input drain running. Read the count first: a drain that
    /// ends after the read is then counted, and one that ended before it isn't scheduled.
    func waitForIdle<S: StateNodeProtocol>(_ keeper: LandKeeper<S>) async {
        let before = count
        if await keeper.inputDrainScheduledForTesting() { await wait(after: before) }
    }
}

private func makeKeeper(
    ticking: Bool,
    transport: SIInTurnTransport? = nil,
    box: SISubmitterBox? = nil
) async throws -> LandKeeper<ServerInputTestState> {
    let definition = makeDefinition(ticking: ticking, box: box)
    let keeper = LandKeeper<ServerInputTestState>(
        definition: definition,
        initialState: ServerInputTestState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        transport: transport
    )
    // One land ID per keeper: parallel tests must not share a recorder spool.
    let landID = "\(definition.id):\(UUID().uuidString)"
    await keeper.setLandID(landID)
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
    return keeper
}

private func saveRecord(_ keeper: LandKeeper<ServerInputTestState>, name: String) async throws -> String {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    return path
}

private func allRecordedServerInputs(_ keeper: LandKeeper<ServerInputTestState>) async throws -> [ReevaluationRecordedServerInput] {
    await keeper.waitForRecorderSubmissionsForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    return await recorder.getAllFrames().flatMap(\.serverInputs)
}

private func accepted(_ outcome: ServerInputOutcome, sourceLocation: SourceLocation = #_sourceLocation) throws -> Int64 {
    guard case let .accepted(sequence) = outcome else {
        Issue.record("expected accepted, got \(outcome)", sourceLocation: sourceLocation)
        throw SIError()
    }
    return sequence
}

@Suite("Server-originated turn inputs (#387)", .timeLimit(.minutes(1)))
struct ServerInputTests {
    @Test("A tick land applies a server input in its next tick, with the system identity, and records it")
    func appliedInNextTickWithSystemIdentity() async throws {
        let keeper = try await makeKeeper(ticking: true)
        let sequence = try accepted(await keeper.submitServerInput(SIProgress(tag: "a")))
        #expect(await keeper.currentState().log.isEmpty, "applied in a turn, not at submit")
        #expect(await keeper.serverInputsInFlightForTesting() == 1)

        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["server:a:\(LandContext.systemPlayerID.rawValue)"])
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        let recorded = try await allRecordedServerInputs(keeper)
        #expect(recorded.map(\.sequence) == [sequence])
        #expect(recorded.first?.typeIdentifier == String(describing: SIProgress.self))
        #expect(recorded.first?.kind == "serverInput")
    }

    @Test("Client and server inputs submitted in one tick apply in submission order")
    func interleavesInSubmissionOrder() async throws {
        let keeper = try await makeKeeper(ticking: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        try await keeper.handleClientEvent(AnyClientEvent(SINoteEvent(tag: "1")), playerID: p1, clientID: c1, sessionID: s1)
        let serverSequence = try accepted(await keeper.submitServerInput(SIProgress(tag: "2")))
        try await keeper.handleClientEvent(AnyClientEvent(SINoteEvent(tag: "3")), playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()

        let system = LandContext.systemPlayerID.rawValue
        #expect(await keeper.currentState().log == ["client:1", "server:2:\(system)", "client:3"])
        // The sequence is taken at submit, between the two client events.
        await keeper.waitForRecorderSubmissionsForTesting()
        let recorder = try #require(await keeper.getReevaluationRecorder())
        let clientSequences = await recorder.getAllFrames().flatMap(\.clientEvents).map(\.sequence)
        #expect(clientSequences.count == 2)
        #expect(clientSequences.allSatisfy { $0 != serverSequence })
        #expect(clientSequences.min()! < serverSequence && serverSequence < clientSequences.max()!)
    }

    @Test("A throwing handler fails that server input alone: its write is kept, it is recorded, and replay matches")
    func throwingHandlerFailsOnlyItsInput() async throws {
        let keeper = try await makeKeeper(ticking: true)
        let failing = try accepted(await keeper.submitServerInput(SIFailing(tag: "x")))
        let next = try accepted(await keeper.submitServerInput(SIProgress(tag: "y")))
        await keeper.stepTickOnce()
        // The write before the throw is kept (no per-input savepoint, #87); the next input runs.
        #expect(await keeper.currentState().log == ["failing:x", "server:y:\(LandContext.systemPlayerID.rawValue)"])
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        #expect(try await allRecordedServerInputs(keeper).map(\.sequence) == [failing, next], "the failed input is recorded")

        let path = try await saveRecord(keeper, name: "server-input-throw")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: true),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(!result.recordedStateHashes.isEmpty)
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick \(tickId): replay fails it the same way")
        }
        #expect(result.serverEventVerification == .passed, "its events are dropped live and in replay")
    }

    @Test("Live applies the record form: a Date and a Double decode the same live and in replay")
    func payloadAppliesInItsRecordForm() async throws {
        let keeper = try await makeKeeper(ticking: true)
        _ = try accepted(await keeper.submitServerInput(SIDated(
            at: Date(timeIntervalSince1970: 1_700_000_000.75), ratio: 2.0, count: 3
        )))
        await keeper.stepTickOnce()
        // The record holds whole seconds; live applies that, not the fractional value.
        #expect(await keeper.currentState().log == ["dated:1700000000.0:2.0:3"])

        let path = try await saveRecord(keeper, name: "server-input-dated")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: true),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(!result.recordedStateHashes.isEmpty)
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick \(tickId)")
        }
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A submit matches the declared type itself: a same-named type from another scope is refused")
    func sameNamedTypeIsRefused() async throws {
        let keeper = try await makeKeeper(ticking: true)
        #expect(String(describing: SIElsewhere.SIProgress.self) == String(describing: SIProgress.self))
        #expect(await keeper.submitServerInput(SIElsewhere.SIProgress(tag: "x")) == .refused(.unknownType))
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log.isEmpty)
    }

    @Test("The depth limit is checked inside the turn record: the deepest accepted payload records and replays")
    func depthIsCheckedInsideTheRecord() async throws {
        let keeper = try await makeKeeper(ticking: true)
        var deepest: Int?
        for depth in stride(from: CanonicalMessagePack.maxDepth, through: 64, by: -1) {
            if case .accepted = await keeper.submitServerInput(SIDeep(depth: depth)) {
                deepest = depth
                break
            }
        }
        let accepted = try #require(deepest)
        #expect(accepted < CanonicalMessagePack.maxDepth, "the record's own levels are reserved")
        #expect(await keeper.submitServerInput(SIDeep(depth: accepted + 1)) == .refused(.unencodable))
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["deep:\(accepted)"])
        #expect(try await allRecordedServerInputs(keeper).count == 1)

        // The recorder kept going: the record saves, and replays to the same hashes.
        let path = try await saveRecord(keeper, name: "server-input-deep")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: true),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(!result.recordedStateHashes.isEmpty)
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick \(tickId)")
        }
    }

    @Test("Replaying a recorded server input the land doesn't declare fails the replay")
    func undeclaredRecordedInputFailsReplay() async throws {
        let keeper = try await makeKeeper(ticking: true)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "a")))
        await keeper.stepTickOnce()
        let path = try await saveRecord(keeper, name: "server-input-undeclared")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeTickDefinitionWithoutServerInputs(),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(result.recordedPassMismatches.values.contains { $0.contains("SIProgress") }, "\(result.recordedPassMismatches)")
        #expect(result.serverEventVerification != .passed)
    }

    @Test("Refusals queue nothing: undeclared type, no record form, not live, draining")
    func refusalsQueueNothing() async throws {
        let keeper = try await makeKeeper(ticking: true)
        #expect(await keeper.submitServerInput(SIUndeclared(tag: "u")) == .refused(.unknownType))
        #expect(await keeper.submitServerInput(SIUnencodable(ids: [1, 2])) == .refused(.unencodable))
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log.isEmpty)

        let replay = LandKeeper<ServerInputTestState>(
            definition: makeDefinition(ticking: true),
            initialState: ServerInputTestState(),
            mode: .reevaluation,
            autoStartLoops: false
        )
        #expect(await replay.submitServerInput(SIProgress(tag: "r")) == .refused(.notLive))

        await keeper.forceShutdown()
        #expect(keeper.isDraining)
        #expect(await keeper.submitServerInput(SIProgress(tag: "d")) == .refused(.draining))
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        #expect(await ServerInputSubmitter.unavailable.submit(SIProgress(tag: "n")) == .refused(.notLive))
    }

    @Test("Over the in-flight cap a submit is refused and counted; an applied input frees its place")
    func capRefusesAndFrees() async throws {
        let keeper = try await makeKeeper(ticking: true)
        await keeper.setServerInputMaxInFlightForTesting(2)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "1")))
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "2")))
        #expect(await keeper.submitServerInput(SIProgress(tag: "3")) == .refused(.overCap))
        #expect(await keeper.serverInputCapRejections == 1)
        #expect(await keeper.serverInputsInFlightForTesting() == 2)

        await keeper.stepTickOnce()
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "4")))
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "5")))
        #expect(await keeper.serverInputCapRejections == 1)
    }

    @Test("A cap of 0 means no cap")
    func zeroCapIsUnbounded() async throws {
        let keeper = try await makeKeeper(ticking: true)
        await keeper.setServerInputMaxInFlightForTesting(0)
        for index in 0..<5 {
            _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "\(index)")))
        }
        #expect(ServerInputLimits.maxInFlightPerLand(environment: [:]) == 64)
        #expect(ServerInputLimits.maxInFlightPerLand(environment: ["SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND": "3"]) == 3)
        #expect(ServerInputLimits.maxInFlightPerLand(environment: ["SERVER_INPUT_IN_FLIGHT_MAX_PER_LAND": "-1"]) == 0)
    }

    @Test("Frozen, a tick land accepts a server input and applies it once after the resume")
    func frozenTickLandQueues() async throws {
        let keeper = try await makeKeeper(ticking: true)
        await keeper.stepTickOnce()
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        let tickBefore = await keeper.debugLastCommittedTickId()
        let sequence = try accepted(await keeper.submitServerInput(SIProgress(tag: "f")))
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log.isEmpty, "no tick runs while frozen")

        await keeper.debugResume(generation: 1)
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log == ["server:f:\(LandContext.systemPlayerID.rawValue)"])
        let recorded = try await allRecordedServerInputs(keeper)
        #expect(recorded.map(\.sequence) == [sequence])
        #expect(recorded.first?.resolvedAtTick == tickBefore)
    }

    @Test("Frozen, a tickless land holds a server input it accepts until the resume, even from a turn already running", arguments: [false, true])
    func frozenTicklessLandQueues(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(ticking: false, transport: inTurn ? SIInTurnTransport() : nil)
        // A's turn (in-turn: its drain; legacy: its pass) is held before it applies anything.
        let kickHold = WatermarkGate()
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>().on(.serverInputKick, arrival: 1) {
            await kickHold.enterAndWait()
        }.hook)
        let a = try accepted(await keeper.submitServerInput(SIProgress(tag: "a")))
        await kickHold.waitUntilEntered()

        // The freeze waits for A's turn, which is in flight; B is accepted meanwhile.
        let freeze = Task { await keeper.debugFreeze(generation: 1, timeout: .seconds(30)) }
        await keeper.waitUntilFreezeWaitsForTesting()
        #expect(await keeper.debugIsFrozenForTesting())
        let tickBefore = await keeper.debugLastCommittedTickId()
        let b = try accepted(await keeper.submitServerInput(SIProgress(tag: "b")))

        // A's turn runs during the freeze: it applies A, never B.
        kickHold.release()
        #expect(await freeze.value, "the freeze drained A's turn")
        let system = LandContext.systemPlayerID.rawValue
        #expect(await keeper.currentState().log == ["server:a:\(system)"], "B waits for the resume")
        #expect(await keeper.serverInputsInFlightForTesting() == 1)

        await keeper.debugResume(generation: 1)
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.currentState().log == ["server:a:\(system)", "server:b:\(system)"], "B applied once after the resume")
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        let recorded = try await allRecordedServerInputs(keeper)
        #expect(recorded.map(\.sequence) == [a, b])
        #expect(recorded.last?.resolvedAtTick == tickBefore)
    }

    @Test("Frozen, a tickless land applies a join before a held server input; the record keeps that order and replays", arguments: [false, true])
    func joinDuringFreezeAppliesBeforeHeldInput(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(ticking: false, transport: inTurn ? SIInTurnTransport() : nil)
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        let held = try accepted(await keeper.submitServerInput(SIProgress(tag: "held")))
        // Joins still run during a freeze; the held input waits for the resume.
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await keeper.currentState().log.isEmpty)
        await keeper.debugResume(generation: 1)
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.currentState().log == ["server:held:\(LandContext.systemPlayerID.rawValue)"])

        let path = try await saveRecord(keeper, name: "server-input-join-frozen")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let join = try #require(try await source.getLifecycleEvents(for: 0).first { $0.kind == "join" }?.sequence)
        #expect(join > held, "the join takes its sequence after the held input")
        let applied = try await source.getPasses(for: 0).flatMap(\.inputs)
        let joinAt = try #require(applied.firstIndex(of: join))
        let heldAt = try #require(applied.firstIndex(of: held))
        #expect(joinAt < heldAt, "the record keeps the applied order: the join first")

        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: false),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A land that drains during a freeze drops the server inputs it held: never applied, never recorded, and the record replays")
    func drainDuringFreezeDropsHeldInputs() async throws {
        let keeper = try await makeKeeper(ticking: false)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "before")))
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.debugFreeze(generation: 1, timeout: .seconds(10)))
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "held")))
        #expect(await keeper.serverInputsInFlightForTesting() == 1)
        await keeper.forceShutdown()
        #expect(await keeper.serverInputsInFlightForTesting() == 0)
        await keeper.debugResume(generation: 1)
        await keeper.waitForInFlightWorkForTesting()
        let system = LandContext.systemPlayerID.rawValue
        #expect(await keeper.currentState().log == ["server:before:\(system)"], "the held input is never applied")
        #expect(try await allRecordedServerInputs(keeper).count == 1, "nor recorded")

        // Like a pending client event at shutdown: its sequence is taken and unused, and the
        // record still replays.
        let path = try await saveRecord(keeper, name: "server-input-drain-frozen")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: false),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A tick land's record replays its server inputs without the outside work; state hashes match")
    func tickLandRoundTrip() async throws {
        let keeper = try await makeKeeper(ticking: true)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "a")))
        try await keeper.handleClientEvent(AnyClientEvent(SINoteEvent(tag: "b")), playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "c")))
        await keeper.stepTickOnce()
        let path = try await saveRecord(keeper, name: "server-input-tick")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let source = try ReevaluationRecordFile.openSource(filePath: path)
        #expect(try await source.getMetadata().version == "3.2")
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: true),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(!result.recordedStateHashes.isEmpty)
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick \(tickId)")
        }
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A tickless land applies each server input in a turn of its own, and its record replays them through the passes", arguments: [false, true])
    func ticklessLandRoundTrip(inTurn: Bool) async throws {
        let transport = inTurn ? SIInTurnTransport() : nil
        let keeper = try await makeKeeper(ticking: false, transport: transport)
        let drainEnds = SIDrainEnds()
        await keeper.setInTurnProbeForTesting { if $0 == "input-drain-end" { drainEnds.signal() } }
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.waitForInFlightWorkForTesting()
        // In-turn sync: each input's turn delivers its event in its own sync phase, so the
        // count goes up by one per input, none through the legacy send. Each server input is
        // submitted with no drain running (the join's drain isn't counted as in-flight work),
        // so only its own kick can apply it.
        func expectDelivered(_ n: Int, _ label: String) {
            if let transport { #expect(transport.counts.inTurn == n, "after \(label)") }
        }
        await drainEnds.waitForIdle(keeper)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "a")))
        await keeper.waitForInFlightWorkForTesting()
        expectDelivered(1, "a")
        try await keeper.handleClientEvent(AnyClientEvent(SINoteEvent(tag: "b")), playerID: p1, clientID: c1, sessionID: s1)
        await keeper.waitForInFlightWorkForTesting()
        expectDelivered(2, "b")
        await drainEnds.waitForIdle(keeper)
        _ = try accepted(await keeper.submitServerInput(SIProgress(tag: "c")))
        await keeper.waitForInFlightWorkForTesting()
        expectDelivered(3, "c")
        let system = LandContext.systemPlayerID.rawValue
        #expect(await keeper.currentState().log == ["server:a:\(system)", "client:b", "server:c:\(system)"])
        if let transport {
            // In-turn sync: every input, server inputs included, applies in an input turn whose
            // sync phase delivers its events (none through the legacy send).
            #expect(transport.counts.inTurn == 3)
            #expect(transport.counts.legacy == 0)
        }

        let path = try await saveRecord(keeper, name: "server-input-tickless")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let source = try ReevaluationRecordFile.openSource(filePath: path)
        let serverSequences = try await source.getServerInputs(for: 0).map(\.sequence)
        #expect(serverSequences.count == 2)
        let passed = try await source.getPasses(for: 0).flatMap(\.inputs)
        #expect(serverSequences.allSatisfy { passed.contains($0) }, "passes list server inputs")

        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(ticking: false),
            initialState: ServerInputTestState(),
            recordFilePath: path
        )
        #expect(result.recordedPassMismatches.isEmpty)
        #expect(result.serverEventMismatches.isEmpty)
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A frame without server inputs encodes as before, with no serverInputs key")
    func frameWithoutServerInputsHasNoKey() throws {
        let plain = ReevaluationTickFrame(tickId: 3, actions: [], clientEvents: [], lifecycleEvents: [])
        let json = try #require(String(data: JSONEncoder().encode(plain), encoding: .utf8))
        #expect(!json.contains("serverInputs"))

        let input = ReevaluationRecordedServerInput(
            sequence: 9, typeIdentifier: "SIProgress", payload: AnyCodable(SIProgress(tag: "z")), resolvedAtTick: 2
        )
        let withInput = ReevaluationTickFrame(tickId: 3, actions: [], clientEvents: [], lifecycleEvents: [], serverInputs: [input])
        let decoded = try JSONDecoder().decode(ReevaluationTickFrame.self, from: JSONEncoder().encode(withInput))
        #expect(decoded.serverInputs == [input])
        #expect(try JSONDecoder().decode(ReevaluationTickFrame.self, from: JSONEncoder().encode(plain)).serverInputs.isEmpty)
    }

    @Test("A declared server input doesn't change the client schema")
    func schemaUnchanged() throws {
        let with = Land("server-input-schema", using: ServerInputTestState.self) {
            ClientEvents { Register(SINoteEvent.self) }
            Rules {
                HandleEvent(SINoteEvent.self) { (_: inout ServerInputTestState, _: SINoteEvent, _: LandContext) in }
                HandleServerInput(SIProgress.self) { (_: inout ServerInputTestState, _: SIProgress, _: LandContext) in }
            }
        }
        let without = Land("server-input-schema", using: ServerInputTestState.self) {
            ClientEvents { Register(SINoteEvent.self) }
            Rules {
                HandleEvent(SINoteEvent.self) { (_: inout ServerInputTestState, _: SINoteEvent, _: LandContext) in }
            }
        }
        #expect(with.serverInputHandlers.keys.sorted() == [String(describing: SIProgress.self)])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let a = try encoder.encode(SchemaExtractor.extract(from: with))
        let b = try encoder.encode(SchemaExtractor.extract(from: without))
        #expect(a == b)
    }

    @Test("A submitter from a land's context reaches the keeper, and is refused once the keeper is gone")
    func submitterAfterKeeperGone() async throws {
        let box = SISubmitterBox()
        weak var weakKeeper: LandKeeper<ServerInputTestState>?
        do {
            let keeper = try await makeKeeper(ticking: true, box: box)
            weakKeeper = keeper
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
            await keeper.stepTickOnce()
            let submitter = try #require(box.value)
            _ = try accepted(await submitter.submit(SIProgress(tag: "via-context")))
            await keeper.stepTickOnce()
            #expect(await keeper.currentState().log == ["server:via-context:\(LandContext.systemPlayerID.rawValue)"])
            try await keeper.leave(playerID: p1, clientID: c1)
            await keeper.forceShutdown()
        }
        // The submitter holds the keeper weakly: it doesn't keep it alive.
        #expect(weakKeeper == nil)
        let submitter = try #require(box.value)
        #expect(await submitter.submit(SIProgress(tag: "late")) == .refused(.draining))
    }
}
