// Tests/SwiftStateTreeTransportTests/TransportAdapterPendingEventsAcrossCyclesTests.swift
//
// Regression tests for #77: with opcode 107 (opcodeMessagePack), server events are queued and
// delivered by the next sync cycle. A cycle used to end by clearing the whole queue, dropping
// events queued after it had read the queue. Now each cycle removes only what it read, and a land
// without periodic sync runs a follow-up cycle to deliver what was kept.
//
// Windows are injected deterministically:
// - the batch send: `sendBatch` suspends until the test releases it;
// - the targeted flush and broadcast-only sends: `send` is synchronous, so the transport actor
//   runs on a gated serial executor; the test releases its jobs one at a time.

import Foundation
import Testing
import SwiftStateTreeMessagePack
import SwiftStateTreeTestSupport
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Test state, action and event

@StateNodeBuilder
struct KeptEventsTestState: StateNodeProtocol {
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct KeptEventsSetAction: ActionPayload {
    typealias Response = KeptEventsSetResponse
    /// "tick" (broadcast) or "score" (the calling player's per-player entry).
    let field: String
    let value: Int
}

@Payload
struct KeptEventsSetResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct KeptEventsEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

// MARK: - Gated transport

/// Serial executor whose jobs run on a private queue. While closed, jobs are held until the test
/// releases them, which blocks callers awaiting a hop onto the transport actor.
private final class GatedSerialExecutor: SerialExecutor, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "kept-events-gated-transport")
    private var isOpen = true
    private var held: [UnownedJob] = []
    private var running = 0

    func enqueue(_ job: UnownedJob) {
        lock.lock()
        if isOpen {
            running += 1
            lock.unlock()
            dispatch(job)
        } else {
            held.append(job)
            lock.unlock()
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        UnownedSerialExecutor(ordinary: self)
    }

    private func dispatch(_ job: UnownedJob) {
        queue.async {
            job.runSynchronously(on: self.asUnownedSerialExecutor())
            self.lock.lock()
            self.running -= 1
            self.lock.unlock()
        }
    }

    func close() {
        lock.lock()
        isOpen = false
        lock.unlock()
    }

    func open() {
        lock.lock()
        isOpen = true
        let jobs = held
        held.removeAll()
        running += jobs.count
        lock.unlock()
        for job in jobs { dispatch(job) }
    }

    /// Runs the oldest held job. Returns `false` when none is held.
    @discardableResult
    func releaseOne() -> Bool {
        lock.lock()
        guard !held.isEmpty else {
            lock.unlock()
            return false
        }
        let job = held.removeFirst()
        running += 1
        lock.unlock()
        dispatch(job)
        return true
    }

    var heldCount: Int {
        lock.lock(); defer { lock.unlock() }
        return held.count
    }

    var runningCount: Int {
        lock.lock(); defer { lock.unlock() }
        return running
    }
}

/// What the transport saw; readable from the test without hopping onto the (gated) actor.
private final class KeptEventsRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var frames: [(session: SessionID?, data: Data)] = []

    func record(_ data: Data, to target: SwiftStateTreeTransport.EventTarget) {
        lock.lock(); defer { lock.unlock() }
        if case .session(let id) = target {
            frames.append((id, data))
        } else {
            frames.append((nil, data))
        }
    }

    func frames(for session: SessionID) -> [Data] {
        lock.lock(); defer { lock.unlock() }
        return frames.compactMap { $0.session == session ? $0.data : nil }
    }

    var frameCount: Int {
        lock.lock(); defer { lock.unlock() }
        return frames.count
    }

    func clear() {
        lock.lock(); defer { lock.unlock() }
        frames.removeAll()
    }

}

private actor KeptEventsTransport: Transport {
    nonisolated let executor = GatedSerialExecutor()
    nonisolated let recorder = KeptEventsRecorder()
    nonisolated var unownedExecutor: UnownedSerialExecutor { executor.asUnownedSerialExecutor() }

    var delegate: TransportDelegate?

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        recorder.record(message, to: target)
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            recorder.record(data, to: target)
        }
    }
}

// MARK: - Helpers

