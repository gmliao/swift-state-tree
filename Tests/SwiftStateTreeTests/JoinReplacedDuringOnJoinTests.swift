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
// K6 (#588) turns a duplicate login into a rebind; the invariant carries over, and so does
// this suite as its regression test.

import Foundation
import Testing
@testable import SwiftStateTree

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

enum ReplacedJoinGates {
    private static let keys = KeyedGates(firstKey: 11_000) { WatermarkGate() }
    static func freshKey() -> Int { keys.freshKey() }
    static func gate(_ key: Int, sourceLocation: SourceLocation = #_sourceLocation) -> WatermarkGate { keys.gate(key, sourceLocation: sourceLocation) }
}

/// A client ID "gate-<n>" waits on gate n; "fail-<n>" waits on gate n, then throws; any other
/// client passes.
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

private func makeDefinition(tick: Bool) -> LandDefinition<ReplacedJoinState> {
    if tick {
        return Land("replaced-join", using: ReplacedJoinState.self) {
            Rules {
                OnJoin(resolvers: ReplacedJoinResolver.self) { state, _, ctx in
                    state.log.append("join:\(ctx.clientID.rawValue)")
                }
                OnLeave { state, ctx in
                    state.log.append("leave:\(ctx.clientID.rawValue)")
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
    }
    return Land("replaced-join", using: ReplacedJoinState.self) {
        Rules {
            OnJoin(resolvers: ReplacedJoinResolver.self) { state, _, ctx in
                state.log.append("join:\(ctx.clientID.rawValue)")
            }
            OnLeave { state, ctx in
                state.log.append("leave:\(ctx.clientID.rawValue)")
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
}
