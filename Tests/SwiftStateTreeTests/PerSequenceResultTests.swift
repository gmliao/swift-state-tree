// Tests/SwiftStateTreeTests/PerSequenceResultTests.swift
//
// Each input's caller gets that input's own outcome (#88), and an input whose handler throws
// fails alone: it is removed and recorded, its caller gets its error, and every later input
// continues with its own outcome. Same on the legacy path (in-turn sync off) and the in-turn
// path, tickless and tick lands.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct PerSequenceTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    /// Tags whose throwing action is refused by its `validate` (#586): nothing is written.
    @Sync(.broadcast)
    var refusedTags: [String] = []

    /// What ran, in order.
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@Payload
struct PerSequenceAck: ResponsePayload {
    let amount: Int
}

@Payload
struct PerSequencePlainAction: ActionPayload {
    typealias Response = PerSequenceAck
    let amount: Int
}

@Payload
struct PerSequenceGatedAction: ActionPayload {
    typealias Response = PerSequenceAck
    /// Also the key of the resolver's gate (`DeliveryGates`).
    let amount: Int
}

@Payload
struct PerSequenceThrowingAction: ActionPayload {
    typealias Response = PerSequenceAck
    let amount: Int
    /// Refused when it is in `refusedTags`.
    let tag: String
}

@Payload
struct PerSequenceEvent: ServerEventPayload {
    let amount: Int
}

struct PerSequenceGatedResolver: ContextResolver {
    typealias Output = DeliveryResolverOutput

    static func resolve(ctx: ResolverContext) async throws -> DeliveryResolverOutput {
        let amount = (ctx.actionPayload as? PerSequenceGatedAction)?.amount ?? -1
        await DeliveryGates.gate(amount).enterAndWait()
        return DeliveryResolverOutput(value: amount)
    }
}

struct PerSequenceHandlerFailure: Error, Equatable {
    let tag: String
}

/// Tags refused once, at `validate`'s first attempt (#586). A refused input run again would then
/// apply and show in the log, where a refusal the state decides (`refusedTags`) can't show it.
enum PerSequenceRefuseOnce {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var tags: Set<String> = []

    /// A tag no other test uses, refused at its first attempt only.
    static func fresh() -> String {
        let tag = "once-\(UUID().uuidString.prefix(8))"
        lock.withLock { _ = tags.insert(tag) }
        return tag
    }

    static func take(_ tag: String) -> Bool { lock.withLock { tags.remove(tag) != nil } }
}

private func makePerSequenceDefinition(tick: Bool) -> LandDefinition<PerSequenceTestState> {
    if tick {
        return Land("per-sequence-test", using: PerSequenceTestState.self) {
            ServerEvents { Register(PerSequenceEvent.self) }
            perSequenceRules()
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout PerSequenceTestState, _: LandContext) in
                    state.log.append("tick")
                }
            }
        }
    }
    return Land("per-sequence-test", using: PerSequenceTestState.self) {
        ServerEvents { Register(PerSequenceEvent.self) }
        perSequenceRules()
    }
}

private func perSequenceRules() -> RulesNode {
    Rules {
        OnJoin { (state: inout PerSequenceTestState, ctx: LandContext) in
            state.log.append("join:\(ctx.playerID.rawValue)")
        }
        OnLeave { (state: inout PerSequenceTestState, ctx: LandContext) in
            state.log.append("leave:\(ctx.playerID.rawValue)")
        }
        HandleAction(PerSequencePlainAction.self) {
            (state: inout PerSequenceTestState, action: PerSequencePlainAction, ctx: LandContext) in
            state.total += action.amount
            state.log.append("plain:\(action.amount)")
            ctx.emitEvent(PerSequenceEvent(amount: action.amount), to: .all)
            return PerSequenceAck(amount: action.amount)
        }
        HandleAction(PerSequenceGatedAction.self, resolvers: PerSequenceGatedResolver.self) {
            (state: inout PerSequenceTestState, action: PerSequenceGatedAction, _: LandContext) in
            state.total += action.amount
            state.log.append("gated:\(action.amount)")
            return PerSequenceAck(amount: action.amount)
        }
        HandleAction(PerSequenceThrowingAction.self, validate: {
            (state: PerSequenceTestState, action: PerSequenceThrowingAction, _: ValidateContext) in
            if state.refusedTags.contains(action.tag) || PerSequenceRefuseOnce.take(action.tag) {
                throw PerSequenceHandlerFailure(tag: action.tag)
            }
        }, apply: { (state: inout PerSequenceTestState, action: PerSequenceThrowingAction, _: LandContext) in
            state.total += action.amount
            state.log.append("throwing:\(action.tag)")
            return PerSequenceAck(amount: action.amount)
        })
    }
}