/// Polls `condition` (no fixed sleeps as synchronization; the poll only waits for work in flight).
private func waitUntil(
    _ what: String,
    timeout: Duration = .seconds(5),
    _ condition: () -> Bool
) async throws {
    let deadline = ContinuousClock.now + timeout
    while !condition() {
        guard ContinuousClock.now < deadline else {
            Issue.record("timed out waiting for \(what)")
            throw CancellationError()
        }
        try await Task.sleep(for: .milliseconds(1))
    }
}

private func count(_ message: String, in frames: [Data]) -> Int {
    let marker = Data(message.utf8)
    return frames.filter { $0.range(of: marker) != nil }.count
}

/// Frame kinds by first element: 0...2 state update, 103 event, 107 merged state + events.
private func opcodes(_ frames: [Data]) -> [Int64] {
    frames.compactMap { frame in
        guard let unpacked = try? unpack(frame),
              case .array(let array) = unpacked,
              case .int(let opcode) = array.first else { return nil }
        return opcode
    }
}

private enum KeptEventsLand {
    /// No tick, no `StateSync`: nothing syncs the land unless asked (`hasPeriodicSync == false`).
    case tickless
    /// A sync loop configured, far apart so none fires during a test (`hasPeriodicSync == true`).
    /// No tick handler: a ticked land applies actions on its next tick, which the tests never reach.
    case periodicSync
}

private struct KeptEventsMember {
    let session: SessionID
    let client: ClientID
    let player: PlayerID

    init(_ name: String) {
        session = SessionID("ke-session-\(name)")
        client = ClientID("ke-client-\(name)")
        player = PlayerID("ke-player-\(name)")
    }
}

private struct KeptEventsFixture {
    let keeper: LandKeeper<KeptEventsTestState>
    let adapter: TransportAdapter<KeptEventsTestState>
    let transport: KeptEventsTransport
    let members: [KeptEventsMember]
    /// Holds an in-turn settle in flight; see `SyncHold`. The settle tests install it at
    /// `.settleBeforePublish`.
    let hold = SyncHold()

    var a: KeptEventsMember { members[0] }
    var b: KeptEventsMember { members[1] }
    var recorder: KeptEventsRecorder { transport.recorder }
    var gate: GatedSerialExecutor { transport.executor }

    static func make(
        _ land: KeptEventsLand,
        members names: [String] = ["a"]
    ) async throws -> KeptEventsFixture {
        let definition: LandDefinition<KeptEventsTestState>
        switch land {
        case .tickless:
            definition = Land("kept-events-test", using: KeptEventsTestState.self) {
                ServerEvents { Register(KeptEventsEvent.self) }
                Rules {
                    OnJoin { state, ctx in
                        state.scores[ctx.playerID] = 0
                    }
                    HandleAction(KeptEventsSetAction.self) { state, action, ctx in
                        if action.field == "tick" {
                            state.tick = action.value
                        } else {
                            state.scores[ctx.playerID] = action.value
                        }
                        return KeptEventsSetResponse(ok: true)
                    }
                }
            }
        case .periodicSync:
            definition = Land("kept-events-test", using: KeptEventsTestState.self) {
                ServerEvents { Register(KeptEventsEvent.self) }
                Lifetime {
                    StateSync(every: .seconds(3600)) { _, _ in }
                }
                Rules {
                    OnJoin { state, ctx in
                        state.scores[ctx.playerID] = 0
                    }
                    HandleAction(KeptEventsSetAction.self) { state, action, ctx in
                        if action.field == "tick" {
                            state.tick = action.value
                        } else {
                            state.scores[ctx.playerID] = action.value
                        }
                        return KeptEventsSetResponse(ok: true)
                    }
                }
            }
        }
        let transport = KeptEventsTransport()
        let keeper = LandKeeper<KeptEventsTestState>(
            definition: definition,
            initialState: KeptEventsTestState()
        )
        let adapter = TransportAdapter<KeptEventsTestState>(
            keeper: keeper,
            transport: transport,
            landID: "kept-events-test",
            // Fixed so env vars cannot change the sync path.
            transportEnvConfig: TransportEnvConfig(
                enableDirtyTracking: true,
                useSnapshotForSync: true,
                syncStrategy: .delta,
                profilingConfig: nil
            ),
            encodingConfig: .messagepack
        )
        await transport.setDelegate(adapter)
        // The freeze tests hold a settle: no deadline may fire inside the hold (#928).
        await adapter.setDebugFreezeSettleDeadline(freezeWithoutDeadline)
        await adapter.setDebugFreezeAutoResumeTimeout(freezeWithoutDeadline)
        let members = names.map(KeptEventsMember.init)
        for member in members {
            await adapter.onConnect(sessionID: member.session, clientID: member.client)
            try await simulateRouterJoin(
                adapter: adapter,
                keeper: keeper,
                sessionID: member.session,
                clientID: member.client,
                playerID: member.player
            )
        }
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await settle(transport)
        transport.recorder.clear()
        let fixture = KeptEventsFixture(keeper: keeper, adapter: adapter, transport: transport, members: members)
        return fixture
    }

