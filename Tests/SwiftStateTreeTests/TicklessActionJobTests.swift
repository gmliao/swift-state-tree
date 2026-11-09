// Tests/SwiftStateTreeTests/TicklessActionJobTests.swift
//
// On a tickless land, an action with resolvers is a job too: `submitAction` returns without
// waiting for them, the completion appends the action, and the input turn (or, in-turn sync
// off, the legacy pass) that applies it produces the handler's response, which waits in the
// job's slot. The slot is filled only after the turn's record is submitted, so a response never
// leaves before its input is recorded. Replay applies the recorded passes, so a job that
// completes after a later input replays in the live order.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct TicklessJobState: StateNodeProtocol {
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct TicklessJobGatedAction: ActionPayload {
    typealias Response = TicklessJobAck
    /// The key of the action's resolver gate (`TicklessJobGates`).
    let key: Int
    let tag: String
}

@Payload
struct TicklessJobPlainAction: ActionPayload {
    typealias Response = TicklessJobAck
    let tag: String
}

@Payload
struct TicklessJobAck: ResponsePayload {
    let entry: String
    let length: Int
}

@Payload
struct TicklessJobNote: ClientEventPayload {
    let tag: String
}

/// Emitted by every handler with the log after it, so a replay in another order fails.
@Payload
struct TicklessJobLogged: ServerEventPayload {
    let entry: String
    let length: Int
}

@Payload
struct TicklessJobFailingAction: ActionPayload {
    typealias Response = TicklessJobAck
    let key: Int
}

struct TicklessJobResolverFailure: Error {}

struct TicklessJobResolverOutput: ResolverOutput {
    let key: Int
}

/// One gate per key: resolvers are static, and parallel tests must not share a gate.
enum TicklessJobGates {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var gates: [Int: WatermarkGate] = [:]

    static func gate(_ key: Int) -> WatermarkGate {
        lock.withLock {
            if let gate = gates[key] { return gate }
            let gate = WatermarkGate()
            gates[key] = gate
            return gate
        }
    }
}

struct TicklessJobGatedResolver: ContextResolver {
    typealias Output = TicklessJobResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> TicklessJobResolverOutput {
        let key = (ctx.actionPayload as? TicklessJobGatedAction)?.key ?? -1
        await TicklessJobGates.gate(key).enterAndWait()
        return TicklessJobResolverOutput(key: key)
    }
}

/// Waits at its gate, then fails.
struct TicklessJobFailingResolver: ContextResolver {
    typealias Output = TicklessJobResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> TicklessJobResolverOutput {
        let key = (ctx.actionPayload as? TicklessJobFailingAction)?.key ?? -1
        await TicklessJobGates.gate(key).enterAndWait()
        throw TicklessJobResolverFailure()
    }
}

@discardableResult
private func append(_ entry: String, to state: inout TicklessJobState, ctx: LandContext) -> TicklessJobAck {
    state.log.append(entry)
    ctx.emitEvent(TicklessJobLogged(entry: entry, length: state.log.count), to: .all)
    return TicklessJobAck(entry: entry, length: state.log.count)
}

private func makeDefinition() -> LandDefinition<TicklessJobState> {
    Land("tickless-job", using: TicklessJobState.self) {
        ClientEvents { Register(TicklessJobNote.self) }
        ServerEvents { Register(TicklessJobLogged.self) }
        Rules {
            OnJoin { (state: inout TicklessJobState, ctx: LandContext) in
                append("join:\(ctx.playerID.rawValue)", to: &state, ctx: ctx)
            }
            HandleAction(TicklessJobGatedAction.self, resolvers: TicklessJobGatedResolver.self) {
                (state: inout TicklessJobState, action: TicklessJobGatedAction, ctx: LandContext) in
                append(action.tag, to: &state, ctx: ctx)
            }
            HandleAction(TicklessJobFailingAction.self, resolvers: TicklessJobFailingResolver.self) {
                (state: inout TicklessJobState, action: TicklessJobFailingAction, ctx: LandContext) in
                append("failing", to: &state, ctx: ctx)
            }
            HandleAction(TicklessJobPlainAction.self) {
                (state: inout TicklessJobState, action: TicklessJobPlainAction, ctx: LandContext) in
                append(action.tag, to: &state, ctx: ctx)
            }
            HandleEvent(TicklessJobNote.self) { (state: inout TicklessJobState, event: TicklessJobNote, ctx: LandContext) in
                append(event.tag, to: &state, ctx: ctx)
            }
        }
    }
}

