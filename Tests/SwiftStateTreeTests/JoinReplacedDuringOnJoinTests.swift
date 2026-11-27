// Tests/SwiftStateTreeTests/JoinReplacedDuringOnJoinTests.swift
//
// A join whose entry is replaced or removed while its OnJoin resolvers run must not leave the
// player's lifecycle out of order (#860). The invariant: per player, the applied OnJoin and
// OnLeave inputs alternate, starting with a join, and each OnLeave follows the OnJoin of the
// entry it ends. A join's OnJoin and its entry's OnLeave are dropped as a pair when the entry
// goes before the OnJoin applied:
// - the join appends no OnJoin and throws `JoinError.superseded`;
// - the leave that removed the entry (a newer login's kick, or the session's own leave) appends
//   no OnLeave.
// A kick's leave awaits too: a third login meanwhile finds the slot empty and inserts its own
// entry. Each attempt takes an arrival token at its decision; a kicking join that resumes and
// finds a later arrival is fenced out: it throws `JoinError.superseded`, and the last login to
// arrive keeps the player (R8), whichever kick returns first (R11). The kick's leave is scoped
// by the kicked entry's generation, so it never removes a newer entry that carries the kicked
// one's IDs (R10).
// K6 (#588) turns a duplicate login into a rebind; the invariant carries over, and so does
// this suite as its regression test.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct ReplacedJoinState: StateNodeProtocol {
    /// "join:<client>" and "leave:<client>", in apply order.
    @Sync(.broadcast)
    var log: [String] = []

    public init() {}
}

@PlainData
struct ReplacedJoinOutput: ResolverOutput {
    let value: Int
}

struct ReplacedJoinResolverFailure: Error, Equatable {}

@Payload
struct ReplacedJoinEvent: ServerEventPayload {
    let client: String
}

/// Emits `ReplacedJoinEvent` for its sender: a server event after a sequence gap (R7b).
@Payload
struct ReplacedJoinEmitAction: ActionPayload {
    typealias Response = ReplacedJoinAck
    let n: Int
}

/// Its resolver waits on gate `key` (R8, R9).
@Payload
struct ReplacedJoinGatedAction: ActionPayload {
    typealias Response = ReplacedJoinAck
    let key: Int
}

@Payload
struct ReplacedJoinAck: ResponsePayload {
    let ok: Bool
}

@PlainData
struct ReplacedJoinActionResolver: Resolver {
    typealias Dependencies = NoServices
    typealias Output = ReplacedJoinOutput
    let key: Int

    func resolve(_ deps: NoServices) async throws -> ReplacedJoinOutput {
        let key = key
        await ReplacedJoinGates.gate(key).enterAndWait()
        return ReplacedJoinOutput(value: key)
    }
}