    func set(_ field: String, _ value: Int, by member: KeptEventsMember? = nil) async throws {
        let member = member ?? a
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: KeptEventsSetAction.self),
            payload: AnyCodable(KeptEventsSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: member.player,
            clientID: member.client,
            sessionID: member.session
        )
    }

    func broadcastEvent(_ message: String) async {
        // opcodeMessagePack queues events for the next cycle; nothing to drain here (and some
        // tests call this with the transport gated).
        await adapter.sendEvent(AnyServerEvent(KeptEventsEvent(message: message)), to: .all)
    }

    func targetedEvent(_ message: String, to member: KeptEventsMember) async {
        // opcodeMessagePack queues events for the next cycle; nothing to drain here (and some
        // tests call this with the transport gated).
        await adapter.sendEvent(AnyServerEvent(KeptEventsEvent(message: message)), to: .player(member.player))
    }

    /// Frames for `member`, after in-flight sends landed (see `settle`).
    func frames(_ member: KeptEventsMember) -> [Data] {
        recorder.frames(for: member.session)
    }

    func settle() async {
        await KeptEventsFixture.settle(transport)
    }

    /// Waits until `message` reached `member` at least `expected` times, then settles, so an exact
    /// count asserted afterwards also sees duplicates that land late.
    func waitForCount(_ message: String, _ member: KeptEventsMember, _ expected: Int = 1) async throws {
        let recorder = self.recorder
        try await waitUntil("\(expected)x \(message) at \(member.session.rawValue)") {
            count(message, in: recorder.frames(for: member.session)) >= expected
        }
        await settle()
    }

    /// Frames reach the transport from the outbound writer's consumer task, so they can land
    /// after `syncNow` returns; follow-up cycles run in their own task too. Waits until no frame
    /// arrived for a while. A heuristic: tests wait for the frames they expect first
    /// (`waitForCount`), so this only guards against late extra frames.
    static func settle(_ transport: KeptEventsTransport) async {
        var last = -1
        for _ in 0..<250 {
            let now = transport.recorder.frameCount
            if now == last, transport.executor.heldCount == 0, transport.executor.runningCount == 0 { return }
            last = now
            try? await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("frames kept arriving: transport did not settle within 5 s")
    }
}

// MARK: - Tests

@Suite("TransportAdapter keeps late-queued events for the next sync cycle (#77)", .serialized, .timeLimit(.minutes(1)))
struct TransportAdapterPendingEventsAcrossCyclesTests {

