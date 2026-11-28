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
import SwiftStateTreeTestSupport
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

private struct SyncPlanFault: Error {}
private struct FirstSyncFault: Error {}

/// `tick`: a land with an hourly tick and its loops started (periodic sync, stepped by hand);
/// otherwise tickless with no periodic sync.
private func makeFixture(tick: Bool, onJoin: Bool = true) async -> Fixture {
    let definition: LandDefinition<JoinFlipTestState>
    switch (tick, onJoin) {
    case (true, true):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            ServerEvents { Register(JoinFlipTestEvent.self) }
            Rules {
                OnJoin { state, ctx in
                    state.joins += 1
                }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
    case (false, true):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            Rules {
                OnJoin { state, ctx in
                    state.joins += 1
                }
            }
        }
    case (true, false):
        definition = Land("join-flip", using: JoinFlipTestState.self) {
            Rules {}
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
        }
    case (false, false):
        definition = Land("join-flip", using: JoinFlipTestState.self) { Rules {} }
    }
    let sent = FlipFrames()
    // Tick lands start their loops (hourly, so they never fire in a test) to have periodic
    // sync; without loops a keeper has none, and its tick turns run the phase for joins.
    // A tick land's fixture returns once its tick loop has written its first deadline, so a
    // test's `setNextTickDeadlineForTesting` isn't overwritten by the loop's (#335).
    let firstTickSleep = FirstTickSleepSignal()
    let keeper = TickLoopClock.$forNewKeepers.withValue(tick ? firstTickSleep.tickLoopClock : .continuous) {
        LandKeeper(
            definition: definition,
            initialState: JoinFlipTestState(),
            autoStartLoops: tick
        )
    }
    let adapter = TransportAdapter<JoinFlipTestState>(
        keeper: keeper,
        transport: sent,
        landID: "join-flip"
    )
    await sent.setDelegate(adapter)
    // The freeze tests assert, while frozen, that a ready join hasn't flipped: no deadline may
    // fire inside that window, or the auto-resume flips it first. No test here tests a deadline.
    await adapter.setDebugFreezeSettleDeadline(freezeWithoutDeadline)
    await adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
    await keeper.setTransport(adapter)
    if tick { await firstTickSleep.waitUntilReached() }
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
    "Join completes in a turn (#69)"
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
        let joinTicksBefore = await fixture.keeper.joinSyncTicks
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.currentState().joins == 2)
        #expect(!(await fixture.adapter.isJoiningInTurn(s1)), "flipped by the tick turn itself")
        #expect(await fixture.keeper.joinSyncTicks == joinTicksBefore + 1, "counted as a join sync tick")
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

    @Test("A failed flip commit ends the land (#535 row 15): nothing reaches the joiner, and its join fails")
    func failedFlipPlanEndsTheLand() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        // The tick's sync phase (run for the ready join) throws: the first throw ends the land.
        await fixture.adapter.setSyncPlanFaultForTesting { throw SyncPlanFault() }
        await fixture.keeper.stepTickOnce()
        #expect(fixture.keeper.failure?.kind == .syncPlan)
        #expect(fixture.keeper.destructionCause == .failed)
        await fixture.keeper.waitUntilDrained()
        await #expect(throws: (any Error).self) { _ = try await join.value }
        #expect(await fixture.sent.kinds(for: s1) == [], "no joinResponse or firstSync from the failed plan")
    }

    @Test("Tickless land: a plan that throws while a join waits ends the land at once, with no retry (#535 row 15)")
    func failingPlanOnTicklessJoinEndsTheLand() async throws {
        let fixture = await makeFixture(tick: false)
        await fixture.adapter.setSyncPlanFaultForTesting { throw SyncPlanFault() }
        let join = Task { try await joinInTurn(fixture, session: SessionID("s1"), player: PlayerID("p1")) }
        await #expect(throws: (any Error).self) { _ = try await join.value }
        #expect(fixture.keeper.failure?.kind == .syncPlan)
        #expect(await fixture.keeper.joinSyncTurnsForTesting == 0, "no join-sync retry turn")
    }

    @Test("Not registered with the transport yet: a consumed join doesn't flip until it is; its registration then flips it in a sync-only turn")
    func flipWaitsForRegistration() async throws {
        let fixture = await makeFixture(tick: true)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.keeperJoinReturned) { await gate.arrive() })
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at keeperJoinReturned") { gate.arrivalCount == 1 }
        #expect(await fixture.adapter.admittedNotRegisteredForTesting(s1), "admitted, not registered (#555)")
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
        #expect(await !fixture.adapter.admittedNotRegisteredForTesting(s1))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test("At joinSyncRequested an in-turn join is registered and not flipped; its sync-only turn flips it after release (#555)")
    func joinSyncRequestedIsRegisteredNotFlipped() async throws {
        // Tickless: the join's own turn consumes its OnJoin, so only the sync turn is missing.
        let fixture = await makeFixture(tick: false)
        // The join-commit observations record only in DEBUG builds (#748); the rest runs in release too.
        #if DEBUG
        await fixture.adapter.captureJoinCommitsForTesting()
        #endif
        let returned = TestGate()
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.keeperJoinReturned) { await returned.arrive() }
            .on(.joinSyncRequested) { await gate.arrive() }
            .hook)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        // The turn that applies OnJoin ends before the registration: a turn after it would run
        // a sync phase that flips the registered join before `joinSyncRequested`.
        #expect(await returned.waitForArrivals(1), "the join reached keeperJoinReturned")
        await fixture.keeper.waitForInputDrainIdleForTesting()
        returned.open()
        #expect(await gate.waitForArrivals(1), "the join reached joinSyncRequested")
        #expect(await fixture.adapter.isInTurnJoinRegisteredForTesting(s1), "registered with the transport")
        #expect(await fixture.adapter.isJoiningInTurn(s1), "not flipped")
        // The named observations (#555), keyed by the attempt (no router attempt number here).
        #expect(await !fixture.adapter.admittedNotRegisteredForTesting(s1), "registered")
        #if DEBUG
        let attempt = TransportAdapter<JoinFlipTestState>.JoinAttemptKey(sessionID: s1, attempt: nil)
        #expect(await !fixture.adapter.joinFlippedForTesting(attempt))
        #expect(await !fixture.adapter.initialSyncCommittedForTesting(attempt))
        #endif
        await fixture.adapter.waitForOutboundIdleForTesting()
        #expect(await fixture.sent.kinds(for: s1) == [])
        gate.open()
        await fixture.adapter.installHolds(nil)
        _ = try await join.value
        #expect(await !fixture.adapter.isJoiningInTurn(s1), "the sync-only turn flipped it")
        #if DEBUG
        #expect(await fixture.adapter.joinFlippedForTesting(attempt))
        #expect(await fixture.adapter.initialSyncCommittedForTesting(attempt))
        #expect(await !fixture.adapter.joinFlippedForTesting(.init(sessionID: s1, attempt: 7)), "keyed by the attempt")
        #endif

        // A session ticket token (#555): current while joined, not after a teardown.
        let ticket = try #require(await fixture.adapter.sessionTicketForTesting(s1))
        #expect(await fixture.adapter.ticketIsCurrentForTesting(ticket))
        await fixture.adapter.endSessionTicketsForTeardown()
        #expect(await !fixture.adapter.ticketIsCurrentForTesting(ticket))
        await fixture.adapter.waitForOutboundIdleForTesting()
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test("A session-targeted event before the flip is held and follows the joiner's firstSync")
    func sessionEventBeforeFlipIsHeld() async throws {
        let fixture = await makeFixture(tick: true)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.adapter.sendEvent(AnyServerEvent(JoinFlipTestEvent(note: "early")), to: .session(s1))
        await fixture.keeper.stepTickOnce()
        await fixture.keeper.runSyncLoopIterationForTesting()
        _ = try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync", "event"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 0)
        #expect(await fixture.adapter.eventsHeldForJoiningSessions == 1)
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

    @Test("Periodic land: a registration inside the fold window doesn't run the folded sync ahead of the tick; the tick flips the join")
    func registrationInFoldWindowWaitsForTheTick() async throws {
        let fixture = await makeFixture(tick: true)
        let s0 = SessionID("s0"), s1 = SessionID("s1")
        let first = Task { try await joinInTurn(fixture, session: s0, player: PlayerID("p0")) }
        await eventually("s0 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s0) }
        await fixture.keeper.stepTickOnce()
        _ = try await first.value
        #expect(await fixture.adapter.waitForOutboundDrain())

        // s1's OnJoin is consumed by a tick while its registration is held.
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.keeperJoinReturned) { await gate.arrive() })
        let second = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at keeperJoinReturned") { gate.arrivalCount == 1 }
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.keeper.currentState().joins == 2)
        #expect(await fixture.adapter.isJoiningInTurn(s1))

        // The sync loop fires inside the coincident window of the next tick: it folds.
        let now = ContinuousClock.now
        await fixture.keeper.setNextTickDeadlineForTesting(now + .milliseconds(1))
        await fixture.keeper.runSyncLoopIterationForTesting(at: now)
        #expect(await fixture.keeper.foldedSyncs == 1)
        #expect(await fixture.keeper.inTurnSyncDueForTesting)
        #expect(await fixture.adapter.waitForOutboundDrain())
        let beforeRegistration = await fixture.sent.frames.count

        // Registration finishes; its sync-only turn request (made again here, so the check
        // doesn't depend on when the adapter's own one runs) must not take the folded sync.
        gate.open()
        await fixture.adapter.installHolds(nil)
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.keeper.requestJoinSyncTurn()
        #expect(await fixture.keeper.inTurnSyncDueForTesting, "the folded sync still waits for the tick")
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.frames.count == beforeRegistration, "no frame ahead of the tick")

        // The tick turn runs the folded (cadence) sync, which flips the join.
        let joinTicksBefore = await fixture.keeper.joinSyncTicks
        await fixture.keeper.stepTickOnce()
        _ = try await second.value
        #expect(!(await fixture.keeper.inTurnSyncDueForTesting))
        #expect(await fixture.keeper.joinSyncTicks == joinTicksBefore, "a cadence sync, not a join sync tick")
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync"])
    }

    @Test(
        "Tickless land: a join that becomes ready during a debug freeze flips after the resume",
        .timeLimit(.minutes(1))
    )
    func joinReadyDuringFreezeFlipsAfterResume() async throws {
        let fixture = await makeFixture(tick: false)
        // No flip timeout: the join waits out the freeze, which may outlast any wall-clock
        // bound on a stalled runner. The time limit bounds a join that never flips.
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.keeperJoinReturned) { await gate.arrive() })
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at keeperJoinReturned") { gate.arrivalCount == 1 }

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
    // MARK: - The in-turn resume (#546 L2b, plan §3.4)

    @Test("Resume, writer free: the deferred sync's phase flips the ready join; no join-sync turn")
    func resumeFlipsReadyJoinInItsOwnPhase() async throws {
        let f = await makeFixture(tick: false)
        let ready = try await readyUnflippedJoin(f, session: SessionID("s1"), player: PlayerID("p1"))
        let freeze = try await f.adapter.debugFreeze()
        await f.adapter.syncNow()
        #expect(await f.adapter.debugFreezeState.deferredSyncNow, "the frozen sync is left to the resume")

        let before = await f.keeper.joinSyncRequestTurnsForTesting
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(await f.keeper.joinSyncRequestTurnsForTesting == before, "step 1 flipped it: step 2 requested nothing")
        try #require(await !f.adapter.isJoiningInTurn(ready.session))

        #expect(try await ready.finish(f))
        let outbound = f.adapter
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        #expect(await f.sent.kinds(for: ready.session) == ["joinResponse", "firstSync"])
    }

    @Test("Resume, no deferred sync: step 2's join-sync turn flips the ready join")
    func resumeJoinSyncTurnFlipsReadyJoin() async throws {
        let f = await makeFixture(tick: false)
        let ready = try await readyUnflippedJoin(f, session: SessionID("s1"), player: PlayerID("p1"))
        let freeze = try await f.adapter.debugFreeze()
        #expect(await !f.adapter.debugFreezeState.deferredSyncNow, "no sync was asked while frozen")

        let before = await f.keeper.joinSyncRequestTurnsForTesting
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(await f.keeper.joinSyncRequestTurnsForTesting == before + 1, "step 2 ran its join-sync turn")
        try #require(await !f.adapter.isJoiningInTurn(ready.session))

        #expect(try await ready.finish(f))
        let outbound = f.adapter
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        #expect(await f.sent.kinds(for: ready.session) == ["joinResponse", "firstSync"])
    }

    @Test("Tickless land: a freeze's settle plans no joiner; a ready join stays unflipped until the resume flips it (#546 L2d-1)")
    func settlePlansNoJoiner() async throws {
        let f = await makeFixture(tick: false)
        // A joined member, so the land isn't empty and the settle's phase runs.
        let member = SessionID("s0")
        _ = try await joinInTurn(f, session: member, player: PlayerID("p0"))
        let ready = try await readyUnflippedJoin(f, session: SessionID("s1"), player: PlayerID("p1"))
        let freeze = try await f.adapter.debugFreeze()
        let outbound = f.adapter
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        // The settle passes no joiners to its phase: the join is still joining, and its session
        // got neither a JoinResponse nor a firstSync.
        #expect(await f.adapter.isJoiningInTurn(ready.session), "the settle flipped the ready join")
        #expect(await f.sent.kinds(for: ready.session).isEmpty, "the settle sent frames to the joiner")

        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        try #require(await !f.adapter.isJoiningInTurn(ready.session), "the resume didn't flip the join")
        #expect(try await ready.finish(f))
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        #expect(await f.sent.kinds(for: ready.session) == ["joinResponse", "firstSync"])
    }

    @Test("Resume, writer held, no periodic sync: step 2 is skipped; the writer-drain retry flips the join")
    func resumeLeavesJoinToTheDrainRetry() async throws {
        let f = await makeFixture(tick: false)
        let ready = try await readyUnflippedJoin(f, session: SessionID("s1"), player: PlayerID("p1"))
        let freeze = try await f.adapter.debugFreeze()
        await f.adapter.syncNow()

        await f.adapter.setWriterBackPressureOverrideForTesting { true }
        let before = await f.keeper.joinSyncRequestTurnsForTesting
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(await f.keeper.joinSyncRequestTurnsForTesting == before, "step 1 deferred: no second phase to defer again")
        #expect(await f.adapter.isJoiningInTurn(ready.session), "nothing flipped it yet")
        #expect(await f.adapter.keeperHasRequestedSyncWorkForTesting(), "the writer-drain retry is armed")

        await f.adapter.setWriterBackPressureOverrideForTesting(nil)
        let adapter = f.adapter
        #expect(await withinHangBound { await adapter.waitForKeeperRequestedSyncWorkForTesting() }, "the retry never ran")
        try #require(await !f.adapter.isJoiningInTurn(ready.session), "the retry's phase flipped the join")

        #expect(try await ready.finish(f))
        let outbound = f.adapter
        #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
        #expect(await f.sent.kinds(for: ready.session) == ["joinResponse", "firstSync"])
    }

    @Test("Resume, writer held, periodic land: step 2 is skipped; the next periodic phase flips the join")
    func resumeLeavesJoinToThePeriodicPhase() async throws {
        let f = await makeFixture(tick: true)
        // No flip wait: the join is held across the freeze and the resume.
        await f.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        let returned = TestGate(), joinGate = TestGate()
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.keeperJoinReturned) { await returned.arrive() }
            .on(.joinSyncRequested) { await joinGate.arrive() }
            .hook)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(f, session: s1, player: PlayerID("p1")) }
        // A tick land consumes the join's input in a tick turn: run it while the join is
        // admitted and not registered, so that tick's phase can't flip it.
        try #require(await returned.waitForArrivals(1), "the keeper join didn't return")
        await f.keeper.stepTickOnce()
        returned.open()
        try #require(await joinGate.waitForArrivals(1), "the join didn't register")
        try #require(await f.adapter.hasJoinsAwaitingSyncForTesting(), "a ready, unflipped join")
        let freeze = try await f.adapter.debugFreeze()
        await f.adapter.syncNow()

        await f.adapter.setWriterBackPressureOverrideForTesting { true }
        let before = await f.keeper.joinSyncRequestTurnsForTesting
        let resumesBefore = await f.keeper.requestedSyncTurnsForTesting[.resume, default: 0]
        _ = await f.adapter.debugResume(freezeToken: freeze.freezeToken)
        #expect(await f.keeper.requestedSyncTurnsForTesting[.resume, default: 0] == resumesBefore + 1, "step 1 ran")
        // Required, not expected: the flip timeout is off, so a join left in a wrong state would
        // hang the test at `join.value` instead of failing here.
        try #require(await f.keeper.joinSyncRequestTurnsForTesting == before, "step 1 deferred: step 2 skipped")
        try #require(await f.adapter.isJoiningInTurn(s1))

        await f.adapter.setWriterBackPressureOverrideForTesting(nil)
        await f.keeper.stepTickOnce()
        try #require(await !f.adapter.isJoiningInTurn(s1), "the periodic phase flipped the join")

        joinGate.open()
        await f.adapter.installHolds(nil)
        #expect(try await join.value.completedInTurn)
    }

    @Test("Resume, frozen again between step 1 and step 2: step 2 waits for the next resume")
    func resumeSkipsJoinSyncAfterARefreeze() async throws {
        let f = await makeFixture(tick: false)
        let resumeGate = TestGate()
        let ready = try await readyUnflippedJoin(f, session: SessionID("s1"), player: PlayerID("p1")) {
            $0.on(.resumeAfterSync, arrival: 1) { await resumeGate.arrive() }
        }
        let first = try await f.adapter.debugFreeze()

        let before = await f.keeper.joinSyncRequestTurnsForTesting
        let adapter = f.adapter
        let resume = Task { await adapter.debugResume(freezeToken: first.freezeToken) }
        #expect(await resumeGate.waitForArrivals(1), "the resume didn't reach step 2")
        let second = try await f.adapter.debugFreeze()
        resumeGate.open()
        _ = await resume.value
        #expect(await f.keeper.joinSyncRequestTurnsForTesting == before, "no join-sync turn while frozen again")
        #expect(await f.adapter.isJoiningInTurn(ready.session))

        _ = await f.adapter.debugResume(freezeToken: second.freezeToken)
        #expect(await f.keeper.joinSyncRequestTurnsForTesting == before + 1, "the next resume requested it")
        try #require(await !f.adapter.isJoiningInTurn(ready.session))

        #expect(try await ready.finish(f))
    }
}