/// Reports in-turn sync for every keeper, so a keeper attached to it takes the input-drain path.
private final class TicklessJobInTurnTransport: LandKeeperTransport, @unchecked Sendable {
    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async {}
    func onLandDestroyed() async {}
    func runsSyncPhaseInTurn(of keeper: AnyObject) -> Bool { true }
    func runSyncPhaseInTurn<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

private func makeKeeper(inTurn: Bool) async throws -> LandKeeper<TicklessJobState> {
    let definition = makeDefinition()
    let keeper = LandKeeper<TicklessJobState>(
        definition: definition,
        initialState: TicklessJobState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false,
        transport: inTurn ? TicklessJobInTurnTransport() : nil
    )
    // One land ID per keeper: parallel tests must not share a recorder spool.
    let landID = "tickless-job:\(UUID().uuidString)"
    await keeper.setLandID(landID)
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await recorder.setMetadata(ReevaluationRecordMetadata(
        landID: landID,
        landType: "tickless-job",
        createdAt: Date(timeIntervalSince1970: 1_700_000_000),
        metadata: [:],
        landDefinitionID: definition.id,
        rngSeed: DeterministicSeed.fromLandID(landID),
        version: ReevaluationRecordVersion.current
    ))
    return keeper
}

private func gated(key: Int, tag: String) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: TicklessJobGatedAction.self), payload: AnyCodable(TicklessJobGatedAction(key: key, tag: tag)))
}

private func plain(_ tag: String) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: TicklessJobPlainAction.self), payload: AnyCodable(TicklessJobPlainAction(tag: tag)))
}

/// Gate key per test and mode, so parallel cases never share a gate.
private func key(_ base: Int, inTurn: Bool) -> Int { 7_000 + base * 10 + (inTurn ? 1 : 0) }