enum ReplacedJoinGates {
    private static let keys = KeyedGates(firstKey: 11_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> WatermarkGate { keys.gate(key, sourceLocation: sourceLocation) }
}

/// OnJoin's resolver: a client ID "gate-<n>" waits on gate n; "fail-<n>" waits on gate n, then
/// throws; any other client passes.
struct ReplacedJoinResolver: ContextResolver {
    typealias Output = ReplacedJoinOutput
    static func resolve(ctx: ResolverContext) async throws -> ReplacedJoinOutput {
        let client = ctx.clientID.rawValue
        for (prefix, fails) in [("gate-", false), ("fail-", true)] where client.hasPrefix(prefix) {
            guard let key = Int(client.dropFirst(prefix.count)) else { continue }
            await ReplacedJoinGates.gate(key).enterAndWait()
            if fails { throw ReplacedJoinResolverFailure() }
        }
        return ReplacedJoinOutput(value: 0)
    }
}

/// OnLeave's resolver: a leaving client "lgate-<n>" waits on gate n; any other client passes.
struct ReplacedLeaveResolver: ContextResolver {
    typealias Output = ReplacedJoinOutput
    static func resolve(ctx: ResolverContext) async throws -> ReplacedJoinOutput {
        let client = ctx.clientID.rawValue
        if client.hasPrefix("lgate-"), let key = Int(client.dropFirst("lgate-".count)) {
            await ReplacedJoinGates.gate(key).enterAndWait()
        }
        return ReplacedJoinOutput(value: 0)
    }
}

private func makeDefinition(tick: Bool) -> LandDefinition<ReplacedJoinState> {
    if tick {
        return Land("replaced-join", using: ReplacedJoinState.self) {
            ServerEvents { Register(ReplacedJoinEvent.self) }
            Rules {
                OnJoin(resolvers: ReplacedJoinResolver.self) { state, _, ctx in
                    state.log.append("join:\(ctx.clientID.rawValue)")
                }
                OnLeave(resolvers: ReplacedLeaveResolver.self) { state, _, ctx in
                    state.log.append("leave:\(ctx.clientID.rawValue)")
                }
                HandleAction(ReplacedJoinEmitAction.self) { state, action, ctx in
                    state.log.append("emit:\(action.n)")
                    ctx.emitEvent(ReplacedJoinEvent(client: ctx.clientID.rawValue), to: .all)
                    return ReplacedJoinAck(ok: true)
                }
                HandleAction(ReplacedJoinGatedAction.self, resolvers: { _, action, _ in ReplacedJoinActionResolver(key: action.key) }) {
                    state, action, _, _ in
                    state.log.append("action:\(action.key)")
                    return ReplacedJoinAck(ok: true)
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
    }
    return Land("replaced-join", using: ReplacedJoinState.self) {
        ServerEvents { Register(ReplacedJoinEvent.self) }
        Rules {
            OnJoin(resolvers: ReplacedJoinResolver.self) { state, _, ctx in
                state.log.append("join:\(ctx.clientID.rawValue)")
            }
            OnLeave(resolvers: ReplacedLeaveResolver.self) { state, _, ctx in
                state.log.append("leave:\(ctx.clientID.rawValue)")
            }
            HandleAction(ReplacedJoinEmitAction.self) { state, action, ctx in
                state.log.append("emit:\(action.n)")
                ctx.emitEvent(ReplacedJoinEvent(client: ctx.clientID.rawValue), to: .all)
                return ReplacedJoinAck(ok: true)
            }
            HandleAction(ReplacedJoinGatedAction.self, resolvers: { _, action, _ in ReplacedJoinActionResolver(key: action.key) }) {
                state, action, _, _ in
                state.log.append("action:\(action.key)")
                return ReplacedJoinAck(ok: true)
            }
        }
    }
}

/// One keeper and one player, joined through the reporting path (`join(session:)`) or the
/// `join(playerID:)` overload.
private struct ReplacedJoinFixture {
    let keeper: LandKeeper<ReplacedJoinState>
    let tick: Bool
    let reporting: Bool
    let player = PlayerID("p1")

    init(tick: Bool, reporting: Bool, recording: Bool = false) async {
        self.tick = tick
        self.reporting = reporting
        keeper = LandKeeper<ReplacedJoinState>(
            definition: makeDefinition(tick: tick),
            initialState: ReplacedJoinState(),
            enableLiveStateHashRecording: recording,
            autoStartLoops: false,
            landID: "replaced-join:local"
        )
        if recording, let recorder = await keeper.getReevaluationRecorder() {
            await recorder.setMetadata(ReevaluationRecordMetadata(
                landID: "replaced-join:local",
                landType: "replaced-join",
                createdAt: Date(timeIntervalSince1970: 1_700_000_000),
                metadata: [:],
                landDefinitionID: "replaced-join",
                rngSeed: DeterministicSeed.fromLandID("replaced-join:local"),
                version: ReevaluationRecordVersion.current
            ))
        }
    }

    func join(_ client: ClientID, _ session: SessionID) async throws {
        if reporting {
            _ = try await keeper.join(session: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
                                      clientID: client, sessionID: session, services: LandServices())
        } else {
            try await keeper.join(playerID: player, clientID: client, sessionID: session)
        }
    }

    /// The join in a task; its error, or nil when it returned.
    func joinInTask(_ client: ClientID, _ session: SessionID) -> Task<(any Error)?, Never> {
        Task {
            do { try await join(client, session); return nil } catch { return error }
        }
    }

    /// A tick land applies its pending inputs in a tick; a tickless land already has.
    func settle() async {
        if tick { await keeper.stepTickOnce() }
    }

    var log: [String] {
        get async { await keeper.currentState().log }
    }

    /// Submits a gated action for the player's `client`; its sequence, or nil (recorded) when it
    /// isn't a pending job.
    func submitGated(_ key: Int, client: ClientID, session: SessionID, sourceLocation: SourceLocation = #_sourceLocation) async throws -> Int64? {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: ReplacedJoinGatedAction.self),
            payload: AnyCodable(ReplacedJoinGatedAction(key: key))
        )
        let submission = try await keeper.submitAction(envelope, playerID: player, clientID: client, sessionID: session)
        guard case .pending(let sequence) = submission else {
            Issue.record("Expected a pending job, got \(submission)", sourceLocation: sourceLocation)
            return nil
        }
        return sequence
    }

    /// The emitting action, from the player's `client`.
    func emit(_ n: Int, client: ClientID, session: SessionID) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: ReplacedJoinEmitAction.self),
            payload: AnyCodable(ReplacedJoinEmitAction(n: n))
        )
        _ = try await keeper.handleActionEnvelope(envelope, playerID: player, clientID: client, sessionID: session)
    }
}