    // Since #60 the flush only enqueues on the outbound writer and never suspends between
    // sessions; the gate now holds the writer's delivery instead. The test still checks that
    // events queued after a cycle read the queue arrive once each, at their own session.
    @Test("2: targeted events queued while the flush is between sessions arrive once each, next cycle")
    func targetedEventsQueuedDuringFlushArriveNextCycle() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync, members: ["a", "b"])

        // No per-player change, so the flush serves both sessions, one send per event body.
        await f.targetedEvent("pre-a", to: f.a)
        await f.targetedEvent("pre-b", to: f.b)
        f.gate.close()
        let adapter = f.adapter
        let cycle = Task { await adapter.syncNow() }
        // Release transport jobs one by one until the flush has sent to its first session.
        while count("pre-a", in: f.frames(f.a)) + count("pre-b", in: f.frames(f.b)) == 0 {
            try await waitUntil("a held transport job") { f.gate.heldCount > 0 }
            f.gate.releaseOne()
            try await waitUntil("the released job to finish") { f.gate.runningCount == 0 }
        }
        // The flush is now between sessions (its next send is held or not yet issued).
        await f.targetedEvent("late-a", to: f.a)
        await f.targetedEvent("late-b", to: f.b)
        f.gate.open()
        await cycle.value
        await f.settle()

        await f.adapter.syncNow()  // the next periodic cycle
        try await f.waitForCount("late-a", f.a)
        try await f.waitForCount("late-b", f.b)
        let aFrames = f.frames(f.a)
        let bFrames = f.frames(f.b)
        #expect(count("pre-a", in: aFrames) == 1)
        #expect(count("pre-b", in: bFrames) == 1)
        #expect(count("late-a", in: aFrames) == 1, "late-a must reach A exactly once")
        #expect(count("late-b", in: bFrames) == 1, "late-b must reach B exactly once")
        #expect(count("late-a", in: bFrames) == 0 && count("late-b", in: aFrames) == 0, "no cross delivery")
    }

    // Since #60 the cycle does not suspend at its send; the gate holds the writer's
    // delivery. The test still checks that events queued after the cycle arrive once each.
    @Test("3: a cycle keeps broadcast events queued during its send for the next cycle")
    func broadcastOnlyCycleKeepsLateEvents() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)

        try await f.set("tick", 1)
        f.gate.close()
        let adapter = f.adapter
        let cycle = Task { await adapter.syncNow() }
        // Held at the broadcast frame's send: broadcast events were read, targeted not yet.
        try await waitUntil("the broadcast frame send to be held") { f.gate.heldCount > 0 }
        await f.broadcastEvent("bc-late")
        await f.targetedEvent("tg-late", to: f.a)
        f.gate.open()
        await cycle.value
        await f.settle()

        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        try await f.waitForCount("bc-late", f.a)
        try await f.waitForCount("tg-late", f.a)
        let frames = f.frames(f.a)
        #expect(count("bc-late", in: frames) == 1, "broadcast event must arrive exactly once")
        #expect(count("tg-late", in: frames) == 1, "targeted event must arrive exactly once")
    }

    @Test("4: events read by cycle N are not resent by cycle N+1 (exact frame counts)")
    func noDuplicatesAcrossCycles() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)
        // Each `syncNow` is one sync-only turn, which enqueues its frames before it returns, so
        // the writer's idle is the cycle's delivery.

        // Cycle N: a per-player change, and a targeted and a broadcast event queued before it.
        try await f.set("score", 1)
        await f.targetedEvent("tg-1", to: f.a)
        await f.broadcastEvent("bc-1")
        await f.adapter.syncNow()
        try #require(await withinHangBound { await f.adapter.waitForOutboundIdleForTesting() }, "the cycle's frames never reached the transport")
        // Cycle N+1: nothing new but a broadcast event queued after N.
        await f.broadcastEvent("bc-2")
        await f.adapter.syncNow()
        try #require(await withinHangBound { await f.adapter.waitForOutboundIdleForTesting() }, "the cycle's frames never reached the transport")
        // Cycle N+2: nothing at all.
        await f.adapter.syncNow()
        try #require(await withinHangBound { await f.adapter.waitForOutboundIdleForTesting() }, "the cycle's frames never reached the transport")

        let frames = f.frames(f.a)
        let kinds = opcodes(frames)
        #expect(count("tg-1", in: frames) == 1)
        #expect(count("bc-1", in: frames) == 1)
        #expect(count("bc-2", in: frames) == 1)
        #expect(kinds.filter { $0 == 103 }.count == 1, "one targeted event frame (N); kinds \(kinds)")
        #expect(kinds.filter { $0 == 107 }.count == 2, "one merged frame each in N and N+1; kinds \(kinds)")
        #expect(kinds.filter { (0...2).contains($0) }.count == 1, "one per-player state frame (N); kinds \(kinds)")
    }

    @Test("5a: with every member in initial sync, queued events are dropped by both cycle types (#69)")
    func allInitialSyncingDropsEvents() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)
        await f.adapter.beginInitialSync(for: f.a.player)

        await f.broadcastEvent("bc-drop")
        await f.targetedEvent("tg-drop", to: f.a)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await f.settle()
        var counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "syncNow drops them; left \(counts)")

        try await f.set("tick", 1)
        await f.broadcastEvent("bc-drop-2")
        await f.targetedEvent("tg-drop-2", to: f.a)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        await f.settle()
        counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "broadcast-only drops them; left \(counts)")
        #expect(f.frames(f.a).isEmpty, "nothing is sent to an initial-syncing session")
    }

    @Test("5b: an initial-syncing session does not get events of its join window (#69)")
    func initialSyncingSessionMissesJoinWindowEvents() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync, members: ["a", "b"])
        await f.adapter.beginInitialSync(for: f.b.player)

        await f.broadcastEvent("bc-window")
        await f.targetedEvent("tg-window-b", to: f.b)
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        try await f.waitForCount("bc-window", f.a)

        #expect(count("bc-window", in: f.frames(f.a)) == 1, "the eligible session gets the broadcast event")
        #expect(f.frames(f.b).isEmpty, "the initial-syncing session gets nothing")
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "the cycle consumed both; left \(counts)")
    }

    @Test(
        "8-in-turn: an event queued before a cycle is delivered by that cycle, once"
    )
    func inTurnEventQueuedBeforeCycleIsInThatCycle() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)
        await f.broadcastEvent("bc-begin")
        await f.adapter.syncNow()
        // Periodic sync (hourly): no follow-up cycle, so only the cycle above can deliver it.
        try await f.waitForCount("bc-begin", f.a)
        #expect(count("bc-begin", in: f.frames(f.a)) == 1)
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "the cycle consumed the event")
    }
}