/// Submits a gated action and expects a pending job; returns its sequence.
private func submitPending(
    _ keeper: LandKeeper<TicklessJobState>,
    key: Int,
    tag: String,
    player: PlayerID = p1,
    client: ClientID = c1,
    session: SessionID = s1,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws -> Int64 {
    let submission = try await keeper.submitAction(gated(key: key, tag: tag), playerID: player, clientID: client, sessionID: session)
    guard case .pending(let sequence) = submission else {
        Issue.record("Expected a pending job, got \(submission)", sourceLocation: sourceLocation)
        return -1
    }
    return sequence
}

/// The handler's response in a slot or a `.completed` submission.
private func ack(_ value: AnyCodable) -> TicklessJobAck? {
    (value.base as? TicklessJobAck) ?? ((value.base as? AnyCodable)?.base as? TicklessJobAck)
}

private func readResult(_ keeper: LandKeeper<TicklessJobState>, _ sequence: Int64, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Result<AnyCodable, any Error>? {
    try await withinDeadline("reading the job's result", sourceLocation: sourceLocation) {
        do { return .success(try await keeper.awaitActionResult(sequence: sequence)) } catch { return .failure(error) }
    }
}

private func saveRecord(_ keeper: LandKeeper<TicklessJobState>, name: String) async throws -> String {
    await keeper.waitForInFlightWorkForTesting()
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString).sstr").path
    try await recorder.save(to: path)
    return path
}

@Suite("Tickless action jobs: resolvers off the session's line", .timeLimit(.minutes(1)))
struct TicklessActionJobTests {
    @Test("A held action doesn't block the session's later inputs; it applies on completion, and replay matches", arguments: [true, false])
    func chainNotBlockedAndReplays(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let keyA = key(1, inTurn: inTurn), keyB = key(2, inTurn: inTurn)
        TicklessJobGates.gate(keyB).release()

        // A's resolver holds; every later input of the same session goes through.
        let a = try await submitPending(keeper, key: keyA, tag: "A")
        await TicklessJobGates.gate(keyA).waitUntilEntered()
        try await keeper.handleClientEvent(AnyClientEvent(TicklessJobNote(tag: "E")), playerID: p1, clientID: c1, sessionID: s1)
        let plainResponse = try await keeper.handleActionEnvelope(plain("plain"), playerID: p1, clientID: c1, sessionID: s1)
        #expect(ack(plainResponse)?.entry == "plain")
        let b = try await submitPending(keeper, key: keyB, tag: "B")
        let bResult = try await readResult(keeper, b)
        #expect(ack(try #require(try bResult?.get()))?.entry == "B")
        // B's answer comes after its turn's record; A still holds (its work is in flight).
        #expect(await keeper.debugInFlightWorkForTesting() == 1)
        #expect(await keeper.currentState().log == ["join:p1", "E", "plain", "B"])

        TicklessJobGates.gate(keyA).release()
        let aResult = try await readResult(keeper, a)
        let aAck = ack(try #require(try aResult?.get()))
        #expect(aAck?.entry == "A")
        #expect(aAck?.length == 5)
        #expect(await keeper.currentState().log == ["join:p1", "E", "plain", "B", "A"])

        // A applied after inputs with higher sequences; replay applies the recorded passes.
        let path = try await saveRecord(keeper, name: "tickless-job-order")
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(),
            initialState: TicklessJobState(),
            recordFilePath: path
        )
        #expect(result.recordedPassMismatches.isEmpty, "\(result.recordedPassMismatches)")
        #expect(result.serverEventVerification == .passed)
    }

    @Test("A lone job on an idle legacy land: its completion starts the pass that applies and answers it")
    func loneJobOnAnIdleLegacyLand() async throws {
        let keeper = try await makeKeeper(inTurn: false)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(10, inTurn: false)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        await TicklessJobGates.gate(k).waitUntilEntered()
        // No other input follows: nothing but the completion can start a pass.
        TicklessJobGates.gate(k).release()
        let result = try await readResult(keeper, sequence)
        #expect(ack(try #require(try result?.get()))?.entry == "A")
        #expect(await keeper.currentState().log == ["join:p1", "A"])
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
    }

    @Test("Every legacy caller (join, client event, action, leave) is answered by its own pass, under concurrency")
    func legacyCallersAreAppliedByTheirOwnPass() async throws {
        let keeper = try await makeKeeper(inTurn: false)
        // `runLegacyPass` asserts (debug) that its own pass applied the caller's input; many
        // concurrent callers of all four kinds interleave their passes.
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                let player = PlayerID("lp\(index)"), client = ClientID("lc\(index)"), session = SessionID("ls\(index)")
                group.addTask {
                    try await keeper.join(playerID: player, clientID: client, sessionID: session)
                    try await keeper.handleClientEvent(AnyClientEvent(TicklessJobNote(tag: "e\(index)")), playerID: player, clientID: client, sessionID: session)
                    let response = try await keeper.handleActionEnvelope(plain("a\(index)"), playerID: player, clientID: client, sessionID: session)
                    #expect(ack(response)?.entry == "a\(index)")
                    try await keeper.leave(playerID: player, clientID: client, sessionID: session)
                }
            }
            try await group.waitForAll()
        }
        #expect(await keeper.currentState().log.count == 60)
        #expect(await keeper.pendingItemSequencesForTesting().isEmpty)
    }

    @Test("A slot is filled after its turn's record is submitted, and a late reader gets the handler's response", arguments: [true, false])
    func slotFilledAfterTheRecord(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(3, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")

        // Hold the turn (or pass) that applies A at its record.
        let recordHold = WatermarkGate()
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.turnRecord) { await recordHold.enterAndWait() })
        TicklessJobGates.gate(k).release()
        await recordHold.waitUntilEntered()
        #expect(await keeper.currentState().log == ["join:p1", "A"])
        #expect(await keeper.actionSlotIsFilledForTesting(sequence) == false, "the response left before its input was recorded")
        await keeper.installHolds(nil)
        recordHold.release()

        // Read only after the job's work ended: the outcome waits in the slot.
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.actionSlotIsFilledForTesting(sequence) == true)
        let result = try await readResult(keeper, sequence)
        #expect(ack(try #require(try result?.get()))?.entry == "A")
        #expect(await keeper.actionJobCountsForTesting().slots == 0)
    }

    @Test("Freeze waits for a held tickless job and completes once its response exists", arguments: [true, false])
    func freezeWaitsForTheJob(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(4, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        await TicklessJobGates.gate(k).waitUntilEntered()

        let freeze = Task { () -> (frozen: Bool, filled: Bool) in
            let frozen = await keeper.debugFreeze(generation: 1, timeout: .seconds(30))
            return (frozen, await keeper.actionSlotIsFilledForTesting(sequence))
        }
        // The freeze is waiting on the job (the keeper reports the work in flight).
        try await withinDeadline("the freeze waits") { await keeper.waitUntilFreezeWaitsForTesting() }
        #expect(await keeper.debugIsFrozenForTesting())
        #expect(await keeper.debugInFlightWorkForTesting() == 1)
        TicklessJobGates.gate(k).release()
        let outcome = await freeze.value
        #expect(outcome.frozen)
        #expect(outcome.filled, "the freeze completed before the job's response existed")
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
        await keeper.debugResume(generation: 1)
        let result = try await readResult(keeper, sequence)
        #expect(ack(try #require(try result?.get()))?.entry == "A")
    }

    @Test("A leave during a tickless job's resolvers rejects it; nothing is applied", arguments: [true, false])
    func leaveRejectsThePendingJob(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(5, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        await TicklessJobGates.gate(k).waitUntilEntered()
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        let result = try await readResult(keeper, sequence)
        #expect(throws: LandInputRejection.self) { try result?.get() }
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
        TicklessJobGates.gate(k).release()
        try await withinDeadline("the job settles") { await keeper.waitForActionJobsForTesting() }
        #expect(await keeper.currentState().log == ["join:p1"])
    }

    @Test("A rejoin during a tickless job's resolvers rejects it; the new entry isn't affected", arguments: [true, false])
    func rejoinRejectsThePendingJob(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(6, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        await TicklessJobGates.gate(k).waitUntilEntered()
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        TicklessJobGates.gate(k).release()
        let result = try await readResult(keeper, sequence)
        #expect(throws: LandInputRejection.self) { try result?.get() }
        try await withinDeadline("the job settles") { await keeper.waitForActionJobsForTesting() }
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.currentState().log == ["join:p1", "join:p1"])
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
    }

    @Test("A delivered job is not rejected by a later leave: it applies and answers", arguments: [true, false])
    func deliveredJobSurvivesALeave(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(7, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        // A is delivered (appended) and its turn is held at the record; then p1 leaves.
        let recordHold = WatermarkGate()
        let held = TicklessJobFlag()
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(.turnRecord) {
            if held.setOnce() { await recordHold.enterAndWait() }
        })
        TicklessJobGates.gate(k).release()
        await recordHold.waitUntilEntered()
        let leave = Task { try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1) }
        recordHold.release()
        try await leave.value
        let result = try await readResult(keeper, sequence)
        #expect(ack(try #require(try result?.get()))?.entry == "A")
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
    }

    @Test("A leave between a job's delivery and its apply doesn't reject it: it applies and answers once", arguments: [true, false])
    func leaveBetweenDeliveryAndApply(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(10, inTurn: inTurn)
        let sequence = try await submitPending(keeper, key: k, tag: "A")
        await TicklessJobGates.gate(k).waitUntilEntered()
        // The completion delivers A; the turn (in-turn: its drain, legacy: its trigger pass)
        // that would apply it is held before it applies anything.
        let applyHold = WatermarkGate()
        let held = TicklessJobFlag()
        let point: LandKeeperHoldPoint = inTurn ? .inputDrain : .ticklessJobPass
        await keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>.at(point) {
            if held.setOnce() { await applyHold.enterAndWait() }
        })
        TicklessJobGates.gate(k).release()
        await applyHold.waitUntilEntered()
        #expect(await keeper.currentState().log == ["join:p1"], "A is delivered, not applied")
        #expect(await !keeper.actionSlotIsFilledForTesting(sequence))
        // p1 leaves in that window.
        try await keeper.leave(playerID: p1, clientID: c1, sessionID: s1)
        #expect(await !keeper.actionSlotIsFilledForTesting(sequence), "the leave rejected a delivered job")
        applyHold.release()
        let result = try await readResult(keeper, sequence)
        #expect(ack(try #require(try result?.get()))?.entry == "A")
        await keeper.waitForInFlightWorkForTesting()
        #expect(await keeper.currentState().log == ["join:p1", "A"], "applied once")
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
        await keeper.waitForActionJobsForTesting()
        #expect(await keeper.filledActionSlotsRememberedForTesting() == 0, "the finished job is forgotten")
    }

    @Test("A resolver failure answers with its error and ends the job's work", arguments: [true, false])
    func resolverFailureEndsTheWork(inTurn: Bool) async throws {
        let keeper = try await makeKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        let k = key(8, inTurn: inTurn)
        let submission = try await keeper.submitAction(
            ActionEnvelope(typeIdentifier: String(describing: TicklessJobFailingAction.self), payload: AnyCodable(TicklessJobFailingAction(key: k))),
            playerID: p1, clientID: c1, sessionID: s1
        )
        guard case .pending(let sequence) = submission else {
            Issue.record("Expected a pending job, got \(submission)")
            return
        }
        await TicklessJobGates.gate(k).waitUntilEntered()
        #expect(await keeper.debugInFlightWorkForTesting() == 1)
        TicklessJobGates.gate(k).release()
        let result = try await readResult(keeper, sequence)
        #expect(throws: (any Error).self) { try result?.get() }
        try await withinDeadline("the job settles") { await keeper.waitForActionJobsForTesting() }
        #expect(await keeper.debugInFlightWorkForTesting() == 0)
        #expect(await keeper.currentState().log == ["join:p1"])
    }
}

/// Sets once, from any thread.
private final class TicklessJobFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var set = false
    /// True for the first caller only.
    func setOnce() -> Bool {
        lock.withLock {
            defer { set = true }
            return !set
        }
    }
}