/// Reports in-turn sync for every keeper and commits each requested sync phase, so a keeper
/// attached to it takes the in-turn path whatever `IN_TURN_SYNC` says. Not an actor: its
/// synchronous calls need no isolation.
private final class PerSequenceInTurnTransport: LandKeeperTransport, @unchecked Sendable {
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
        InTurnSyncOutput(syncPhaseResult(state: state, events: events, includeSync: includeSync))
    }

    private func syncPhaseResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        includeSync ? .committed(clearDirtyFlags: true) : .notRequested
    }
}

/// In-turn transport that counts the turns whose output step included the sync phase.
private final class InTurnSyncSpyTransport: LandKeeperTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var syncs = 0
    var syncPhases: Int { lock.withLock { syncs } }

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
        InTurnSyncOutput(syncPhaseResult(state: state, events: events, includeSync: includeSync))
    }

    private func syncPhaseResult<S: StateNodeProtocol>(
        state: S,
        events: [InTurnServerEvent],
        includeSync: Bool
    ) -> InTurnSyncResult {
        guard includeSync else { return .notRequested }
        lock.withLock { syncs += 1 }
        return .committed(clearDirtyFlags: true)
    }
}

/// Counts the legacy broadcast-only syncs (the one a leave asks for).
private actor BroadcastSpyTransport: LandKeeperTransport {
    private(set) var broadcastSyncs = 0

    func sendEventToTransport(_ event: AnyServerEvent, to target: EventTarget) async {}
    func syncNowFromTransport() async {}
    func syncBroadcastOnlyFromTransport() async { broadcastSyncs += 1 }
    func onLandDestroyed() async {}
}

private let perSequenceLandID = "per-sequence-test:local"

private func makePerSequenceKeeper(
    tick: Bool = false,
    inTurn: Bool,
    refusedTags: [String] = [],
    recording: Bool = false,
    transport: (any LandKeeperTransport)? = nil
) async -> LandKeeper<PerSequenceTestState> {
    var initial = PerSequenceTestState()
    initial.refusedTags = refusedTags
    let keeper = LandKeeper<PerSequenceTestState>(
        definition: makePerSequenceDefinition(tick: tick),
        initialState: initial,
        enableLiveStateHashRecording: recording,
        autoStartLoops: false,
        transport: transport ?? (inTurn ? PerSequenceInTurnTransport() : nil)
    )
    #expect(await keeper.isUsingInTurnSync() == inTurn)
    await keeper.setLandID(perSequenceLandID)
    if recording, let recorder = await keeper.getReevaluationRecorder() {
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: perSequenceLandID,
            landType: "per-sequence-test",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000),
            metadata: [:],
            landDefinitionID: "per-sequence-test",
            rngSeed: DeterministicSeed.fromLandID(perSequenceLandID),
            version: ReevaluationRecordVersion.current
        ))
    }
    return keeper
}

private let p1 = PlayerID("p1"), c1 = ClientID("c1"), s1 = SessionID("s1")
private let p2 = PlayerID("p2"), c2 = ClientID("c2"), s2 = SessionID("s2")

private func envelope(_ action: any ActionPayload) -> ActionEnvelope {
    ActionEnvelope(typeIdentifier: String(describing: type(of: action)), payload: AnyCodable(action))
}

/// The ack in a tickless action's response.
private func ackAmount(_ response: AnyCodable) -> Int? {
    let ack = (response.base as? PerSequenceAck) ?? ((response.base as? AnyCodable)?.base as? PerSequenceAck)
    return ack?.amount
}

private func send(
    _ keeper: LandKeeper<PerSequenceTestState>,
    _ action: any ActionPayload,
    from player: PlayerID = p1
) async throws -> AnyCodable {
    let (client, session) = player == p1 ? (c1, s1) : (c2, s2)
    return try await keeper.handleActionEnvelope(envelope(action), playerID: player, clientID: client, sessionID: session)
}

/// Sends `action` and describes its outcome: "ok <amount>", "threw <tag>" or "closed".
private func outcome(
    _ keeper: LandKeeper<PerSequenceTestState>,
    _ action: any ActionPayload,
    from player: PlayerID = p1
) async -> String {
    do {
        let response = try await send(keeper, action, from: player)
        return "ok \(ackAmount(response).map(String.init) ?? "-")"
    } catch let failure as PerSequenceHandlerFailure {
        return "threw \(failure.tag)"
    } catch LandInputRejection.landClosed {
        return "closed"
    } catch {
        return "error \(error)"
    }
}

