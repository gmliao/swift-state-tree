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
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

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

// MARK: - Keeper blocker

/// Blocks the keeper actor from inside an action handler (the "block" action of the test land),
/// so a hop onto the keeper, such as `endSync()`, waits until the test releases it.
private final class KeptEventsKeeperBlocker: @unchecked Sendable {
    static let shared = KeptEventsKeeperBlocker()
    private let condition = NSCondition()
    private var entered = false
    private var released = false

    func block() {
        condition.lock()
        entered = true
        released = false
        condition.broadcast()
        while !released { condition.wait() }
        entered = false
        condition.unlock()
    }

    var isBlocking: Bool {
        condition.lock(); defer { condition.unlock() }
        return entered
    }

    func release() {
        condition.lock()
        released = true
        condition.broadcast()
        condition.unlock()
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
    private var batches = 0

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
        batches = 0
    }

    var batchCount: Int {
        lock.lock(); defer { lock.unlock() }
        return batches
    }

    /// Called by `sendBatch` (one writer element per call). Counts the per-player batches: elements
    /// carrying a per-player state frame (opcode 0...2). Before #60 those were the only frames
    /// sent through `sendBatch` (the merged frame went through `send`), so this keeps the count's
    /// meaning: cycles that sent a per-player batch.
    func countBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) {
        let hasPerPlayerFrame = updates.contains { (0...2).contains(opcodes([$0.0]).first ?? -1) }
        guard hasPerPlayerFrame else { return }
        lock.lock(); defer { lock.unlock() }
        batches += 1
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
        recorder.countBatch(updates)
    }
}

// MARK: - Helpers

