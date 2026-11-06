// Tests/SwiftStateTreeTransportTests/TransportAdapterJoinHeldEventsTests.swift
//
// Join PR 4b (#69): targeted events addressed to a session whose join completes in a turn are
// held from its admission to its flip, then sent right after its firstSync, in emission order.
// A join that ends without a flip discards them (counted). Over the bound, the join fails with
// `eventOverflow`, and a full plan never flips a join it also fails. A joiner whose firstSync
// doesn't encode is not flipped: it keeps its events to a later flip.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct HeldEventsTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var joins: Int = 0
}

@Payload
struct HeldEventsTestEvent: ServerEventPayload {
    let note: String
}

/// Records every frame with its target, in send order.
private actor HeldFrames: Transport {
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

    private func own(_ sessionID: SessionID) -> [Data] {
        frames.compactMap { frame in
            guard case .session(let s) = frame.target, s == sessionID else { return nil }
            return frame.data
        }
    }

    /// What `sessionID` received, in order: "joinResponse", "firstSync", "diff", "noChange",
    /// "event:<note>" or "other", in json or MessagePack.
    func kinds(for sessionID: SessionID) -> [String] {
        own(sessionID).map(heldFrameKind)
    }
}

private let notes = ["a", "b", "c", "d", "mid", "late", "q"].map { "note-\($0)" }

/// The event note a frame carries, found as raw bytes (json and MessagePack both store a
/// string's UTF-8 bytes as is).
private func noteIn(_ data: Data) -> String? {
    notes.first { data.range(of: Data($0.utf8)) != nil }
}

private func heldFrameKind(_ data: Data) -> String {
    let decoder = JSONDecoder()
    if let message = try? decoder.decode(TransportMessage.self, from: data) {
        switch message.kind {
        case .joinResponse: return "joinResponse"
        case .event: return "event:\(noteIn(data) ?? "?")"
        default: return "other"
        }
    }
    if let update = try? decoder.decode(StateUpdate.self, from: data) {
        switch update {
        case .noChange: return "noChange"
        case .firstSync: return "firstSync"
        case .diff: return "diff"
        }
    }
    guard let value = try? unpack(data), case .array(let array) = value, case .int(let opcode)? = array.first else {
        return "other"
    }
    func updateKind(_ opcode: Int64) -> String {
        switch opcode {
        case Int64(StateUpdateOpcode.noChange.rawValue): return "noChange"
        case Int64(StateUpdateOpcode.firstSync.rawValue): return "firstSync"
        case Int64(StateUpdateOpcode.diff.rawValue): return "diff"
        default: return "other"
        }
    }
    switch opcode {
    case Int64(MessageKindOpcode.event.rawValue):
        return "event:\(noteIn(data) ?? "?")"
    case 107:
        if array.count > 1, case .array(let update) = array[1], case .int(let inner)? = update.first {
            return updateKind(inner)
        }
        return "other"
    default:
        return updateKind(opcode)
    }
}

enum HeldEncoding: String, CaseIterable, CustomStringConvertible {
    /// Opcode 107: events are queued and merged; a joiner's share is held by the plan.
    case messagepack
    /// Immediate mode: events are encoded when emitted; a joiner's is held by the target resolution.
    case json

    var description: String { rawValue }
}

private struct Fixture {
    let keeper: LandKeeper<HeldEventsTestState>
    let adapter: TransportAdapter<HeldEventsTestState>
    let sent: HeldFrames
}

/// OnJoin sends `.session` "a" and `.player` "b" to the joiner; the player "many" also gets
/// "c", whose payload is over 8 KiB.
private func heldEventsOnJoin(_ state: inout HeldEventsTestState, _ ctx: LandContext) {
    state.joins += 1
    ctx.emitEvent(HeldEventsTestEvent(note: "note-a"), to: .session(ctx.sessionID))
    ctx.emitEvent(HeldEventsTestEvent(note: "note-b"), to: .player(ctx.playerID))
    if ctx.playerID.rawValue == "many" {
        ctx.emitEvent(HeldEventsTestEvent(note: "note-c" + String(repeating: "x", count: 8192)), to: .player(ctx.playerID))
    }
}