/// An in-turn join on a land without periodic sync, registered and ready to flip but not
/// flipped: held at `.keeperJoinReturned` until the keeper's input drain (its OnJoin turn) is
/// idle, so no input turn's phase flips it after it registers, then held at
/// `.joinSyncRequested`, before its own join-sync request. `extra` adds holds to the same
/// registry. `finish` opens the hold, removes the holds and returns whether the join completed
/// in a turn.
private struct ReadyJoin {
    let session: SessionID
    let gate: TestGate
    let task: Task<TransportAdapter<JoinFlipTestState>.JoinResult, any Error>

    func finish(_ f: Fixture) async throws -> Bool {
        gate.open()
        await f.adapter.installHolds(nil)
        return try await task.value.completedInTurn
    }
}

private func readyUnflippedJoin(
    _ f: Fixture,
    session: SessionID,
    player: PlayerID,
    extra: (HoldRegistry<TransportAdapterHoldPoint>) -> HoldRegistry<TransportAdapterHoldPoint> = { $0 }
) async throws -> ReadyJoin {
    // No flip wait: the join is held across freezes and resumes.
    await f.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
    let returned = TestGate(), requested = TestGate()
    await f.adapter.installHolds(extra(HoldRegistry<TransportAdapterHoldPoint>()
        .on(.keeperJoinReturned) { await returned.arrive() }
        .on(.joinSyncRequested) { await requested.arrive() })
        .hook)
    let task = Task { try await joinInTurn(f, session: session, player: player) }
    try #require(await returned.waitForArrivals(1), "the keeper join didn't return")
    let keeper = f.keeper
    try #require(await withinHangBound { await keeper.waitForInputDrainIdleForTesting() }, "the OnJoin turn never ran")
    returned.open()
    try #require(await requested.waitForArrivals(1), "the join didn't register")
    return ReadyJoin(session: session, gate: requested, task: task)
}

