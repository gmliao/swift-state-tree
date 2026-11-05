// Tests/SwiftStateTreeTransportTests/TransportAdapterJoinFlipTests.swift
//
// A join that completes in a turn (#69, PR 4a): on the in-turn path with a JoinResponse
// builder, the session flips to joined in the commit of the first full sync phase after its
// OnJoin input was consumed and it registered with the transport: on a land with periodic sync,
// the sync phase of the tick turn that consumed the input, or the sync-only turn its
// registration requests if it registers after that. Its JoinResponse and firstSync
// are frames of that commit, after everyone else's, and the firstSync is the turn's end state,
// so OnJoin's changes are in it. Failures resolve the join's waiter with a reason.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct JoinFlipTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
}

@Payload
struct JoinFlipTestEvent: ServerEventPayload {
    let note: String
}

/// Records every frame with its target in `send`, in send order.
private actor FlipFrames: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [(data: Data, target: SwiftStateTreeTransport.EventTarget)] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        frames.append((message, target))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates { frames.append((data, target)) }
    }

    /// What `sessionID` received, in order: "joinResponse", "firstSync", "diff", "noChange",
    /// "event" or "other" (json encoding).
    func kinds(for sessionID: SessionID) -> [String] {
        frames.compactMap { frame -> String? in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            let decoder = JSONDecoder()
            if let message = try? decoder.decode(TransportMessage.self, from: frame.data) {
                switch message.kind {
                case .joinResponse: return "joinResponse"
                case .event: return "event"
                default: return "other"
                }
            }
            if let update = try? decoder.decode(StateUpdate.self, from: frame.data) {
                switch update {
                case .noChange: return "noChange"
                case .firstSync: return "firstSync"
                case .diff: return "diff"
                }
            }
            return "other"
        }
    }

    /// The `joins` value in `sessionID`'s firstSync, if it has one.
    func firstSyncJoins(for sessionID: SessionID) -> Int? {
        for frame in frames {
            guard case .session(let s) = frame.target, s == sessionID,
                  let update = try? JSONDecoder().decode(StateUpdate.self, from: frame.data),
                  case .firstSync(let patches) = update else { continue }
            for patch in patches where patch.path == "/joins" {
                if case .set(let value) = patch.operation, case .int(let joins) = value { return joins }
            }
        }
        return nil
    }
}

/// A flag tests flip from outside the adapter (the back-pressure override reads it).
private final class BackPressureSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

private struct Fixture {
    let keeper: LandKeeper<JoinFlipTestState>
    let adapter: TransportAdapter<JoinFlipTestState>
    let sent: FlipFrames
}

private struct OnJoinFailure: Error {}

/// `tick`: a land with an hourly tick and its loops started (periodic sync, stepped by hand);
/// otherwise tickless with no periodic sync. OnJoin throws for the player "bad".
private func makeFixture(tick: Bool, onJoin: Bool = true) async -> Fixture {
    let definition: LandDefinition<JoinFlipTestState>
    switch (tick, onJoin) {
    case (true, true):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            ServerEvents { Register(JoinFlipTestEvent.self) }
            Rules {
                OnJoin { (state: inout JoinFlipTestState, ctx: LandContext) in
                    if ctx.playerID.rawValue == "bad" { throw OnJoinFailure() }
                    state.joins += 1
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout JoinFlipTestState, _: LandContext) in }
            }
        }
    case (false, true):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            Rules {
                OnJoin { (state: inout JoinFlipTestState, ctx: LandContext) in
                    if ctx.playerID.rawValue == "bad" { throw OnJoinFailure() }
                    state.joins += 1
                }
            }
        }
    case (true, false):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            Rules {}
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout JoinFlipTestState, _: LandContext) in }
            }
        }
    case (false, false):
        definition = Land("join-flip", using: JoinFlipTestState.self) { Rules {} }
    }
    let sent = FlipFrames()
    // Tick lands start their loops (hourly, so they never fire in a test) to have periodic
    // sync; without loops a keeper has none, and its tick turns run the phase for joins.
    let keeper = LandKeeper(
        definition: definition,
        initialState: JoinFlipTestState(),
        autoStartLoops: tick
    )
    let adapter = TransportAdapter<JoinFlipTestState>(
        keeper: keeper,
        transport: sent,
        landID: "join-flip",
        inTurnSync: true
    )
    await sent.setDelegate(adapter)
    await keeper.setTransport(adapter)
    return Fixture(keeper: keeper, adapter: adapter, sent: sent)
}