/// `tick`: a land with an hourly tick and its loops started (periodic sync, stepped by hand);
/// otherwise tickless with no periodic sync. OnJoin is `heldEventsOnJoin`.
private func makeFixture(_ encoding: HeldEncoding, tick: Bool = true) async -> Fixture {
    let definition: LandDefinition<HeldEventsTestState>
    if tick {
        definition = Land("held-events", using: HeldEventsTestState.self) {
            ServerEvents { Register(HeldEventsTestEvent.self) }
            Rules {
                OnJoin { (state: inout HeldEventsTestState, ctx: LandContext) in heldEventsOnJoin(&state, ctx) }
            }
            Lifetime {
                Tick(every: .seconds(3600)) { (_: inout HeldEventsTestState, _: LandContext) in }
            }
        }
    } else {
        definition = Land("held-events", using: HeldEventsTestState.self) {
            ServerEvents { Register(HeldEventsTestEvent.self) }
            Rules {
                OnJoin { (state: inout HeldEventsTestState, ctx: LandContext) in heldEventsOnJoin(&state, ctx) }
            }
        }
    }
    let sent = HeldFrames()
    let keeper = LandKeeper(definition: definition, initialState: HeldEventsTestState(), autoStartLoops: tick)
    let config: TransportEncodingConfig = switch encoding {
    case .messagepack: .messagepack
    case .json: .json
    }
    let adapter = TransportAdapter<HeldEventsTestState>(
        keeper: keeper,
        transport: sent,
        landID: "held-events",
        encodingConfig: config,
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

/// A join through the in-turn path: returns once it flipped.
private func joinInTurn(_ fixture: Fixture, session: SessionID, player: PlayerID) async throws {
    let client = ClientID("c-\(session.rawValue)")
    await fixture.adapter.onConnect(sessionID: session, clientID: client)
    _ = try await fixture.adapter.performJoin(
        playerSession: PlayerSession(playerID: player.rawValue, deviceID: "dev", metadata: [:]),
        clientID: client,
        sessionID: session,
        authInfo: nil,
        joinResponse: joinResponseBuilder
    )
}

/// Waits (bounded, not a timing assertion) until `condition` holds.
private func eventually(_ what: String, _ condition: @Sendable () async -> Bool) async {
    for _ in 0..<2000 {
        if await condition() { return }
        try? await safeTaskSleep(for: .milliseconds(1))
    }
    Issue.record("timed out waiting for \(what)")
}

/// A joined member, so later joins have another recipient in their plans.
private func joinMember(_ fixture: Fixture) async throws {
    let s0 = SessionID("s0")
    let first = Task { try await joinInTurn(fixture, session: s0, player: PlayerID("p0")) }
    await eventually("s0 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s0) }
    await fixture.keeper.stepTickOnce()
    try await first.value
    #expect(await fixture.adapter.waitForOutboundDrain())
}

@Suite(
    "Join holds targeted events until its firstSync (#69)",
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: held events are on the in-turn path only")
)
struct TransportAdapterJoinHeldEventsTests {
    @Test("OnJoin's .session and .player events reach the joiner after its firstSync, in order", arguments: HeldEncoding.allCases)
    func onJoinEventsFollowTheFirstSync(encoding: HeldEncoding) async throws {
        let fixture = await makeFixture(encoding)
        try await joinMember(fixture)
        let heldBefore = await fixture.adapter.eventsHeldForJoiningSessions
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.keeper.stepTickOnce()
        try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync", "event:note-a", "event:note-b"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 0)
        #expect(await fixture.adapter.eventsHeldForJoiningSessions == heldBefore + 2)
    }

    @Test("Registration held after OnJoin's events were queued: they are delivered, not lost to a stamp bump", arguments: HeldEncoding.allCases)
    func registrationAfterOnJoinKeepsTheStamp(encoding: HeldEncoding) async throws {
        let fixture = await makeFixture(encoding)
        try await joinMember(fixture)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.registerSession) { await gate.arrive() })
        let s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at registerSession") { gate.arrivalCount == 1 }
        // The tick consumes OnJoin: its events are queued (107) or held (json) with the
        // admission's stamp, before the registration.
        await fixture.keeper.stepTickOnce()
        // Between the consumption and the flip, another targeted event.
        await fixture.adapter.sendEvent(AnyServerEvent(HeldEventsTestEvent(note: "note-mid")), to: .session(s1))
        gate.open()
        await fixture.adapter.installHolds(nil)
        try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync", "event:note-a", "event:note-b", "event:note-mid"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 0)
    }

    @Test(".players([joining, joined]): the joined player gets it at once, the joiner after its firstSync", arguments: HeldEncoding.allCases)
    func playersTargetSplitsJoinedAndJoining(encoding: HeldEncoding) async throws {
        // One session per player (#92), so a joined and a joining session of the same player
        // can't coexist; the split is between players.
        let fixture = await makeFixture(encoding)
        try await joinMember(fixture)
        let gate = TestGate()
        await fixture.adapter.installHolds(HoldRegistry.at(.registerSession) { await gate.arrive() })
        let s0 = SessionID("s0"), s1 = SessionID("s1")
        let join = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("the join at registerSession") { gate.arrivalCount == 1 }
        await fixture.keeper.stepTickOnce()
        await fixture.adapter.sendEvent(AnyServerEvent(HeldEventsTestEvent(note: "note-q")), to: .players([PlayerID("p1"), PlayerID("p0")]))
        await fixture.adapter.syncNow()
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s0).contains("event:note-q"), "the joined player got it before the joiner's flip")
        #expect(await fixture.sent.kinds(for: s1) == [])
        gate.open()
        await fixture.adapter.installHolds(nil)
        try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync", "event:note-a", "event:note-b", "event:note-q"])
    }

    @Test("A joiner past the flip budget keeps its events to its own later flip", arguments: HeldEncoding.allCases)
    func joinerPastTheBudgetKeepsItsEvents(encoding: HeldEncoding) async throws {
        let fixture = await makeFixture(encoding)
        try await joinMember(fixture)
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: nil, budget: 1)
        let s1 = SessionID("s1"), s2 = SessionID("s2")
        let first = Task { try await joinInTurn(fixture, session: s1, player: PlayerID("p1")) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        let second = Task { try await joinInTurn(fixture, session: s2, player: PlayerID("p2")) }
        await eventually("s2 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s2) }
        // One tick consumes both OnJoins; the budget flips s1 only.
        await fixture.keeper.stepTickOnce()
        try await first.value
        #expect(await fixture.adapter.isJoiningInTurn(s2))
        await fixture.adapter.sendEvent(AnyServerEvent(HeldEventsTestEvent(note: "note-late")), to: .session(s2))
        await fixture.keeper.stepTickOnce()
        try await second.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s2) == ["joinResponse", "firstSync", "event:note-a", "event:note-b", "event:note-late"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 0)
    }

    @Test("Over the held-event count or byte bound: the join fails with eventOverflow and is never flipped; another joiner of that commit flips", arguments: HeldEncoding.allCases, [true, false])
    func overflowFailsTheJoin(encoding: HeldEncoding, byCount: Bool) async throws {
        let fixture = await makeFixture(encoding)
        try await joinMember(fixture)
        // "many" gets 3 events (one over 8 KiB), "ok" 2 small ones: a bound of 2 events, or of 4 KiB.
        await fixture.adapter.setHeldEventsLimitForTesting(count: byCount ? 2 : 1000, bytes: byCount ? 1 << 20 : 4096)
        let sMany = SessionID("s-many"), sOK = SessionID("s-ok")
        let many = Task { try await joinInTurn(fixture, session: sMany, player: PlayerID("many")) }
        await eventually("many registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(sMany) }
        let ok = Task { try await joinInTurn(fixture, session: sOK, player: PlayerID("ok")) }
        await eventually("ok registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(sOK) }
        await fixture.keeper.stepTickOnce()
        await #expect(throws: JoinFlipError.eventOverflow) { try await many.value }
        try await ok.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: sMany) == [], "never flipped: no JoinResponse, no firstSync, no event")
        #expect(await fixture.sent.kinds(for: sOK) == ["joinResponse", "firstSync", "event:note-a", "event:note-b"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 3, "the overflowing event and the ones held before it")
        #expect(await fixture.adapter.inTurnJoinFailures[.eventOverflow] == 1)
    }

    @Test("A joiner whose firstSync doesn't encode is not flipped; it keeps its events, and the next cycle flips it")
    func unencodableFirstSyncIsNotFlipped() async throws {
        let fixture = await makeFixture(.messagepack)
        try await joinMember(fixture)
        let p1 = PlayerID("p1"), s1 = SessionID("s1")
        await fixture.adapter.setSyncEncodeFaultForTesting { $0 == p1 }
        let join = Task { try await joinInTurn(fixture, session: s1, player: p1) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.keeper.stepTickOnce()
        // #194 flipped it here, with no firstSync.
        #expect(await fixture.adapter.isJoiningInTurn(s1), "not flipped")
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [], "no JoinResponse before its state")
        // An event in the window where it would have been flipped: held.
        await fixture.adapter.sendEvent(AnyServerEvent(HeldEventsTestEvent(note: "note-mid")), to: .session(s1))
        // It no longer asks for join sync turns of its own; the land's periodic sync retries it.
        #expect(await fixture.adapter.hasJoinsAwaitingSyncForTesting() == false)
        await fixture.keeper.runSyncLoopIterationForTesting()
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        await fixture.adapter.setSyncEncodeFaultForTesting(nil)
        await fixture.keeper.runSyncLoopIterationForTesting()
        try await join.value
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == ["joinResponse", "firstSync", "event:note-a", "event:note-b", "event:note-mid"])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 0)
    }

    @Test("Tickless land, a firstSync that never encodes: a bounded number of retries, then the join times out")
    func unencodableFirstSyncOnTicklessLandIsBounded() async throws {
        let fixture = await makeFixture(.messagepack, tick: false)
        let p1 = PlayerID("p1"), s1 = SessionID("s1")
        let attempts = EncodeAttempts()
        await fixture.adapter.setSyncEncodeFaultForTesting { player in
            guard player == p1 else { return false }
            attempts.increment()
            return true
        }
        await fixture.adapter.setJoinFlipLimitsForTesting(timeout: .milliseconds(1500), budget: nil)
        await #expect(throws: JoinFlipError.timeout) {
            try await joinInTurn(fixture, session: s1, player: p1)
        }
        // The first plan and at most `syncFailedPlanFollowUpLimit` follow-ups (100 ms apart),
        // each encoding the joiner's firstSync and its fallback: not back-to-back phases until
        // the timeout.
        let limit = TransportAdapter<HeldEventsTestState>.syncFailedPlanFollowUpLimit
        #expect(attempts.count >= 2, "the firstSync was tried")
        #expect(attempts.count <= 2 * (1 + limit), "attempts: \(attempts.count)")
        #expect(await fixture.sent.kinds(for: s1) == [])
    }

    @Test("A disconnect or a newer join while events are held or queued: no event is sent, and the discard is counted", arguments: [true, false])
    func endedJoinDiscardsItsEvents(disconnect: Bool) async throws {
        let fixture = await makeFixture(.messagepack)
        try await joinMember(fixture)
        let heldBefore = await fixture.adapter.eventsHeldForJoiningSessions
        let s1 = SessionID("s1"), p1 = PlayerID("p1")
        // Its firstSync doesn't encode: it stays joining after the tick, holding OnJoin's two events.
        await fixture.adapter.setSyncEncodeFaultForTesting { $0 == p1 }
        let join = Task { try await joinInTurn(fixture, session: s1, player: p1) }
        await eventually("s1 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s1) }
        await fixture.keeper.stepTickOnce()
        #expect(await fixture.adapter.isJoiningInTurn(s1))
        // Queued for the next merged frame, not yet held when the join ends: counted too.
        await fixture.adapter.sendEvent(AnyServerEvent(HeldEventsTestEvent(note: "note-mid")), to: .session(s1))
        if disconnect {
            await fixture.adapter.onDisconnect(sessionID: s1, clientID: ClientID("c-s1"))
            await #expect(throws: JoinFlipError.disconnected) { try await join.value }
        } else {
            let s2 = SessionID("s2")
            let newer = Task { try await joinInTurn(fixture, session: s2, player: p1) }
            await #expect(throws: JoinFlipError.superseded) { try await join.value }
            await fixture.adapter.setSyncEncodeFaultForTesting(nil)
            await eventually("s2 registered") { await fixture.adapter.isInTurnJoinRegisteredForTesting(s2) }
            await fixture.keeper.stepTickOnce()
            try await newer.value
        }
        #expect(await fixture.adapter.waitForOutboundDrain())
        #expect(await fixture.sent.kinds(for: s1) == [])
        #expect(await fixture.adapter.eventsDroppedForJoiningSessions == 3, "two held, one still queued")
        #expect(await fixture.adapter.eventsHeldForJoiningSessions == heldBefore + (disconnect ? 0 : 2), "only the newer join's own")
    }
}