/// The task's value once it ends, or nil when it doesn't end within the hang bound. The wait is
/// on an event the task's end appends, not on `task.value`: a task group's bound
/// (`withinHangBound`) can't end an await of a task that never returns, since the group waits
/// for every child.
private func valueWithinHangBound<T: Sendable>(_ task: Task<T, Never>) async -> T? {
    let ended = EventLog()
    Task {
        _ = await task.value
        ended.append("ended")
    }
    guard await ended.waitFor("ended") else { return nil }
    return await task.value
}

/// Whether the action's outcome is a rejection, read without waiting on a held resolver: call
/// it once the slot is filled.
private func isRejected(_ keeper: LandKeeper<ReplacedJoinState>, _ sequence: Int64) async -> Bool {
    do {
        _ = try await keeper.awaitActionResult(sequence: sequence)
        return false
    } catch {
        return true
    }
}

private func tempRecordPath(_ name: String) -> String {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("replaced-join-\(name)-\(UUID().uuidString).json")
        .path
}

private func isSuperseded(_ error: (any Error)?) -> Bool {
    if case .superseded? = error as? JoinError { return true }
    return false
}

/// Whether `error` is the resolver's own failure, as the executor reports it.
private func isResolverFailure(_ error: (any Error)?) -> Bool {
    guard case let .resolverFailed(_, underlying)? = error as? ResolverExecutionError else { return false }
    return underlying is ReplacedJoinResolverFailure
}

private func describe(_ error: (any Error)?) -> String {
    error.map { "threw \($0)" } ?? "returned"
}

@Suite("A join replaced or removed during its OnJoin resolvers (#860)", .timeLimit(.minutes(1)), .resolverDeadlinesOff)
struct JoinReplacedDuringOnJoinTests {
    @Test("R1: a second login during A's OnJoin resolvers: A's OnJoin and the kick's OnLeave are both dropped", arguments: [false, true], [false, true])
    func replacedJoinDropsThePair(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b")

        // A: inserted, its OnJoin resolver held.
        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }

        // B: a second login of the same player kicks A's entry and inserts its own.
        try await f.join(clientB, SessionID("s-b"))

        // A's resolver ends; A's join finds its entry gone.
        gate.release()
        let errorA = await joinA.value
        await f.settle()