@Suite("Each input's own outcome; a throwing input fails alone", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct PerSequenceResultTests {
    @Test("A caller gets its own response, not that of an input run after it (#88)", arguments: [false, true])
    func ownResponse(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        let gateKey = DeliveryGates.freshKey()
        // Refused at its first attempt only: run again, it would apply.
        let t = PerSequenceRefuseOnce.fresh()

        // Y takes its number, then holds in its resolver; T, numbered after Y, throws.
        let y = Task { try await send(keeper, PerSequenceGatedAction(amount: gateKey), from: p2) }
        guard try await withinDeadline("Y's resolver holds", {
            await DeliveryGates.gate(gateKey).waitUntilEntered()
        }) != nil else { return }
        #expect(await outcome(keeper, PerSequenceThrowingAction(amount: 7, tag: t)) == "threw \(t)")

        DeliveryGates.gate(gateKey).release()
        guard let response = try await withinDeadline("Y returns", { try await y.value }) else { return }
        #expect(ackAmount(response) == gateKey)
        // T failed and was removed: it doesn't run again, in Y's pass or in a later one.
        #expect(await outcome(keeper, PerSequencePlainAction(amount: 1)) == "ok 1")
        let state = await keeper.currentState()
        #expect(state.total == gateKey + 1)
        #expect(!state.log.contains("throwing:\(t)"))
    }

    @Test("Tickless: an always-throwing input fails alone and blocks nothing; nothing runs twice", arguments: [false, true])
    func throwingInputFailsAlone(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(inTurn: inTurn, refusedTags: ["w"])
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        var outcomes: [String] = []
        for action: any ActionPayload in [
            PerSequencePlainAction(amount: 3),
            PerSequenceThrowingAction(amount: 1, tag: "w"),
            PerSequencePlainAction(amount: 5),
            PerSequenceThrowingAction(amount: 1, tag: "w"),
            PerSequencePlainAction(amount: 7),
        ] {
            outcomes.append(await outcome(keeper, action))
        }
        #expect(outcomes == ["ok 3", "threw w", "ok 5", "threw w", "ok 7"])
        let state = await keeper.currentState()
        #expect(state.total == 15)
        #expect(state.log == ["join:p1", "plain:3", "plain:5", "plain:7"])
    }

    @Test("Tick land: in one tick, the inputs after a throwing input apply; it doesn't run again next tick", arguments: [false, true])
    func tickPassContinuesPastThrow(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(tick: true, inTurn: inTurn)
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        // Refused at its first attempt only: if it stayed queued, the next tick would apply it.
        let w = PerSequenceRefuseOnce.fresh()
        _ = try await send(keeper, PerSequencePlainAction(amount: 2))
        _ = try await send(keeper, PerSequenceThrowingAction(amount: 1, tag: w))
        _ = try await send(keeper, PerSequencePlainAction(amount: 4))
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()

        let state = await keeper.currentState()
        #expect(state.total == 6)
        #expect(state.log == ["join:p1", "tick", "plain:2", "plain:4", "tick", "tick"])
    }

    @Test("Legacy and in-turn give the same outcomes and state for the same tickless inputs")
    func legacyAndInTurnAgree() async throws {
        var runs: [[String]] = []
        for inTurn in [false, true] {
            let keeper = await makePerSequenceKeeper(inTurn: inTurn, refusedTags: ["w", "t"])
            try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
            var log: [String] = []
            for action: any ActionPayload in [
                PerSequencePlainAction(amount: 3),
                PerSequenceThrowingAction(amount: 1, tag: "w"),
                PerSequenceThrowingAction(amount: 100, tag: "t"),
                PerSequencePlainAction(amount: 5),
                PerSequenceThrowingAction(amount: 100, tag: "t"),
                PerSequencePlainAction(amount: 7),
            ] {
                log.append(await outcome(keeper, action))
            }
            let state = await keeper.currentState()
            log.append("total \(state.total)")
            runs.append(log)
        }
        #expect(runs[0] == runs[1])
        #expect(runs[0].dropLast() == ["ok 3", "threw w", "threw t", "ok 5", "threw t", "ok 7"])
        #expect(runs[0].last == "total 15")
    }

    @Test("Legacy tick: a leave applied before a throwing input still gets its broadcast-only sync")
    func leaveBeforeThrowStillBroadcasts() async throws {
        let spy = BroadcastSpyTransport()
        let keeper = await makePerSequenceKeeper(
            tick: true, inTurn: false, refusedTags: ["w"], transport: spy
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        await keeper.stepTickOnce()
        let before = await spy.broadcastSyncs

        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        _ = try await send(keeper, PerSequenceThrowingAction(amount: 1, tag: "w"))
        await keeper.stepTickOnce()

        #expect(await spy.broadcastSyncs == before + 1)
        #expect(await keeper.currentState().log.contains("leave:p2"))
    }

    @Test("Tick land with a recorder: a pass with OnJoin, OnLeave and a throwing input is recorded once, in order, and replays (ON and OFF)", arguments: [false, true])
    func recordedPassReplays(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(
            tick: true, inTurn: inTurn, refusedTags: ["w"], recording: true
        )
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)
        await keeper.stepTickOnce()
        // One tick's pass: OnJoin, an action, a throwing action, OnLeave, an action.
        try await keeper.join(playerID: p2, clientID: c2, sessionID: s2)
        _ = try await send(keeper, PerSequencePlainAction(amount: 2))
        _ = try await send(keeper, PerSequenceThrowingAction(amount: 1, tag: "w"))
        try await keeper.leave(playerID: p2, clientID: c2, sessionID: s2)
        _ = try await send(keeper, PerSequencePlainAction(amount: 4))
        await keeper.stepTickOnce()
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().log
            == ["join:p1", "tick", "join:p2", "plain:2", "leave:p2", "plain:4", "tick", "tick"])

        let recorder = try #require(await keeper.getReevaluationRecorder())
        let frames = await recorder.getAllFrames()
        let inputSequences = frames.flatMap { frame in
            (frame.actions.map(\.sequence) + frame.lifecycleEvents.map(\.sequence)).sorted()
        }
        // Every input recorded once, in order, the failed one included; nothing again later.
        #expect(inputSequences == Array(Set(inputSequences)).sorted())
        let passFrame = try #require(frames.first { !$0.actions.isEmpty })
        #expect(passFrame.actions.map(\.typeIdentifier) == [
            String(describing: PerSequencePlainAction.self),
            String(describing: PerSequenceThrowingAction.self),
            String(describing: PerSequencePlainAction.self),
        ])
        #expect(passFrame.lifecycleEvents.map(\.kind) == ["join", "leave"])
        // The plain actions' events go out; the refused input emitted none.
        #expect(passFrame.serverEvents.count == 2)
        #expect(passFrame.serverEvents.map(\.sequence) == passFrame.serverEvents.map(\.sequence).sorted())
        // A tick land records the refused input on its frame (record format 3.5, #586).
        #expect(passFrame.rejected == [passFrame.actions[1].sequence])
        #expect(frames.filter { !$0.actions.isEmpty }.count == 1)

        try await expectReplayMatches(recorder, refusedTags: ["w"])
    }

    @Test("Tickless: a drain starting after a throwing input's pass: its caller gets its error, a later caller landClosed", arguments: [false, true])
    func throwingInputAcrossDrain(inTurn: Bool) async throws {
        let keeper = await makePerSequenceKeeper(inTurn: inTurn, refusedTags: ["w"])
        try await keeper.join(playerID: p1, clientID: c1, sessionID: s1)

        // P fails in its pass (or turn), which then holds before its record.
        let recordGate = WatermarkGate()
        await keeper.installHolds(HoldRegistry.at(.turnRecord) { await recordGate.enterAndWait() })
        let failing = Task { await outcome(keeper, PerSequenceThrowingAction(amount: 1, tag: "w")) }
        guard try await withinDeadline("P's pass holds before its record", {
            await recordGate.waitUntilEntered()
        }) != nil else { return }

        // The shutdown applies once P's turn has ended (in-turn: after its record); an input
        // after the shutdown is rejected (#382).
        let shutdown = Task { await keeper.forceShutdown() }
        await keeper.installHolds(nil)
        recordGate.release()
        guard try await withinDeadline("the shutdown returns", { await shutdown.value }) != nil else { return }
        #expect(await outcome(keeper, PerSequencePlainAction(amount: 5)) == "closed")

        guard let failed = try await withinDeadline("P's caller returns", { await failing.value }) else { return }
        #expect(failed == "threw w")
        #expect(await keeper.currentState().total == 0)
    }

}

/// Saves `recorder`'s record and replays it on a tick land; the replay must match the live
/// state hashes and server events.
private func expectReplayMatches(
    _ recorder: ReevaluationRecorder,
    refusedTags: [String] = [],
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let path = FileManager.default.temporaryDirectory
        .appendingPathComponent("per-sequence-\(UUID().uuidString).json").path
    defer { try? FileManager.default.removeItem(atPath: path) }
    try await recorder.save(to: path)
    var initial = PerSequenceTestState()
    initial.refusedTags = refusedTags
    let result = try await ReevaluationEngine.run(
        definition: makePerSequenceDefinition(tick: true),
        initialState: initial,
        recordFilePath: path
    )
    #expect(!result.recordedStateHashes.isEmpty, sourceLocation: sourceLocation)
    #expect(result.serverEventMismatches.isEmpty, sourceLocation: sourceLocation)
    #expect(result.tickHashes == result.recordedStateHashes, sourceLocation: sourceLocation)
}