/// Counts encode attempts from the fault hook (called on the adapter's executor).
private final class EncodeAttempts: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func increment() { lock.lock(); value += 1; lock.unlock() }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}

@Suite("Membership: a re-registration keeps its stamp only while bound (#69)")
struct MembershipKeptStampTests {
    @Test("The same session and player registered again keeps the stamp")
    func reRegistrationKeepsTheStamp() {
        let membership = MembershipCoordinator()
        let s = SessionID("s"), p = PlayerID("p")
        let first = membership.registerPlayer(sessionID: s, playerID: p, authInfo: nil)
        let again = membership.registerPlayer(sessionID: s, playerID: p, authInfo: nil)
        #expect(again == first)
        #expect(membership.isSessionCurrent(s, expected: first.version))
    }

    @Test("After a leave (unregister, remove, invalidate), a rejoin of the same session and player bumps the stamp", arguments: ["unregister", "remove", "invalidate"])
    func rejoinAfterLeaveBumps(end: String) {
        let membership = MembershipCoordinator()
        let s = SessionID("s"), p = PlayerID("p")
        let first = membership.registerPlayer(sessionID: s, playerID: p, authInfo: nil)
        switch end {
        case "unregister": membership.unregisterSession(sessionID: s)
        case "remove": membership.removeJoinedPlayer(sessionID: s)
        default: membership.invalidateMembership(sessionID: s, playerID: p)
        }
        let rejoined = membership.registerPlayer(sessionID: s, playerID: p, authInfo: nil)
        #expect(rejoined.version > first.version)
        #expect(!membership.isSessionCurrent(s, expected: first.version), "an event stamped before the leave is rejected")
        #expect(!membership.isPlayerCurrent(p, expected: first.version))
    }
}