// MARK: - Queue unit tests

@Suite("PendingEventManager consumed-prefix removal (#77)")
struct PendingEventManagerConsumedPrefixTests {

    private func body(_ n: Int) -> MessagePackValue { .array([.int(Int64(n))]) }

    @Test("removeConsumed removes exactly the read prefix and keeps later events in order")
    func removeConsumedKeepsLaterEvents() {
        var manager = PendingEventManager()
        let session = SessionID("s")
        let stamp = MembershipStamp(playerID: PlayerID("p"), version: 0)
        for n in 0..<4 {
            manager.queueTargeted(target: .session(session), body: body(n), stamp: stamp)
            manager.queueBroadcast(body: body(10 + n))
        }

        manager.removeConsumed(targeted: 3, broadcast: 1)

        #expect(manager.targetedEventCount == 1)
        #expect(manager.broadcastEventCount == 3)
        #expect(manager.pendingBroadcastBodies() == [body(11), body(12), body(13)])
        let remaining = manager.pendingTargetedBodies(
            for: session,
            playerID: PlayerID("p"),
            clientID: nil,
            isSessionCurrent: { _, _ in true },
            isPlayerCurrent: { _, _ in true }
        )
        #expect(remaining == [body(3)])
    }

    @Test("pendingTargetedBodies reads the prefix [0, end)")
    func targetedSlice() {
        var manager = PendingEventManager()
        let session = SessionID("s")
        let stamp = MembershipStamp(playerID: PlayerID("p"), version: 0)
        for n in 0..<5 {
            manager.queueTargeted(target: .session(session), body: body(n), stamp: stamp)
        }
        let slice = manager.pendingTargetedBodies(
            for: session,
            playerID: PlayerID("p"),
            clientID: nil,
            isSessionCurrent: { _, _ in true },
            isPlayerCurrent: { _, _ in true },
            endingBefore: 4
        )
        #expect(slice == [body(0), body(1), body(2), body(3)])
    }

    @Test("removing nothing (a cycle that threw before its cleanup) keeps the queue")
    func zeroMarksRemoveNothing() {
        var manager = PendingEventManager()
        manager.queueBroadcast(body: body(1))
        manager.removeConsumed(targeted: 0, broadcast: 0)
        #expect(manager.broadcastEventCount == 1)
    }
}