private let joinResponseBuilder: @Sendable (PlayerID, Int32) -> Data? = { playerID, slot in
    try? JSONEncoder().encode(TransportMessage.joinResponse(
        requestID: "r-\(playerID.rawValue)",
        success: true,
        playerID: playerID.rawValue,
        playerSlot: slot,
        encoding: "json"
    ))
}

/// A join through the in-turn path (with a JoinResponse builder): returns once it flipped.
private func joinInTurn(_ fixture: Fixture, session: SessionID, player: PlayerID) async throws -> TransportAdapter<JoinFlipTestState>.JoinResult {
    let client = ClientID("c-\(session.rawValue)")
    await fixture.adapter.onConnect(sessionID: session, clientID: client)
    let result = try await fixture.adapter.performJoin(
        playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
        clientID: client,
        sessionID: session,
        authInfo: nil,
        joinResponse: joinResponseBuilder
    )
    return try #require(result)
}

/// Waits (bounded, not a timing assertion) until `condition` holds.
private func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await safeTaskSleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)")
}

@Suite(
    "Join completes in a turn (#69)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: these tests check the in-turn path")
)
struct TransportAdapterJoinFlipTests {
    @Test("Tickless land: the join returns after its flip; JoinResponse, then a firstSync with OnJoin applied")
    func ticklessJoinFlips() async throws {
        let fixture = await makeFixture(tick: false)
        let s1 = SessionID("s1")
        let result = try await joinInTurn(fixture, session: s1, player: PlayerID("p1"))
        #expect(result.completedInTurn)
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
        #expect(await fixture.sent.firstSyncJoins(for: s1) == 1)
        #expect(await fixture.adapter.isJoining(s1) == false)
        #expect(await fixture.adapter.inTurnJoinFlips == 1)
        #expect(await fixture.keeper.currentState().joins == 1)
    }