private final class KeptEventsFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

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
    /// Holds a sync cycle in flight (frames enqueued, before `endSync`); see `SyncCycleHold`.
    let hold = SyncCycleHold()

    var a: KeptEventsMember { members[0] }
    var b: KeptEventsMember { members[1] }
    var recorder: KeptEventsRecorder { transport.recorder }
    var gate: GatedSerialExecutor { transport.executor }

    static func make(
        _ land: KeptEventsLand,
        members names: [String] = ["a"],
        autoStartLoops: Bool = true
    ) async throws -> KeptEventsFixture {
        let definition: LandDefinition<KeptEventsTestState>
        switch land {
        case .tickless:
            definition = Land("kept-events-test", using: KeptEventsTestState.self) {
                ServerEvents { Register(KeptEventsEvent.self) }
                Rules {
                    OnJoin { (state: inout KeptEventsTestState, ctx: LandContext) in
                        state.scores[ctx.playerID] = 0
                    }
                    HandleAction(KeptEventsSetAction.self) { (state: inout KeptEventsTestState, action: KeptEventsSetAction, ctx: LandContext) in
                        if action.field == "tick" {
                            state.tick = action.value
                        } else if action.field == "block" {
                            KeptEventsKeeperBlocker.shared.block()
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
                    StateSync(every: .seconds(3600)) { (_: KeptEventsTestState, _: LandContext) in }
                }
                Rules {
                    OnJoin { (state: inout KeptEventsTestState, ctx: LandContext) in
                        state.scores[ctx.playerID] = 0
                    }
                    HandleAction(KeptEventsSetAction.self) { (state: inout KeptEventsTestState, action: KeptEventsSetAction, ctx: LandContext) in
                        if action.field == "tick" {
                            state.tick = action.value
                        } else if action.field == "block" {
                            KeptEventsKeeperBlocker.shared.block()
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
            initialState: KeptEventsTestState(),
            autoStartLoops: autoStartLoops
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
                enableChangeObjectMetrics: false,
                changeObjectMetricsLogEvery: 10,
                changeObjectMetricsEmaAlpha: 0.2,
                enableAutoDirtyTracking: false,
                autoDirtyOffThreshold: 0.55,
                autoDirtyOnThreshold: 0.30,
                autoDirtyRequiredConsecutiveSamples: 30,
                profilingConfig: nil
            ),
            encodingConfig: .messagepack
        )
        await transport.setDelegate(adapter)
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
        await adapter.waitForOutboundDrain()
        await settle(transport)
        transport.recorder.clear()
        let fixture = KeptEventsFixture(keeper: keeper, adapter: adapter, transport: transport, members: members)
        await fixture.hold.install(on: adapter)
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
        await adapter.sendEvent(AnyServerEvent(KeptEventsEvent(message: message)), to: .all)
        await adapter.waitForOutboundDrain()
    }

    func targetedEvent(_ message: String, to member: KeptEventsMember) async {
        await adapter.sendEvent(AnyServerEvent(KeptEventsEvent(message: message)), to: .player(member.player))
        await adapter.waitForOutboundDrain()
    }

    /// Runs `syncNow` held in flight, runs `duringBatch`, then lets the cycle finish. Before
    /// #60 the cycle was held inside the transport's `sendBatch`; it no longer awaits the
    /// transport, so it is held after it enqueued its frames, before `endSync` (the event queue
    /// was read at the same points either way).
    func syncNowHoldingBatch(_ duringBatch: () async throws -> Void) async throws {
        hold.arm()
        let adapter = self.adapter
        let cycle = Task { await adapter.syncNow() }
        do {
            try await hold.waitUntilHeld()
            try await duringBatch()
        } catch {
            hold.release()
            await cycle.value
            throw error
        }
        hold.release()
        await cycle.value
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

@Suite("TransportAdapter keeps late-queued events for the next sync cycle (#77)", .timeLimit(.minutes(1)))
struct TransportAdapterPendingEventsAcrossCyclesTests {

    @Test("1: a broadcast event queued during the batch send arrives once, in the next cycle's merged frame")
    func broadcastEventQueuedDuringBatchArrivesNextCycle() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)
        #expect(f.keeper.hasPeriodicSync == true)

        try await f.set("score", 1)
        try await f.syncNowHoldingBatch {
            await f.broadcastEvent("bc-held")
        }
        await f.settle()
        #expect(count("bc-held", in: f.frames(f.a)) == 0, "kept for the next cycle, not sent by this one")

        f.recorder.clear()
        await f.adapter.syncNow()  // the next periodic cycle
        try await f.waitForCount("bc-held", f.a)
        let frames = f.frames(f.a)
        #expect(count("bc-held", in: frames) == 1, "kept broadcast event must arrive exactly once next cycle")
        let carrier = frames.first { $0.range(of: Data("bc-held".utf8)) != nil }
        #expect(carrier.map { opcodes([$0]) } == [107], "it rides in the next cycle's merged frame")
    }

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

    // Since #60 the broadcast-only cycle does not suspend at its send; the gate holds the writer's
    // delivery. The test still checks that events queued after the cycle arrive once each.
    @Test("3: a broadcast-only cycle keeps broadcast events queued during its send for the next cycle")
    func broadcastOnlyCycleKeepsLateEvents() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)

        try await f.set("tick", 1)
        f.gate.close()
        let adapter = f.adapter
        let cycle = Task { await adapter.syncBroadcastOnly() }
        // Held at the broadcast frame's send: broadcast events were read, targeted not yet.
        try await waitUntil("the broadcast frame send to be held") { f.gate.heldCount > 0 }
        await f.broadcastEvent("bc-late")
        await f.targetedEvent("tg-late", to: f.a)
        f.gate.open()
        await cycle.value
        await f.settle()

        await f.adapter.syncNow()
        await f.adapter.waitForOutboundDrain()
        try await f.waitForCount("bc-late", f.a)
        try await f.waitForCount("tg-late", f.a)
        let frames = f.frames(f.a)
        #expect(count("bc-late", in: frames) == 1, "broadcast event must arrive exactly once")
        #expect(count("tg-late", in: frames) == 1, "targeted event must arrive exactly once")
    }

    @Test("4: events read by cycle N are not resent by cycle N+1 (exact frame counts)")
    func noDuplicatesAcrossCycles() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)

        // Cycle N: a per-player change, a targeted and a broadcast event queued before it,
        // and a broadcast event queued during its batch send (kept for N+1).
        try await f.set("score", 1)
        await f.targetedEvent("tg-1", to: f.a)
        await f.broadcastEvent("bc-1")
        try await f.syncNowHoldingBatch {
            await f.broadcastEvent("bc-2")
        }
        await f.settle()
        // Cycle N+1: nothing new, only the kept event.
        await f.adapter.syncNow()
        await f.adapter.waitForOutboundDrain()
        await f.settle()
        try await f.waitForCount("bc-2", f.a)
        // Cycle N+2: nothing at all.
        await f.adapter.syncNow()
        await f.adapter.waitForOutboundDrain()
        await f.settle()

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
        await f.adapter.waitForOutboundDrain()
        await f.settle()
        var counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "syncNow drops them; left \(counts)")

        try await f.set("tick", 1)
        await f.broadcastEvent("bc-drop-2")
        await f.targetedEvent("tg-drop-2", to: f.a)
        await f.adapter.syncBroadcastOnly()
        await f.adapter.waitForOutboundDrain()
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
        await f.adapter.waitForOutboundDrain()
        try await f.waitForCount("bc-window", f.a)

        #expect(count("bc-window", in: f.frames(f.a)) == 1, "the eligible session gets the broadcast event")
        #expect(f.frames(f.b).isEmpty, "the initial-syncing session gets nothing")
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "the cycle consumed both; left \(counts)")
    }

    @Test("7: without periodic sync, an event kept by a cycle arrives through the follow-up cycle")
    func followUpDeliversKeptEventsWithoutPeriodicSync() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        #expect(f.keeper.hasPeriodicSync == false)

        try await f.set("score", 1)
        try await f.syncNowHoldingBatch {
            await f.broadcastEvent("bc-follow-up")
        }
        // No further sync request from the test.
        try await f.waitForCount("bc-follow-up", f.a)
        #expect(count("bc-follow-up", in: f.frames(f.a)) == 1, "the follow-up cycle must deliver the kept event once")
        #expect(f.recorder.batchCount == 1, "the follow-up has no per-player change, so no batch")
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0)
    }

    @Test("7b: with periodic sync, a kept event waits for the next periodic cycle (no follow-up)")
    func noFollowUpWithPeriodicSync() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync)
        #expect(f.keeper.hasPeriodicSync == true)

        // Every cycle gets an event during its batch send; only the test-driven (periodic) cycles run.
        for tick in 1...3 {
            try await f.set("score", tick)
            try await f.syncNowHoldingBatch {
                await f.broadcastEvent("bc-tick-\(tick)")
            }
            await f.settle()
        }
        try await f.waitForCount("bc-tick-2", f.a)
        #expect(f.recorder.batchCount == 3, "one cycle per periodic sync, no follow-ups")
        let frames = f.frames(f.a)
        #expect(count("bc-tick-1", in: frames) == 1 && count("bc-tick-2", in: frames) == 1)
        #expect(count("bc-tick-3", in: frames) == 0, "the last kept event waits for the next periodic cycle")
    }

    @Test("7c: without periodic sync, an event during every cycle gives events + 1 cycles, and syncNow returns after one")
    func followUpsAreBoundedAndDoNotBlockTheCaller() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        let events = 3

        // Each cycle's batch is held; the test then queues one broadcast event (kept, since the
        // merged frame was already built) and a per-player change, so the follow-up has a batch.
        try await f.set("score", 100)
        f.hold.arm()
        let adapter = f.adapter
        let returned = KeptEventsFlag()
        let cycle = Task {
            await adapter.syncNow()
            await adapter.waitForOutboundDrain()
            returned.set()
        }
        for index in 1...events {
            try await f.hold.waitUntilHeld()
            await f.broadcastEvent("bc-source-\(index)")
            try await f.set("score", 100 + index)
            if index < events { f.hold.arm() }
            f.hold.release()
            if index == 1 {
                // The follow-up's batch gets held, yet the caller's syncNow returns: it waits for
                // one cycle, not for the chain.
                try await waitUntil("the first syncNow to return while the follow-up runs") { returned.isSet }
            }
        }
        await cycle.value
        try await f.waitForCount("bc-source-\(events)", f.a)

        #expect(f.recorder.batchCount == events + 1, "cycles must be events + 1; got \(f.recorder.batchCount)")
        let frames = f.frames(f.a)
        for index in 1...events {
            #expect(count("bc-source-\(index)", in: frames) == 1, "bc-source-\(index) must arrive exactly once")
        }
    }

    @Test("7e: an event queued during the endSync hop (after cleanup) still gets a follow-up")
    func eventQueuedDuringEndSyncHopIsDelivered() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        let blocker = KeptEventsKeeperBlocker.shared

        // tg-pre goes out in the batch and is removed at cleanup: the queue goes 1 -> 0 there.
        try await f.set("score", 1)
        await f.targetedEvent("tg-pre", to: f.a)
        f.hold.arm()
        let adapter = f.adapter
        let cycle = Task { await adapter.syncNow() }
        try await f.hold.waitUntilHeld()

        // Block the keeper so the cycle's endSync() hop waits there.
        let keeper = f.keeper
        let a = f.a
        let blockingAction = Task {
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: KeptEventsSetAction.self),
                payload: AnyCodable(KeptEventsSetAction(field: "block", value: 0))
            )
            _ = try await keeper.handleActionEnvelope(
                envelope, playerID: a.player, clientID: a.client, sessionID: a.session
            )
        }
        try await waitUntil("the keeper to be blocked") { blocker.isBlocking }
        f.hold.release()

        // Cleanup is done once the queue is empty; the cycle's next step is the endSync() hop.
        let deadline = ContinuousClock.now + .seconds(5)
        while await adapter.pendingEventCounts() != (0, 0) {
            guard ContinuousClock.now < deadline else {
                blocker.release()
                Issue.record("the cycle never reached its cleanup")
                return
            }
            try await Task.sleep(for: .milliseconds(1))
        }
        await f.broadcastEvent("bc-hop")
        blocker.release()
        _ = try await blockingAction.value
        await cycle.value

        // No further sync request from the test: the post-endSync check must start the follow-up.
        try await f.waitForCount("bc-hop", f.a)
        #expect(count("bc-hop", in: f.frames(f.a)) == 1)
        #expect(count("tg-pre", in: f.frames(f.a)) == 1)
    }

    @Test("7d: a sync loop that does not auto-start is not periodic sync; the follow-up still delivers")
    func followUpWhenLoopsDoNotAutoStart() async throws {
        let f = try await KeptEventsFixture.make(.periodicSync, autoStartLoops: false)
        #expect(f.keeper.hasPeriodicSync == false)

        try await f.set("score", 1)
        try await f.syncNowHoldingBatch {
            await f.broadcastEvent("bc-no-loops")
        }
        try await f.waitForCount("bc-no-loops", f.a)
        #expect(count("bc-no-loops", in: f.frames(f.a)) == 1, "the follow-up cycle must deliver the kept event once")
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

    @Test("pendingTargetedBodies reads the half-open slice [start, end)")
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
            startingAt: 1,
            endingBefore: 4
        )
        #expect(slice == [body(1), body(2), body(3)])
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
                Tick(every: .seconds(3600)) { (_: inout KeptEventsTestState, _: LandContext) in }
            }
            Rules {}
        }
        let synced = Land("periodic-sync", using: KeptEventsTestState.self) {
            Lifetime {
                StateSync(every: .seconds(3600)) { (_: KeptEventsTestState, _: LandContext) in }
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
    @Test("A follow-up requested while frozen is deferred, then runs on resume")
    func followUpDeferredWhileFrozen() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        #expect(f.keeper.hasPeriodicSync == false)

        try await f.set("score", 1)
        var freeze: Task<DebugFreezeResponse, Error>?
        try await f.syncNowHoldingBatch {
            // Kept by this cycle, so its end requests a follow-up; the freeze is already in effect.
            await f.broadcastEvent("bc-frozen-follow-up")
            let adapter = f.adapter
            freeze = Task { try await adapter.debugFreeze() }
            for _ in 0..<5000 where await adapter.isDebugFrozen() == false {
                try await Task.sleep(for: .milliseconds(1))
            }
            #expect(await adapter.isDebugFrozen(), "freeze did not take effect")
        }
        let token = try #require(try await freeze?.value).freezeToken

        // The settle cycle delivered the kept event; the follow-up hit the freeze gate instead
        // of running.
        try await f.waitForCount("bc-frozen-follow-up", f.a)
        #expect(await f.adapter.debugFreezeState.deferredSyncNow, "follow-up was not deferred by the freeze")
        #expect(count("bc-frozen-follow-up", in: f.frames(f.a)) == 1)

        _ = await f.adapter.debugResume(freezeToken: token)
        await f.settle()
        #expect(await f.adapter.debugFreezeState.deferredSyncNow == false, "deferred follow-up did not run on resume")
        #expect(count("bc-frozen-follow-up", in: f.frames(f.a)) == 1, "the event was resent after resume")
    }

    @Test("An event kept by the settle cycle arrives once after resume")
    func eventKeptBySettleArrivesAfterResume() async throws {
        let f = try await KeptEventsFixture.make(.tickless)
        try await f.set("score", 2)

        // The settle cycle is the held one: the event is queued after its merged frame was built.
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

    @Test("A leave during the settle cycle's sends sets membershipChanged")
    func leaveDuringSettleSendsFlagsMembership() async throws {
        let f = try await KeptEventsFixture.make(.tickless, members: ["a", "b"])
        try await f.set("score", 3)

        // Hold the settle cycle's batch: its state copy is already taken.
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