// MARK: - hasPeriodicSync

@Suite("LandKeeper.hasPeriodicSync (#77)")
struct LandKeeperHasPeriodicSyncTests {

    private func keeper(
        _ definition: LandDefinition<KeptEventsTestState>,
        autoStartLoops: Bool = true
    ) -> LandKeeper<KeptEventsTestState> {
        LandKeeper(definition: definition, initialState: KeptEventsTestState(), autoStartLoops: autoStartLoops)
    }

    @Test("true for an auto-started tick loop or sync loop, false otherwise")
    func flagCombinations() {
        let tickless = Land("periodic-none", using: KeptEventsTestState.self) {
            Rules {}
        }
        let ticked = Land("periodic-tick", using: KeptEventsTestState.self) {
            Lifetime {
                Tick(every: .seconds(3600)) { _, _ in }
            }
            Rules {}
        }
        let synced = Land("periodic-sync", using: KeptEventsTestState.self) {
            Lifetime {
                StateSync(every: .seconds(3600)) { _, _ in }
            }
            Rules {}
        }
        #expect(keeper(tickless).hasPeriodicSync == false)
        #expect(keeper(ticked).hasPeriodicSync == true)
        #expect(keeper(synced).hasPeriodicSync == true)
        #expect(keeper(ticked, autoStartLoops: false).hasPeriodicSync == false)
        #expect(keeper(synced, autoStartLoops: false).hasPeriodicSync == false)
    }
}

// MARK: - Debug freeze (#79)

@Suite("Kept events and follow-up cycles under a debug freeze (#79)", .timeLimit(.minutes(1)))
struct TransportAdapterKeptEventsDebugFreezeTests {
    // The in-turn settle commits in one keeper job (#546 L2b), so its read→cleanup window can't
    // be reached from outside; the marks stay covered by the PendingEventManager unit tests.
    // This test queues its event while the settle is held after its commit, before it publishes,
    // and checks that the settle's kept-events check leaves it to the resume.
    @Test("An event queued after the settle's commit arrives once after resume")
    func eventKeptBySettleArrivesAfterResume() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        // The settle runs only through the keeper's attached transport (#546 L2d-1).
        await f.keeper.setTransport(f.adapter)
        try await f.set("score", 2)

        // The settle is the held one: the event is queued after its frame was built.
        await f.hold.install(on: f.adapter, at: .settleBeforePublish)
        f.hold.arm()
        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try await f.hold.waitUntilHeld()
        await f.broadcastEvent("bc-kept-by-settle")
        f.hold.release()
        let token = try await freeze.value.freezeToken
        await f.settle()

        #expect(count("bc-kept-by-settle", in: f.frames(f.a)) == 0, "a sync ran while frozen")
        #expect(await f.adapter.debugFreezeState.deferredSyncNow, "no follow-up scheduled for the kept event")

        _ = await f.adapter.debugResume(freezeToken: token)
        try await f.waitForCount("bc-kept-by-settle", f.a)
        #expect(count("bc-kept-by-settle", in: f.frames(f.a)) == 1)
    }

    @Test("A leave after the settle's commit sets membershipChanged")
    func leaveDuringSettleSendsFlagsMembership() async throws {
        let f = try await KeptEventsFixture.make(.tickless, members: ["a", "b"])
        // The settle runs only through the keeper's attached transport (#546 L2d-1).
        await f.keeper.setTransport(f.adapter)
        try await f.set("score", 3)

        // Hold the settle after its commit: its state copy is already taken.
        await f.hold.install(on: f.adapter, at: .settleBeforePublish)
        f.hold.arm()
        let adapter = f.adapter
        let freeze = Task { try await adapter.debugFreeze() }
        try await f.hold.waitUntilHeld()
        await f.adapter.onDisconnect(sessionID: f.b.session, clientID: f.b.client)
        f.hold.release()
        let token = try await freeze.value.freezeToken

        let projection = try await f.adapter.debugProjection(playerID: f.a.player)
        #expect(projection.membershipChanged, "a leave after the settle copy was taken is not flagged")
        _ = await f.adapter.debugResume(freezeToken: token)
        await f.settle()
    }
}