    @Test("Tickless land without OnJoin: the join flips in the sync-only turn its registration requests")
    func ticklessJoinWithoutOnJoinFlips() async throws {
        let fixture = await makeFixture(tick: false, onJoin: false)
        let s1 = SessionID("s1")
        _ = try await joinInTurn(fixture, session: s1, player: PlayerID("p1"))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test("Periodic land: the tick that consumes OnJoin flips the join in that turn's sync phase, after everyone's frames")
    func periodicJoinFlipsInTheConsumingTick() async throws {
        let fixture = await makeFixture(tick: true)
        let s0 = SessionID("s0"), s1 = SessionID("s1")
        // A first member, flipped by a sync of its own.
        let first = Task { try await joinInTurn(fixture, session: s0, player: PlayerID("p0")) }
        await eventually("s0 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s0) }
        await fixture.keeper.stepTickOnce()
        _ = try await first.value
        #expect(await fixture.adapter.waitForOutboundDrain())

        let second = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        // The tick consumes the OnJoin input; no sync is due by the cadence, and the ready join
        // runs the turn's sync phase, which flips it. No periodic sync runs in this test.
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.currentState().joins == 2)
        #expect(!(await fixture.adapter.isJoiningInTurn(s1)), "flipped by the tick turn itself")
        _ = try await second.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
        #expect(await fixture.sent.firstSyncJoins(for: s1) == 2)
        // The member's diff of that commit comes before the joiner's frames.
        let frames = await fixture.sent.frames
        let s0Last = frames.lastIndex { if case .session(let s) = $0.target { return s == s0 } else { return false } }
        let s1First = frames.firstIndex { if case .session(let s) = $0.target { return s == s1 } else { return false } }
        #expect(try #require(s0Last) < (try #require(s1First)))
    }

    @Test("OnJoin throws: the join fails with onJoinFailed at once, and the session got nothing")
    func onJoinThrowFailsTheJoin() async throws {
        let fixture = await makeFixture(tick: false)
        let s1 = SessionID("s1")
        await #expect(throws: JoinFlipError.onJoinFailed) {
            _ = try await joinInTurn(fixture, session: s1, player: PlayerID("bad"))
        }
        #expect(await fixture.keeper.playerCount() == 0)
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await fixture.adapter.inTurnJoinFailures[.onJoinFailed] == 1)
    }

    @Test("No committed sync within the flip timeout: the join fails with timeout")
    func joinTimesOut() async throws {
        let fixture = await makeFixture(tick: true)
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: .milliseconds(50), budget: nil)
        let s1 = SessionID("s1")
        await #expect(throws: JoinFlipError.timeout) {
            _ = try await joinInTurn(fixture, session: s1, player: PlayerID("p1"))
        }
        // It never flips later.
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.runSyncLoopIterationForTesting()
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
    }

    @Test("A newer join of the player supersedes a joining session; the newer one flips")
    func newerJoinSupersedes() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1"), s2 = SessionID("s2"), p = PlayerID("p")
        let first = Task { try await joinInTurn(fixture, session: s1, player: p) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        let second = Task { try await joinInTurn(fixture, session: s2, player: p) }
        await #expect(throws: JoinFlipError.superseded) { _ = try await first.value }
        await eventually("s2 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s2) }
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.runSyncLoopIterationForTesting()
        _ = try await second.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await fixture.sent.kinds(for: s2) == ["joinResponse", "firstSync"])
    }

    @Test("A disconnect while joining fails the join with disconnected")
    func disconnectWhileJoining() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.adapter.onDisconnect(sessionID: s1, clientID: ClientID("c-s1"))
        await #expect(throws: JoinFlipError.disconnected) { _ = try await join.value }
    }

    @Test("Flip budget: ready joins flip first in, first out, at most the budget per commit; the tick's commit is the first")
    func flipBudgetIsFIFO() async throws {
        let fixture = await makeFixture(tick: true)
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: nil, budget: 2)
        let sessions = (1...5).map { SessionID("s\($0)") }
        var joins: [Task<TransportAdapter<JoinFlipTestState>.JoinResult, any Error>] = []
        for (index, session) in sessions.enumerated() {
            joins.append(Task { try await joinInTurn(fixture, session: session, player: PlayerID("p\(index)")) })
            await eventually("\(session) registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(session) }
        }
        // The tick consumes all five OnJoin inputs; its sync phase flips the first two. The
        // leftovers wait for the periodic syncs (stepped here).
        var flippedPerCommit: [Int] = []
        let beforeTick = await fixture.adapter.inTurnJoinFlips
        await fixture.keeper.stepTickOnce()
        flippedPerCommit.append(await fixture.adapter.inTurnJoinFlips - beforeTick)
        for _ in 0..<2 {
            // A commit's frames still in the writer defer the next sync-only turn (back
            // pressure); a stepped sync after a drain always runs.
            #expect(await fixture.adapter.waitForOutboundDrain())
            let before = await fixture.adapter.inTurnJoinFlips
            await fixture.keeper.runSyncLoopIterationForTesting()
            flippedPerCommit.append(await fixture.adapter.inTurnJoinFlips - before)
        }
        #expect(flippedPerCommit == [2, 2, 1], "flipped per commit: \(flippedPerCommit)")
        for join in joins { _ = try await join.value }
        #expect(await fixture.adapter.waitForOutboundDrain())
        // FIFO: each JoinResponse goes out in admission order.
        let frames = await fixture.sent.frames
        let order = sessions.map { session in
            frames.firstIndex { if case .session(let s) = $0.target { return s == session } else { return false } } ?? -1
        }
        #expect(order == order.sorted())
    }

    @Test("Tickless land over the budget: leftover joins flip in follow-up sync-only turns")
    func ticklessLeftoversFlip() async throws {
        let fixture = await makeFixture(tick: false)
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: nil, budget: 1)
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<4 {
                group.addTask { _ = try await joinInTurn(fixture, session: SessionID("s\(index)"), player: PlayerID("p\(index)")) }
            }
            try await group.waitForAll()
        }
        #expect(await fixture.adapter.inTurnJoinFlips == 4)
    }

    @Test("A failed flip commit commits nothing for the joiner; the next committed sync flips it")
    func failedPlanRetriesTheFlip() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        // The tick's sync phase (run for the ready join) fails: the join stays joining.
        await fixture.adapter.setSyncPlanFaultForTesting { throw OnJoinFailure() }
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.currentState().joins == 1)
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        await fixture.adapter.setSyncPlanFaultForTesting(nil)
        await fixture.keeper.runSyncLoopIterationForTesting()
        _ = try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test("Tickless land whose plan keeps failing: the join retries back off, doubling, and it flips once a plan commits")
    func failingPlanRetriesBackOff() async throws {
        let fixture = await makeFixture(tick: false)
        await fixture.adapter.setSyncPlanFaultForTesting { throw OnJoinFailure() }
        let join = Task { try await joinInTurn(fixture, session: SessionID("s1"), player: PlayerID("p1")) }
        // Past the repair limit the retries back off, doubling from 100 ms, so a plan that keeps
        // failing gives a bounded number of turns before the join's timeout.
        await eventually("three retries scheduled") {
            await fixture.keeper.joinSyncRetryDelaysForTesting.count >= 3
        }
        let delays = await fixture.keeper.joinSyncRetryDelaysForTesting
        #expect(Array(delays.prefix(3)) == [.milliseconds(100), .milliseconds(200), .milliseconds(400)])
        // Once a plan commits again, the next retry flips the join.
        await fixture.adapter.setSyncPlanFaultForTesting(nil)
        let result = try await join.value
        #expect(result.completedInTurn)
    }

    @Test("Not registered with the transport yet: a consumed join doesn't flip until it is; its registration then flips it in a sync-only turn")
    func flipWaitsForRegistration() async throws {
        let fixture = await makeFixture(tick: true)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.registerSession) { await gate.arrive() })
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at registerSession") { gate.arrivalCount == 1 }
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.runSyncLoopIterationForTesting()
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        // No periodic sync or tick runs from here on: the registration requests the sync-only
        // turn that flips it.
        gate.open()
        await fixture.adapter.installHolds(nil)
        _ = try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test("A session-targeted event before the flip doesn't reach the joining session")
    func sessionEventBeforeFlipIsNotDelivered() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.adapter.sendEvent(AnyServerEvent(JoinFlipTestEvent(note: "early")), to: .session(s1))
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.runSyncLoopIterationForTesting()
        _ = try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 1, "the dropped event is counted")
    }

    @Test("Periodic land under writer back-pressure: a deferred join sync isn't retried every tick; the next periodic sync flips it")
    func joinSyncUnderBackPressureWaitsForThePeriodicSync() async throws {
        let fixture = await makeFixture(tick: true)
        let s0 = SessionID("s0"), s1 = SessionID("s1"), s2 = SessionID("s2")
        let first = Task { try await joinInTurn(fixture, session: s0, player: PlayerID("p0")) }
        await eventually("s0 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s0) }
        await fixture.keeper.stepTickOnce()
        _ = try await first.value
        #expect(await fixture.adapter.waitForOutboundDrain())

        let pressured = BackPressureSwitch()
        pressured.set(true)
        await fixture.adapter.setWriterBackPressureOverrideForTesting { pressured.isOn }
        let second = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        let deferredBefore = await fixture.keeper.inTurnDeferredTurns
        // The tick's join sync is deferred: counted once, and the join waits.
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.inTurnDeferredTurns == deferredBefore + 1)
        #expect(await fixture.keeper.joinSyncWaitsForCommit)
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        // Neither later ticks nor another join's registration run a join sync again (each
        // would be deferred and counted).
        let third = Task { try await joinInTurn(fixture, session: s2, player: PlayerID("p2")) }
        await eventually("s2 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s2) }
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.inTurnDeferredTurns == deferredBefore + 1, "one deferral per back-pressure episode")
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        #expect(await fixture.adapter.isJoiningInTurn(s2))

        // The writer drains: the periodic sync commits and flips both, in admission order.
        pressured.set(false)
        await fixture.keeper.runSyncLoopIterationForTesting()
        _ = try await second.value
        _ = try await third.value
        #expect(!(await fixture.keeper.joinSyncWaitsForCommit))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
        #expect(await fixture.sent.kinds(for: s2) == ["joinResponse", "firstSync"])
        #expect(await fixture.sent.firstSyncJoins(for: s2) == 3)
    }

    @Test("Tickless land: a join that becomes ready during a debug freeze flips after the resume")
    func joinReadyDuringFreezeFlipsAfterResume() async throws {
        let fixture = await makeFixture(tick: false)
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: .seconds(3), budget: nil)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.registerSession) { await gate.arrive() })
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at registerSession") { gate.arrivalCount == 1 }

        let freeze = try await fixture.adapter.debugFreeze()
        gate.open()
        await fixture.adapter.installHolds(nil)
        await eventually("s1 ready") { await fixture.adapter.hasJoinsAwaitingSyncForTesting() }
        // The join's sync-only turn runs while frozen and is skipped.
        await fixture.keeper.requestJoinSyncTurn()
        #expect(await fixture.adapter.isJoiningInTurn(s1))

        _ = await fixture.adapter.debugResume(freezeToken: freeze.freezeToken)
        let result = try await join.value
        #expect(result.completedInTurn)
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }
}