// MARK: - A failure noted outside a turn (#704)

/// A join on a tick land, held once it registered, and flipped by the tick that consumes its
/// OnJoin input.
private func joinOnTickLand(_ f: Fixture, session: SessionID, player: PlayerID) async throws {
    let registered = TestGate()
    await f.adapter.installHolds(HoldRegistry.at(.joinSyncRequested) { await registered.arrive() })
    let join = Task { try await joinInTurn(f, session: session, player: player) }
    try #require(await registered.waitForArrivals(1), "\(session.rawValue) registered")
    await f.keeper.stepTickOnce()
    registered.open()
    await f.adapter.installHolds(nil)
    #expect(try await join.value.completedInTurn, "the tick flipped the join")
    let outbound = f.adapter
    #expect(await withinHangBound { await outbound.waitForOutboundIdleForTesting() })
}


@Suite("A join and a rebind after an adapter noted a failure (#704)", .serialized, .timeLimit(.minutes(1)))
struct JoinFlipAfterNotedFailureTests {
    @Test("a join waiting for its flip doesn't flip after an adapter noted a failure (#704, plan test 5)")
    func waitingJoinDoesNotFlip() async throws {
        let f = await makeFixture(tick: false)
        let s1 = SessionID("s1")
        let submit = TestGate()
        let ready = try await readyUnflippedJoin(f, session: s1, player: PlayerID("p1")) {
            $0.on(.failureSubmit) { await submit.arrive() }
        }
        let failing = Task { await f.adapter.failOutsideTurn(notedFailure) }
        try #require(await submit.waitForArrivals(1), "the failure holds before its submit")
        // The join's own join-sync turn runs now: it ends the land before its phase.
        let completed = try? await ready.finish(f)
        #expect(completed != true, "the join didn't flip")
        #expect(f.keeper.failure?.kind == .responseEncode, "the noted failure: \(String(describing: f.keeper.failure))")
        #expect(await !f.sent.kinds(for: s1).contains("joinResponse"), "no JoinResponse")
        submit.open()
        await failing.value
        await f.keeper.waitUntilDrained()
    }