        let log = await f.log
        #expect(log == ["join:\(clientB.rawValue)"], "tick=\(tick) reporting=\(reporting): log \(log), A's join \(describe(errorA))")
        #expect(isSuperseded(errorA), "A's join \(describe(errorA))")
        #expect(await f.keeper.playerCount() == 1)
    }

    @Test("R2: A's own leave during its OnJoin resolvers: nothing applies, and the land is empty", arguments: [false, true], [false, true])
    func leaveDuringOnJoinDropsThePair(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), sessionA = SessionID("s-a")

        let joinA = f.joinInTask(clientA, sessionA)
        guard await gate.waitUntilEntered() else { return }

        // The session disconnects while its OnJoin resolvers run.
        try await f.keeper.leave(playerID: f.player, clientID: clientA, sessionID: sessionA)

        gate.release()
        let errorA = await joinA.value
        await f.settle()

        let log = await f.log
        #expect(log == [], "tick=\(tick) reporting=\(reporting): log \(log), A's join \(describe(errorA))")
        #expect(isSuperseded(errorA), "A's join \(describe(errorA))")
        #expect(await f.keeper.playerCount() == 0)
    }

    @Test("R3: a join with OnJoin resolvers and nothing in between applies its OnJoin and returns", arguments: [false, true], [false, true])
    func uncontendedJoinApplies(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)")

        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        gate.release()
        let errorA = await joinA.value
        await f.settle()

        #expect(errorA == nil, "A's join \(describe(errorA))")
        #expect(await f.log == ["join:\(clientA.rawValue)"])
        #expect(await f.keeper.playerCount() == 1)
    }

    @Test("R4: a second login after A's OnJoin was appended kicks A as before: join A, leave A, join B", arguments: [false, true], [false, true])
    func kickAfterOnJoinIsUnchanged(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b")

        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        gate.release()
        let errorA = await joinA.value
        #expect(errorA == nil, "A's join \(describe(errorA))")
        await f.settle()

        try await f.join(clientB, SessionID("s-b"))
        await f.settle()

        #expect(await f.log == ["join:\(clientA.rawValue)", "leave:\(clientA.rawValue)", "join:\(clientB.rawValue)"])
    }

    @Test("R5: tick land, a tick between the kick and A's append: the tick applies only B's join, and A's join stays dropped", arguments: [false, true])
    func tickBetweenKickAndAppend(reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: true, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b")

        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        try await f.join(clientB, SessionID("s-b"))

        // A tick runs before A's resolvers end: it applies what the kick and B appended.
        await f.keeper.stepTickOnce()
        #expect(await f.log == ["join:\(clientB.rawValue)"], "the kick appended an OnLeave for an entry whose OnJoin never applied")

        gate.release()
        let errorA = await joinA.value
        await f.keeper.stepTickOnce()

        let log = await f.log
        #expect(log == ["join:\(clientB.rawValue)"], "reporting=\(reporting): log \(log), A's join \(describe(errorA))")
        #expect(isSuperseded(errorA), "A's join \(describe(errorA))")
    }

    @Test("R6: A's OnJoin resolvers throw after the kick: A's join fails with their error, and B's entry is untouched", arguments: [false, true], [false, true])
    func resolverFailureAfterKick(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("fail-\(key)"), clientB = ClientID("c-b"), sessionB = SessionID("s-b")

        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        try await f.join(clientB, sessionB)

        // A's resolver throws: its failure path removes only its own entry, which is gone.
        gate.release()
        let errorA = await joinA.value
        await f.settle()

        let log = await f.log
        #expect(log == ["join:\(clientB.rawValue)"], "tick=\(tick) reporting=\(reporting): log \(log), A's join \(describe(errorA))")
        #expect(isResolverFailure(errorA), "A's join \(describe(errorA))")
        #expect(await f.keeper.playerCount() == 1)

        // B's entry is the player's: B's own leave applies.
        try await f.keeper.leave(playerID: f.player, clientID: clientB, sessionID: sessionB)
        await f.settle()
        #expect(await f.log == ["join:\(clientB.rawValue)", "leave:\(clientB.rawValue)"])
    }

    @Test("R7: the kick's skipped OnLeave takes no sequence; A's dropped OnJoin leaves a one-number gap", arguments: [false, true])
    func skippedLeaveTakesNoSequence(tick: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: true, recording: true)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b")

        // An anchor: another player's join, recorded with sequence x.
        try await f.keeper.join(playerID: PlayerID("p0"), clientID: ClientID("c-0"), sessionID: SessionID("s-0"))
        await f.settle()

        // A takes x + 1 at its insert; B's kick of A must take none; B takes x + 2.
        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        try await f.join(clientB, SessionID("s-b"))
        gate.release()
        _ = await joinA.value
        await f.settle()

        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let sequences = await recorder.getAllFrames().flatMap { $0.lifecycleEvents.map(\.sequence) }
        let anchor = try #require(sequences.first)
        #expect(sequences == [anchor, anchor + 2], "tick=\(tick): recorded lifecycle sequences \(sequences)")
    }

    @Test("R4b: tick land, a second login after A's append but before the tick applies it: join A, leave A, join B", arguments: [false, true])
    func kickBetweenAppendAndApply(reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: true, reporting: reporting)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b")

        // A's resolvers end and its OnJoin is appended; no tick has applied it yet.
        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        gate.release()
        let errorA = await joinA.value
        #expect(errorA == nil, "A's join \(describe(errorA))")
        #expect(await f.log == [])

        // The append cleared A's pending mark: the kick appends A's OnLeave behind its OnJoin.
        try await f.join(clientB, SessionID("s-b"))
        await f.settle()

        let log = await f.log
        #expect(log == ["join:\(clientA.rawValue)", "leave:\(clientA.rawValue)", "join:\(clientB.rawValue)"], "reporting=\(reporting): log \(log)")
    }

    @Test("R7b: R1's shape replays: the gaps are stepped over, a later event keeps its sequence, and every state hash matches", arguments: [false, true])
    func replacedJoinReplays(tick: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: true, recording: true)
        let key = ReplacedJoinGates.freshKey()
        let gate = ReplacedJoinGates.gate(key)
        defer { gate.release() }
        let clientA = ClientID("gate-\(key)"), clientB = ClientID("c-b"), sessionB = SessionID("s-b")
        let path = tempRecordPath("r7b")
        defer { try? FileManager.default.removeItem(atPath: path) }

        let joinA = f.joinInTask(clientA, SessionID("s-a"))
        guard await gate.waitUntilEntered() else { return }
        try await f.join(clientB, sessionB)
        gate.release()
        #expect(isSuperseded(await joinA.value))
        await f.settle()
        // After A's dropped OnJoin: an event that takes the next sequence.
        try await f.emit(1, client: clientB, session: sessionB)
        await f.settle()
        #expect(await f.log == ["join:\(clientB.rawValue)", "emit:1"])

        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let recordedEvents = await recorder.getAllFrames().flatMap(\.serverEvents)
        #expect(recordedEvents.count == 1, "tick=\(tick): recorded events \(recordedEvents)")
        try await recorder.save(to: path)

        let result = try await ReevaluationEngine.run(
            definition: makeDefinition(tick: tick),
            initialState: ReplacedJoinState(),
            recordFilePath: path
        )
        #expect(result.serverEventVerification == .passed, "tick=\(tick): \(result.serverEventMismatches)")
        #expect(result.recordedPassMismatches.isEmpty, "tick=\(tick): \(result.recordedPassMismatches)")
        // A tick land records a state hash per tick; a tickless land's passes are checked
        // through `recordedPassMismatches` above.
        if tick { #expect(!result.recordedStateHashes.isEmpty) }
        for (tickId, recorded) in result.recordedStateHashes {
            #expect(result.tickHashes[tickId] == recorded, "tick=\(tick): state hash of tick \(tickId)")
        }
    }

    @Test("R8: a third login during the kick's OnLeave resolvers fences the kicking join out: join A, leave A, join C; B is superseded", arguments: [false, true], [false, true])
    func thirdLoginDuringTheKickFencesTheKickerOut(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let leaveKey = ReplacedJoinGates.freshKey(), joinKey = ReplacedJoinGates.freshKey(), actionKey = ReplacedJoinGates.freshKey()
        let leaveGate = ReplacedJoinGates.gate(leaveKey), joinGate = ReplacedJoinGates.gate(joinKey), actionGate = ReplacedJoinGates.gate(actionKey)
        defer { leaveGate.release(); joinGate.release(); actionGate.release() }
        let clientA = ClientID("lgate-\(leaveKey)"), clientB = ClientID("c-b"), clientC = ClientID("gate-\(joinKey)")
        let sessionB = SessionID("s-b"), sessionC = SessionID("s-c")

        try await f.join(clientA, SessionID("s-a"))
        await f.settle()

        // B kicks A: A's entry goes, and B waits in A's OnLeave resolvers.
        let joinB = f.joinInTask(clientB, sessionB)
        guard await leaveGate.waitUntilEntered() else { return }
        // C finds the slot empty, inserts its entry, and waits in its OnJoin resolvers; an
        // action of C's is a job held in its resolver.
        let joinC = f.joinInTask(clientC, sessionC)
        guard await joinGate.waitUntilEntered() else { return }
        guard let actionC = try await f.submitGated(actionKey, client: clientC, session: sessionC) else { return }
        guard await actionGate.waitUntilEntered() else { return }

        // B resumes: C arrived later, so B is refused, and C's entry is left as it is: its job
        // keeps running. C's OnJoin is held until B returns. In the other order, A's late
        // OnLeave would apply after C's OnJoin, and a handler that removes the player's state
        // would remove C's: that is #943, which a plain reconnect hits too.
        leaveGate.release()
        let errorB = await joinB.value
        #expect(isSuperseded(errorB), "B's join \(describe(errorB))")
        #expect(await f.keeper.actionSlotIsFilledForTesting(actionC) == false, "C's entry was kicked: its job was cancelled")

        joinGate.release()
        let errorC = await joinC.value
        #expect(errorC == nil, "C's join \(describe(errorC))")
        await f.settle()
        let log = await f.log
        #expect(log == ["join:\(clientA.rawValue)", "leave:\(clientA.rawValue)", "join:\(clientC.rawValue)"], "tick=\(tick) reporting=\(reporting): log \(log)")
        #expect(await f.keeper.playerCount() == 1)

        // C's job was never cancelled: it applies once its resolver ends.
        actionGate.release()
        await f.keeper.waitForActionJobsForTesting()
        await f.settle()
        #expect(await isRejected(f.keeper, actionC) == false)
        #expect(await f.log == ["join:\(clientA.rawValue)", "leave:\(clientA.rawValue)", "join:\(clientC.rawValue)", "action:\(actionKey)"])

        // C's entry joined: its own leave applies.
        try await f.keeper.leave(playerID: f.player, clientID: clientC, sessionID: sessionC)
        await f.settle()
        #expect(await f.log.last == "leave:\(clientC.rawValue)")
    }

    @Test("R10: a kick's leave held before it starts, while a newer login with the kicked entry's IDs replaces it, leaves the newer entry alone", arguments: [false, true], [false, true])
    func kicksLeaveIsScopedByGeneration(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let leaveHold = WatermarkGate()
        defer { leaveHold.release() }
        // The first `.leave` is B's kick of A; the second, C's, passes.
        await f.keeper.installHolds(HoldRegistry<LandKeeperHoldPoint>()
            .on(.leave, arrival: 1) { await leaveHold.enterAndWait() }
            .hook)
        let clientA = ClientID("c-a"), sessionA = SessionID("s-a"), clientB = ClientID("c-b")

        try await f.join(clientA, sessionA)
        await f.settle()

        // B kicks A; its leave of A's entry is held before it starts.
        let joinB = f.joinInTask(clientB, SessionID("s-b"))
        guard await leaveHold.waitUntilEntered("B's kick of A") else { return }
        // C, a reconnect with A's client and session IDs, kicks A, and takes the player with a
        // new entry carrying those IDs.
        let joinC = f.joinInTask(clientA, sessionA)
        // Bounded: B's held kick must not park C.
        guard let errorC = await valueWithinHangBound(joinC) else {
            Issue.record("C's join didn't end while B's kick was held")
            return
        }
        #expect(errorC == nil, "C's join \(describe(errorC))")
        await f.settle()
        #expect(await f.log == ["join:c-a", "leave:c-a", "join:c-a"])

        // B's leave names A's entry by its generation: the slot holds C's, whose IDs match but
        // whose generation doesn't, so it is left alone, and B is fenced out.
        leaveHold.release()
        let errorB = await joinB.value
        #expect(isSuperseded(errorB), "B's join \(describe(errorB))")
        await f.settle()
        let log = await f.log
        #expect(log == ["join:c-a", "leave:c-a", "join:c-a"], "tick=\(tick) reporting=\(reporting): log \(log)")
        #expect(await f.keeper.playerCount() == 1)
    }

    @Test("R11: the last of four logins wins whichever kick returns first: B kicks A, C takes the empty slot, D kicks C; A's leave returns before C's", arguments: [false, true], [false, true])
    func lastArrivalWinsAcrossTwoKicks(tick: Bool, reporting: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: reporting)
        let leaveAKey = ReplacedJoinGates.freshKey(), leaveCKey = ReplacedJoinGates.freshKey()
        let leaveAGate = ReplacedJoinGates.gate(leaveAKey), leaveCGate = ReplacedJoinGates.gate(leaveCKey)
        defer { leaveAGate.release(); leaveCGate.release() }
        let clientA = ClientID("lgate-\(leaveAKey)"), clientB = ClientID("c-b")
        let clientC = ClientID("lgate-\(leaveCKey)"), clientD = ClientID("c-d")
        let sessionC = SessionID("s-c"), sessionD = SessionID("s-d")

        try await f.join(clientA, SessionID("s-a"))
        await f.settle()

        // B kicks A, and waits in A's OnLeave resolvers.
        let joinB = f.joinInTask(clientB, SessionID("s-b"))
        guard await leaveAGate.waitUntilEntered("A's OnLeave") else { return }
        // C arrives after B, finds the slot empty and joins.
        guard let errorC = await valueWithinHangBound(f.joinInTask(clientC, sessionC)) else {
            Issue.record("C's join didn't end while B's kick was held")
            return
        }
        #expect(errorC == nil, "C's join \(describe(errorC))")
        await f.settle()
        // D arrives last, kicks C, and waits in C's OnLeave resolvers.
        let joinD = f.joinInTask(clientD, sessionD)
        guard await leaveCGate.waitUntilEntered("C's OnLeave") else { return }

        // A's leave returns first. The slot is empty, but D arrived after B: B is fenced out.
        leaveAGate.release()
        guard let errorB = await valueWithinHangBound(joinB) else {
            Issue.record("B's join didn't end")
            return
        }
        #expect(isSuperseded(errorB), "B's join \(describe(errorB))")

        // C's leave returns: D is the latest arrival and inserts.
        leaveCGate.release()
        guard let errorD = await valueWithinHangBound(joinD) else {
            Issue.record("D's join didn't end")
            return
        }
        #expect(errorD == nil, "D's join \(describe(errorD))")
        await f.settle()
        // B never joined; D's join is the last input. The order of A's OnLeave and C's OnJoin is
        // #943's (an OnLeave held in its resolvers is appended after a later entry's OnJoin), so
        // the rest of the log is checked as a set.
        let log = await f.log
        #expect(log.last == "join:\(clientD.rawValue)", "tick=\(tick) reporting=\(reporting): log \(log)")
        #expect(log.sorted() == [
            "join:\(clientA.rawValue)", "leave:\(clientA.rawValue)",
            "join:\(clientC.rawValue)", "leave:\(clientC.rawValue)",
            "join:\(clientD.rawValue)",
        ].sorted(), "tick=\(tick) reporting=\(reporting): log \(log)")
        #expect(await f.keeper.playerCount() == 1)
        #expect(await f.keeper.latestJoinArrivalsForTesting().isEmpty, "every attempt removed its token")
    }

    @Test("R9: A's OnJoin resolvers fail: an action submitted for A meanwhile is rejected at once, its resolver still held", arguments: [false, true])
    func failedOnJoinCancelsItsActionJobs(tick: Bool) async throws {
        let f = await ReplacedJoinFixture(tick: tick, reporting: true)
        let joinKey = ReplacedJoinGates.freshKey(), actionKey = ReplacedJoinGates.freshKey()
        let joinGate = ReplacedJoinGates.gate(joinKey), actionGate = ReplacedJoinGates.gate(actionKey)
        defer { joinGate.release(); actionGate.release() }
        let clientA = ClientID("fail-\(joinKey)"), sessionA = SessionID("s-a")

        let joinA = f.joinInTask(clientA, sessionA)
        guard await joinGate.waitUntilEntered() else { return }
        guard let action = try await f.submitGated(actionKey, client: clientA, session: sessionA) else { return }
        guard await actionGate.waitUntilEntered() else { return }

        // A's resolvers throw: the rollback removes A's entry and cancels its job.
        joinGate.release()
        let errorA = await joinA.value
        #expect(isResolverFailure(errorA), "A's join \(describe(errorA))")
        #expect(await f.keeper.actionSlotIsFilledForTesting(action), "the job kept its slot until its resolver ends")

        actionGate.release()
        #expect(await isRejected(f.keeper, action))
        await f.keeper.waitForActionJobsForTesting()
        #expect(await f.keeper.actionJobCountsForTesting().jobs == 0)
        await f.settle()
        #expect(await f.log == [])
    }
}