    @Test("on a tick land, a join waiting for its flip doesn't flip after a noted failure, and the tick sends nothing (#704, plan test 5)")
    func waitingJoinDoesNotFlipOnATick() async throws {
        try await tickAfterNote(syncPlanThrows: false)
    }

    @Test("the noted failure stays the first cause when the sync plan would throw (#704, plan test 7)")
    func notedFailureIsTheFirstCause() async throws {
        try await tickAfterNote(syncPlanThrows: true)
    }

    /// A tick land with a join ready to flip; a closer notes its failure and holds before its
    /// submit; a tick runs. With `syncPlanThrows`, a phase that ran would fail with `syncPlan`.
    private func tickAfterNote(syncPlanThrows: Bool) async throws {
        let f = await makeFixture(tick: true)
        await f.adapter.setJoinFlipLimitsForTesting(timeout: .zero, budget: nil)
        let returned = TestGate(), joinGate = TestGate(), submit = TestGate()
        await f.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>()
            .on(.keeperJoinReturned) { await returned.arrive() }
            .on(.joinSyncRequested) { await joinGate.arrive() }
            .on(.failureSubmit) { await submit.arrive() }
            .hook)
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(f, session: s1, player: PlayerID("p1")) }
        // The join's input is consumed in a tick turn before it registers, so that tick's phase
        // can't flip it.
        try #require(await returned.waitForArrivals(1), "the keeper join didn't return")
        await f.keeper.stepTickOnce()
        returned.open()
        try #require(await joinGate.waitForArrivals(1), "the join didn't register")
        try #require(await f.adapter.hasJoinsAwaitingSyncForTesting(), "a ready, unflipped join")
        if syncPlanThrows { await f.adapter.setSyncPlanFaultForTesting { throw SyncPlanFault() } }

        let failing = Task { await f.adapter.failOutsideTurn(notedFailure) }
        try #require(await submit.waitForArrivals(1), "the failure holds before its submit")
        let framesBefore = await f.sent.frames.count
        await f.keeper.stepTickOnce()
        #expect(f.keeper.failure?.kind == .responseEncode, "A's failure, not the phase's: \(String(describing: f.keeper.failure))")
        #expect(await f.adapter.isJoiningInTurn(s1), "the join didn't flip")
        #expect(await f.sent.frames.count == framesBefore, "nothing of that tick went out")

        submit.open()
        await failing.value
        joinGate.open()
        await f.adapter.installHolds(nil)
        let completed = try? await join.value.completedInTurn
        #expect(completed != true, "the join's waiter isn't resolved as joined")
        await f.keeper.waitUntilDrained()
    }

    @Test("a rebind to another adapter during the hold doesn't escape the noted failure (#704, plan test 8)")
    func rebindDoesNotEscapeTheNote() async throws {
        let f = await makeFixture(tick: true)
        try await joinOnTickLand(f, session: SessionID("s1"), player: PlayerID("p1"))
        let submit = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.failureSubmit) { await submit.arrive() })
        let failing = Task { await f.adapter.failOutsideTurn(notedFailure) }
        try #require(await submit.waitForArrivals(1), "the failure holds before its submit")
        let second = FlipFrames()
        let adapter2 = TransportAdapter<JoinFlipTestState>(keeper: f.keeper, transport: second, landID: "join-flip")
        await second.setDelegate(adapter2)
        await f.keeper.setTransport(adapter2)
        await f.keeper.stepTickOnce()
        #expect(f.keeper.failure?.kind == .responseEncode, "the note sits on the keeper: \(String(describing: f.keeper.failure))")
        #expect(await second.frames.isEmpty, "the second adapter sent nothing")
        submit.open()
        await failing.value
        await f.adapter.installHolds(nil)
        await f.keeper.waitUntilDrained()
    }

    @Test("a joiner's first sync that fails notes its failure: the next sync turn runs no phase (#704, plan test 9)")
    func failedFirstSyncNotesItsFailure() async throws {
        let f = await makeFixture(tick: true)
        let p1 = PlayerID("p1"), s1 = SessionID("s1")
        try await joinOnTickLand(f, session: s1, player: p1)
        await f.adapter.setFirstSyncPlanFaultForTesting { throw FirstSyncFault() }
        // A phase that ran would fail with its own cause.
        await f.adapter.setSyncPlanFaultForTesting { throw SyncPlanFault() }
        let submit = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.failureSubmit) { await submit.arrive() })
        let firstSync = Task { await f.adapter.syncStateForNewPlayer(playerID: p1, sessionID: s1) }
        try #require(await submit.waitForArrivals(1), "the first sync's failure holds before its submit")
        await f.keeper.runSyncLoopIterationForTesting()
        #expect(f.keeper.failure?.detail.contains("FirstSyncFault") == true,
                "the first sync's failure, not the phase's: \(String(describing: f.keeper.failure))")
        submit.open()
        await firstSync.value
        await f.adapter.installHolds(nil)
        await f.keeper.waitUntilDrained()
    }
}
