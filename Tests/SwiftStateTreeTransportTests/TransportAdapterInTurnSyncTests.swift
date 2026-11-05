// Tests/SwiftStateTreeTransportTests/TransportAdapterInTurnSyncTests.swift
//
// In-turn sync (`InTurnSync`): the sync phase runs inside the keeper's turns. The adapter shares
// the keeper's executor; the keeper calls `runSyncPhaseInTurn` synchronously after the tick
// handler, so inputs, tick, events, sync plan + commit and the writer enqueue form one actor turn.
//
// The reentrancy probe enqueues one job on the keeper and one on the adapter at "turn-begin" and
// waits, inside the turn, until both tasks have provably started (each bumps a counter right
// before its await). The jobs log from inside the actor methods. If the turn had a suspension
// point before its commit, a job would run there; the negative control inserts one
// (`await Task.yield()`) and the probe must see it.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// MARK: - Land

@StateNodeBuilder
struct InTurnSyncTestState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    @Sync(.broadcast) var total: Int = 0
    init() {}
}

@Payload
struct InTurnSyncEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

/// Adds `amount` to `total` and emits "input-event-<amount>" to everyone.
@Payload
struct InTurnEmitAction: ActionPayload {
    typealias Response = InTurnEmitResponse
    let amount: Int
}

@Payload
struct InTurnEmitResponse: ResponsePayload {
    let ok: Bool
}

/// Emits "input-event-targeted" to the sender, then "input-event-broadcast" to everyone.
@Payload
struct InTurnMixedAction: ActionPayload {
    typealias Response = InTurnEmitResponse
    init() {}
}

/// Each tick increments `ticks`, emits "tick-event-<ticks>" to everyone and requests a sync, so
/// every tick turn includes the sync phase.
private func makeInTurnSyncLand() -> LandDefinition<InTurnSyncTestState> {
    Land("in-turn-sync-test", using: InTurnSyncTestState.self) {
        ServerEvents { Register(InTurnSyncEvent.self) }
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout InTurnSyncTestState, ctx: LandContext) in
                state.ticks += 1
                ctx.emitEvent(InTurnSyncEvent(message: "tick-event-\(state.ticks)"), to: .all)
                ctx.requestSyncNow()
            }
        }
        Rules {
            HandleAction(InTurnEmitAction.self) { (state: inout InTurnSyncTestState, action: InTurnEmitAction, ctx: LandContext) in
                state.total += action.amount
                ctx.emitEvent(InTurnSyncEvent(message: "input-event-\(action.amount)"), to: .all)
                return InTurnEmitResponse(ok: true)
            }
            HandleAction(InTurnMixedAction.self) { (state: inout InTurnSyncTestState, _: InTurnMixedAction, ctx: LandContext) in
                ctx.emitEvent(InTurnSyncEvent(message: "input-event-targeted"), to: .player(ctx.playerID))
                ctx.emitEvent(InTurnSyncEvent(message: "input-event-broadcast"), to: .all)
                return InTurnEmitResponse(ok: true)
            }
        }
    }
}

private let inTurnPathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: ["ticks", "total"].map { ($0, DeterministicHash.fnv1a32($0)) }
)

enum InTurnEncoding: String, CaseIterable, Sendable, CustomStringConvertible {
    case json
    case opcodeJsonArray
    case messagepack

    var description: String { rawValue }

    var config: TransportEncodingConfig {
        switch self {
        case .json: return .json
        case .opcodeJsonArray: return .jsonOpcode
        case .messagepack: return .messagepack
        }
    }
}

// MARK: - Transport, log, decoding

/// Records every frame per session.
private actor InTurnSyncTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []
    private var sentAt: [ContinuousClock.Instant] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
        sentAt.append(ContinuousClock.now)
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            sent.append((target, data))
            sentAt.append(ContinuousClock.now)
        }
    }

    /// Frames for `sessionID` with the time each reached the transport.
    func timedMessages(for sessionID: SessionID) -> [(data: Data, at: ContinuousClock.Instant)] {
        zip(sent, sentAt).compactMap { entry, at in
            if case .session(let id) = entry.target, id == sessionID { return (entry.data, at) }
            return nil
        }
    }

    func messages(for sessionID: SessionID) -> [Data] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
}

/// An ordered, thread-safe log.
private final class InTurnProbeLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String] = []

    func append(_ entry: String) {
        lock.lock()
        entries.append(entry)
        lock.unlock()
    }

    var snapshot: [String] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

/// A thread-safe counter.
private final class InTurnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Holds callers until released; counts the callers waiting.
private actor InTurnGate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var waiting = 0

    func wait() async {
        guard !isOpen else { return }
        waiting += 1
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters.removeAll()
    }
}

/// A thread-safe switch.
private final class InTurnSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false

    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
}

/// What a frame carries, in frame order: state values (top-level path, Int) and event messages.
private enum InTurnItem: Equatable {
    case state(String, Int)
    case event(String)
}

private indirect enum InTurnWire {
    case null
    case int(Int)
    case string(String)
    case array([InTurnWire])
    case map([InTurnWire])

    init(json: Any) {
        if let s = json as? String {
            self = .string(s)
        } else if let a = json as? [Any] {
            self = .array(a.map(InTurnWire.init(json:)))
        } else if let m = json as? [String: Any] {
            self = .map(m.keys.sorted().map { InTurnWire(json: m[$0] as Any) })
        } else if let n = json as? NSNumber {
            self = .int(n.intValue)
        } else {
            self = .null
        }
    }

    init(msgpack: MessagePackValue) {
        switch msgpack {
        case .int(let v): self = .int(Int(v))
        case .uint(let v): self = .int(Int(v))
        case .string(let v): self = .string(v)
        case .array(let v): self = .array(v.map(InTurnWire.init(msgpack:)))
        case .map(let v): self = .map(v.map { InTurnWire(msgpack: $0.value) })
        default: self = .null
        }
    }

    var intValue: Int? {
        if case .int(let v) = self { return v }
        return nil
    }

    /// Event messages anywhere inside.
    var eventMessages: [String] {
        switch self {
        case .string(let s):
            return s.hasPrefix("input-event-") || s.hasPrefix("tick-event-") ? [s] : []
        case .array(let items), .map(let items):
            return items.flatMap(\.eventMessages)
        default:
            return []
        }
    }
}

private let inTurnPatternByHash = Dictionary(uniqueKeysWithValues: inTurnPathHashes.map { (Int($1), $0) })

/// State values of an opcode state array `[opcode, patch...]`: `[path, op, value]` or
/// `[pathHash, dynamicKeys, op, value]`; only top-level set/add patches with Int values.
private func stateItems(_ array: [InTurnWire]) -> [InTurnItem] {
    array.dropFirst().compactMap { entry in
        guard case .array(let parts) = entry, parts.count >= 3 else { return nil }
        if case .string(let path) = parts[0], let value = parts[2].intValue {
            return .state(String(path.dropFirst()), value)
        }
        if let hash = parts[0].intValue, let pattern = inTurnPatternByHash[hash], parts.count >= 4,
           let value = parts[3].intValue {
            return .state(pattern, value)
        }
        return nil
    }
}

/// Decodes one frame into its items, in order.
private func decodeItems(_ frame: Data, encoding: InTurnEncoding) -> [InTurnItem] {
    switch encoding {
    case .json:
        if let decoded = try? JSONStateUpdateDecoder().decode(data: frame) {
            let patches: [StatePatch]
            switch decoded.update {
            case .noChange: patches = []
            case .firstSync(let p), .diff(let p): patches = p
            }
            return patches.compactMap { patch in
                switch patch.operation {
                case .set(.int(let v)), .add(.int(let v)): return .state(String(patch.path.dropFirst()), v)
                default: return nil
                }
            }
        }
        guard let json = try? JSONSerialization.jsonObject(with: frame) else { return [] }
        return InTurnWire(json: json).eventMessages.map(InTurnItem.event)
    case .opcodeJsonArray:
        guard let json = try? JSONSerialization.jsonObject(with: frame) else { return [] }
        let wire = InTurnWire(json: json)
        if case .array(let array) = wire, let opcode = array.first?.intValue, (0...2).contains(opcode) {
            return stateItems(array)
        }
        return wire.eventMessages.map(InTurnItem.event)
    case .messagepack:
        guard let value = try? unpack(frame) else { return [] }
        let wire = InTurnWire(msgpack: value)
        guard case .array(let array) = wire, let opcode = array.first?.intValue else { return [] }
        if opcode == 107, array.count >= 2, case .array(let state) = array[1] {
            return stateItems(state) + array.dropFirst(2).flatMap(\.eventMessages).map(InTurnItem.event)
        }
        if (0...2).contains(opcode) {
            return stateItems(array)
        }
        return wire.eventMessages.map(InTurnItem.event)
    }
}

// MARK: - Fixture

private struct InTurnSyncFixture {
    let encoding: InTurnEncoding
    let keeper: LandKeeper<InTurnSyncTestState>
    let adapter: TransportAdapter<InTurnSyncTestState>
    let transport: InTurnSyncTransport
    let session = SessionID("its-session")
    let client = ClientID("its-client")
    let player = PlayerID("its-player")

    static func make(
        encoding: InTurnEncoding,
        inTurn: Bool = true,
        recording: Bool = false
    ) async throws -> InTurnSyncFixture {
        let transport = InTurnSyncTransport()
        let keeper = LandKeeper<InTurnSyncTestState>(
            definition: makeInTurnSyncLand(),
            initialState: InTurnSyncTestState(),
            enableLiveStateHashRecording: recording,
            autoStartLoops: false
        )
        let adapter = TransportAdapter<InTurnSyncTestState>(
            keeper: keeper,
            transport: transport,
            landID: "in-turn-sync-test",
            encodingConfig: encoding.config,
            pathHashes: encoding == .json ? nil : inTurnPathHashes,
            inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let fixture = InTurnSyncFixture(encoding: encoding, keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: fixture.client,
            playerID: fixture.player
        )
        #expect(await adapter.waitForOutboundDrain())
        return fixture
    }

    func act(_ amount: Int) async throws {
        _ = try await keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: InTurnEmitAction.self),
                payload: AnyCodable(InTurnEmitAction(amount: amount))
            ),
            playerID: player,
            clientID: client,
            sessionID: session
        )
    }

    func frameCount() async -> Int {
        await transport.messages(for: session).count
    }

    /// Steps one tick and returns the frames it sent, decoded.
    func tick() async -> [[InTurnItem]] {
        let before = await frameCount()
        await keeper.stepTickOnce()
        #expect(await adapter.waitForOutboundDrain())
        return await transport.messages(for: session).dropFirst(before).map { decodeItems($0, encoding: encoding) }
    }
}

/// Sorted-key JSON of the recorded tick frames.
private func recordedFramesJSON(
    _ keeper: LandKeeper<InTurnSyncTestState>,
    withoutSyncStream: Bool = false
) async throws -> Data {
    let recorder = try #require(await keeper.getReevaluationRecorder())
    var frames = await recorder.getAllFrames()
    if withoutSyncStream {
        frames = frames.map { $0.replacing(syncOutputs: [], syncMarkers: []) }
    }
    #expect(!frames.isEmpty)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(frames)
}

// MARK: - Tests

@Suite(
    "In-turn sync: the sync phase inside the keeper turn",
    .timeLimit(.minutes(1)),
    .enabled(if: InTurnSync.isEnabled(), "IN_TURN_SYNC=false: these tests check the in-turn path")
)
struct TransportAdapterInTurnSyncTests {

    @Test("in-turn sync only for the adapter's own keeper; an adapter of another keeper does not trap")
    func inTurnSyncOnlyForOwnKeeper() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .json)
        #expect(f.adapter.runsSyncPhaseInTurn(of: f.keeper))

        let other = LandKeeper<InTurnSyncTestState>(
            definition: makeInTurnSyncLand(),
            initialState: InTurnSyncTestState(),
            autoStartLoops: false
        )
        #expect(f.adapter.runsSyncPhaseInTurn(of: other) == false)
        // `other` uses the legacy path with this adapter: no `assumeIsolated` on a foreign
        // executor (which would trap).
        await other.setTransport(f.adapter)
        await other.stepTickOnce()
        #expect(await other.currentState().ticks == 1)

        // The own keeper's turn enters the adapter with `assumeIsolated`: shared executor.
        _ = await f.tick()
        #expect(await f.adapter.syncFailedPlans == 0)
    }

    @Test(
        "reentrancy probe: jobs started during the turn run after its commit; an inserted yield is detected",
        arguments: [false, true]
    )
    func reentrancyProbe(insertYield: Bool) async throws {
        let f = try await InTurnSyncFixture.make(encoding: .messagepack)
        let keeper = f.keeper
        let adapter = f.adapter
        let log = InTurnProbeLog()
        let started = InTurnCounter()
        let spawned = InTurnSwitch()
        await keeper.setInTurnYieldForTesting(insertYield)
        await keeper.setInTurnProbeForTesting { label in
            log.append(label)
            guard label == "turn-begin", !spawned.isOn else { return }
            spawned.set(true)
            Task {
                started.increment()
                await keeper.runIsolatedForTesting { log.append("keeper-job") }
            }
            Task {
                started.increment()
                await adapter.runIsolatedForTesting { log.append("adapter-job") }
            }
            // Inside the turn: wait until both tasks have started (bumped right before their
            // await), then a little longer so both jobs are enqueued on the shared executor.
            // Bounded: this blocks a pool thread; a miss fails the `started` expectation below.
            let deadline = ContinuousClock.now + .milliseconds(500)
            while started.value < 2 && ContinuousClock.now < deadline {
                usleep(100)
            }
            usleep(5_000)
        }

        await keeper.stepTickOnce()
        for _ in 0..<200 where !(log.snapshot.contains("keeper-job") && log.snapshot.contains("adapter-job")) {
            try await safeTaskSleep(for: .milliseconds(10))
        }
        let order = log.snapshot
        #expect(started.value == 2, "both tasks started inside the turn: \(order)")
        let committed = try #require(order.firstIndex(of: "sync-committed"), "order: \(order)")
        let jobs = [order.firstIndex(of: "keeper-job"), order.firstIndex(of: "adapter-job")].compactMap { $0 }
        #expect(jobs.count == 2, "both jobs ran: \(order)")
        if insertYield {
            #expect(jobs.contains { $0 < committed }, "negative control: the yield lets a job run inside the turn: \(order)")
        } else {
            #expect(Array(order.prefix(3)) == ["turn-begin", "sync-committed", "turn-end"], "order: \(order)")
            #expect(jobs.allSatisfy { $0 > committed }, "both jobs ran after the commit: \(order)")
        }
    }

    @Test(
        "json / opcodeJsonArray: input and tick events reach the writer in emit order, before the turn's state",
        arguments: [InTurnEncoding.json, .opcodeJsonArray]
    )
    func eventsPrecedeTheTurnStateFrame(encoding: InTurnEncoding) async throws {
        let f = try await InTurnSyncFixture.make(encoding: encoding)
        try await f.act(5)
        let items = await f.tick().flatMap { $0 }

        let input = try #require(items.firstIndex(of: .event("input-event-5")), "items: \(items)")
        let tick = try #require(items.firstIndex(of: .event("tick-event-1")), "items: \(items)")
        let ticks = try #require(items.firstIndex(of: .state("ticks", 1)), "items: \(items)")
        let total = try #require(items.firstIndex(of: .state("total", 5)), "items: \(items)")
        #expect(input < tick, "the input's event first: \(items)")
        #expect(tick < ticks && tick < total, "events before the turn's state: \(items)")
        #expect(await f.adapter.syncFailedPlans == 0)
    }

    @Test("opcode 107: the turn's state and its broadcast events go in one merged frame")
    func eventsMergedIntoTheTurnFrame() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .messagepack)
        try await f.act(5)
        let frames = await f.tick()

        let merged = frames.filter { $0.contains(.state("ticks", 1)) }
        #expect(merged.count == 1, "one frame with the state: \(frames)")
        let frame = try #require(merged.first)
        #expect(frame.contains(.state("total", 5)), "frame: \(frame)")
        #expect(frame.contains(.event("input-event-5")), "frame: \(frame)")
        #expect(frame.contains(.event("tick-event-1")), "frame: \(frame)")
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "consumed by the turn's commit")
    }

    @Test("the turn's commit clears the dirty flags in the same turn")
    func commitClearsDirtyFlags() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .json)
        _ = await f.tick()
        #expect(await f.keeper.currentState().isDirty() == false)
    }

    @Test("writer back-pressure defers the turn's sync: flags and 107 events kept; the drain retry sends them once")
    func backPressureDefersTheSync() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .messagepack)
        let pressured = InTurnSwitch()
        pressured.set(true)
        await f.adapter.setWriterBackPressureOverrideForTesting { pressured.isOn }

        let deferred = await f.tick()
        #expect(deferred.allSatisfy { !$0.contains(.state("ticks", 1)) }, "no state frame: \(deferred)")
        #expect(await f.keeper.inTurnDeferredTurns == 1)
        #expect(await f.keeper.currentState().isDirty(), "dirty flags kept")
        #expect(await f.adapter.pendingEventCounts().broadcast == 1, "the 107 event stays queued")

        // No periodic sync here: one sync-only turn runs once the writer drains.
        let before = await f.frameCount()
        pressured.set(false)
        for _ in 0..<200 where await f.frameCount() == before {
            try await safeTaskSleep(for: .milliseconds(5))
        }
        #expect(await f.adapter.waitForOutboundDrain())
        let retried = await f.transport.messages(for: f.session).dropFirst(before)
            .flatMap { decodeItems($0, encoding: f.encoding) }
        #expect(retried.contains(.state("ticks", 1)), "the retry sent the deferred state: \(retried)")
        #expect(retried.filter { $0 == .event("tick-event-1") }.count == 1, "the deferred event exactly once: \(retried)")
        #expect(await f.keeper.inTurnDeferredTurns == 1)

        let items = await f.tick().flatMap { $0 }
        #expect(items.contains(.state("ticks", 2)), "items: \(items)")
        #expect(!items.contains(.event("tick-event-1")), "not sent again: \(items)")
        #expect(items.contains(.event("tick-event-2")))
    }

    @Test("replay parity: in-turn and legacy paths record identical frames (sequences, ticks, watermarks, hashes)")
    func replayParity() async throws {
        // Only the in-turn path records a sync stream (record format 2.1); everything else matches.
        var recorded: [Data] = []
        for inTurn in [true, false] {
            let f = try await InTurnSyncFixture.make(encoding: .json, inTurn: inTurn, recording: true)
            await f.keeper.stepTickOnce()
            for tick in 0..<4 {
                for n in 0..<(tick % 2 + 1) {
                    try await f.act(tick * 10 + n)
                }
                await f.keeper.stepTickOnce()
            }
            await f.keeper.waitForRecorderSubmissionsForTesting()
            recorded.append(try await recordedFramesJSON(f.keeper, withoutSyncStream: true))
        }
        #expect(recorded[0] == recorded[1], "in-turn \(String(decoding: recorded[0], as: UTF8.self)) vs legacy \(String(decoding: recorded[1], as: UTF8.self))")
    }

    // MARK: - Coincident-sync rule and cadence (A.2)

    /// A land with running loops: `ticks` changes every tick, the sync loop runs at `sync`.
    private static func makeTimedFixture(
        tick: Duration,
        sync: Duration,
        inTurn: Bool
    ) async throws -> (keeper: LandKeeper<InTurnSyncTestState>, adapter: TransportAdapter<InTurnSyncTestState>, transport: InTurnSyncTransport, session: SessionID) {
        let definition = Land("in-turn-timed-test", using: InTurnSyncTestState.self) {
            Lifetime {
                Tick(every: tick) { (state: inout InTurnSyncTestState, _: LandContext) in
                    state.ticks += 1
                }
                StateSync(every: sync) { (_: InTurnSyncTestState, _: LandContext) in }
            }
        }
        let transport = InTurnSyncTransport()
        let keeper = LandKeeper<InTurnSyncTestState>(
            definition: definition,
            initialState: InTurnSyncTestState(),
            enableLoopPhaseOffset: false
        )
        let adapter = TransportAdapter<InTurnSyncTestState>(
            keeper: keeper,
            transport: transport,
            landID: "in-turn-timed-test",
            inTurnSync: inTurn
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let session = SessionID("timed-session")
        await adapter.onConnect(sessionID: session, clientID: ClientID("timed-client"))
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: session,
            clientID: ClientID("timed-client"),
            playerID: PlayerID("timed-player")
        )
        return (keeper, adapter, transport, session)
    }

    @Test("coincident-sync rule: a sync due within the window of the next tick folds into that tick turn")
    func coincidentSyncFolds() async throws {
        // Loops run (hourly), so the keeper has a tick task and a sync task; the test sets the
        // next tick deadline and runs one sync loop iteration by hand.
        let f = try await Self.makeTimedFixture(tick: .seconds(3600), sync: .seconds(3600), inTurn: true)
        for _ in 0..<200 where await f.keeper.appliedSyncPhaseOffset == nil {
            try await safeTaskSleep(for: .milliseconds(5))
        }
        #expect(await f.adapter.waitForOutboundDrain())
        let base = await f.transport.messages(for: f.session).count

        // Next tick far away: a sync-only turn now, no fold.
        await f.keeper.setNextTickDeadlineForTesting(ContinuousClock.now + .seconds(10))
        await f.keeper.stepTickOnce()  // ticks = 1, no sync requested
        await f.keeper.runSyncLoopIterationForTesting()
        #expect(await f.keeper.foldedSyncs == 0)
        #expect(await f.adapter.waitForOutboundDrain())
        let afterSyncOnly = await f.transport.messages(for: f.session).dropFirst(base)
            .flatMap { decodeItems($0, encoding: .json) }
        #expect(afterSyncOnly.contains(.state("ticks", 1)), "the sync-only turn sent the state: \(afterSyncOnly)")

        // Next tick within the window: the sync folds into that tick turn instead of running first.
        let mid = await f.transport.messages(for: f.session).count
        await f.keeper.setNextTickDeadlineForTesting(ContinuousClock.now + .milliseconds(1))
        await f.keeper.runSyncLoopIterationForTesting()
        #expect(await f.keeper.foldedSyncs == 1)
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.transport.messages(for: f.session).count == mid, "no sync-only turn ran ahead of the tick")
        await f.keeper.stepTickOnce()  // the folded sync runs in this tick turn: ticks = 2
        #expect(await f.adapter.waitForOutboundDrain())
        let folded = await f.transport.messages(for: f.session).dropFirst(mid)
            .flatMap { decodeItems($0, encoding: .json) }
        #expect(folded.contains(.state("ticks", 2)), "the tick turn carried the folded sync: \(folded)")
        #expect(await f.keeper.syncRequestTicksForTesting().isEmpty, "the handler's request was taken too")
        #expect(!folded.contains(.state("ticks", 1)), "no frame with the pre-tick state: \(folded)")
        await f.keeper.forceShutdown()
    }

    @Test("cadence: with tick ≠ sync interval, state frames keep the sync loop's interval (ON vs OFF, stepped)")
    func cadenceMatchesLegacy() async throws {
        // A simulated 1 s with ticks every 20 ms and syncs every 50 ms, stepped by hand: the
        // loops run hourly (so the keeper has both tasks) and never fire. At an instant with
        // both, the sync runs first, with the tick due now (ON: it folds into that tick turn).
        // Counted on simulated time, so the result doesn't depend on the runner's scheduler
        // (#164); the wall-clock comparison belongs to the perf A/B.
        var frameTimes: [Bool: [Int]] = [:]
        var foldedSyncs: [Bool: Int] = [:]
        for inTurn in [true, false] {
            let f = try await Self.makeTimedFixture(tick: .seconds(3600), sync: .seconds(3600), inTurn: inTurn)
            for _ in 0..<200 where await f.keeper.appliedSyncPhaseOffset == nil {
                try await safeTaskSleep(for: .milliseconds(5))
            }
            #expect(await f.adapter.waitForOutboundDrain())
            var seen = await f.transport.messages(for: f.session).count
            var times: [Int] = []
            for t in stride(from: 10, through: 1000, by: 10) {
                let tickDue = t % 20 == 0
                if t % 50 == 0 {
                    let untilTick: Duration = tickDue ? .milliseconds(1) : .seconds(10)
                    await f.keeper.setNextTickDeadlineForTesting(ContinuousClock.now + untilTick)
                    await f.keeper.runSyncLoopIterationForTesting()
                }
                if tickDue { await f.keeper.stepTickOnce() }
                #expect(await f.adapter.waitForOutboundDrain())
                let messages = await f.transport.messages(for: f.session)
                let stateFrames = messages.dropFirst(seen).filter { message in
                    decodeItems(message, encoding: .json).contains { if case .state = $0 { return true } else { return false } }
                }
                seen = messages.count
                times += Array(repeating: t, count: stateFrames.count)
            }
            foldedSyncs[inTurn] = await f.keeper.foldedSyncs
            await f.keeper.forceShutdown()
            frameTimes[inTurn] = times
        }
        let every50 = Array(stride(from: 50, through: 1000, by: 50))
        #expect(frameTimes[true] == every50, "ON: one state frame per sync, at its instant: \(frameTimes[true] ?? [])")
        #expect(frameTimes[false] == every50, "OFF: \(frameTimes[false] ?? [])")
        // 100, 200, ... 1000: the syncs coincident with a tick folded into it.
        #expect(foldedSyncs[true] == 10)
        #expect(foldedSyncs[false] == 0, "the legacy path has no coincident fold")
    }

    @Test("cadence smoke (wall clock): with running loops, state frames come near the sync interval (ON and OFF)", arguments: [true, false])
    func cadenceSmokeWallClock(inTurn: Bool) async throws {
        let report = try await Self.measureCadence(inTurn: inTurn, duration: .milliseconds(1200))
        if ProcessInfo.processInfo.environment["CADENCE_REPORT"] == "1" {
            print("CADENCE \(report.summary)")
        }
        try #require(report.gaps.count >= 10, "state frames: \(report.gaps.count + 1)")
        // Tolerance: half to twice the 50 ms interval, on the median only (scheduler jitter on
        // shared runners; tails belong to the perf A/B). The message names the mechanism behind
        // each long gap, so a miss on CI says which one fired (#164).
        let median = report.gaps.sorted()[report.gaps.count / 2]
        #expect(median > .milliseconds(25) && median < .milliseconds(100), "median \(median): \(report.summary)")
    }

    /// Counters sampled while a cadence run goes.
    struct CadenceSample {
        var at: ContinuousClock.Instant
        var backlogSkips: Int
        var busySkips: Int
        var deferredTurns: Int
        var foldedSyncs: Int
        var ticks: Int64
    }

    /// A cadence run: the gaps between state frames, and each long one (over 1.5 sync intervals)
    /// with the counters that moved inside it.
    struct CadenceReport {
        var inTurn: Bool
        var gaps: [Duration]
        var longGaps: [String]
        var totals: String

        var summary: String {
            let sorted = gaps.sorted()
            let p90 = sorted.isEmpty ? .zero : sorted[sorted.count * 9 / 10]
            let median = sorted.isEmpty ? .zero : sorted[sorted.count / 2]
            return "\(inTurn ? "ON" : "OFF") frames=\(gaps.count + 1) median=\(median) p90=\(p90) \(totals) long=[\(longGaps.joined(separator: "; "))]"
        }
    }

    /// Runs the land (tick 20 ms, sync 50 ms) for `duration` with its loops, sampling the skip,
    /// deferral and fold counters and the tick count every few milliseconds, and attributes
    /// each long gap between state frames to the counters that moved inside it.
    static func measureCadence(inTurn: Bool, duration: Duration) async throws -> CadenceReport {
        let f = try await makeTimedFixture(tick: .milliseconds(20), sync: .milliseconds(50), inTurn: inTurn)
        let keeper = f.keeper, adapter = f.adapter
        // The probe runs on the measured executors (ON: the keeper's, shared with the adapter),
        // so it is kept small: two calls per sample (the adapter's skip counts; the keeper's
        // counters in one call, no state copy), every 10 ms, about 200 calls/s. 10 ms still puts
        // several samples inside any gap over 75 ms, the only ones labelled.
        let sampler = Task { () -> [CadenceSample] in
            var samples: [CadenceSample] = []
            while !Task.isCancelled {
                let skips = await adapter.syncSkipCounts()
                let counters = await keeper.cadenceCountersForTesting()
                samples.append(CadenceSample(
                    at: .now,
                    backlogSkips: skips.outboundBacklog,
                    busySkips: skips.busy,
                    deferredTurns: counters.deferredTurns,
                    foldedSyncs: counters.foldedSyncs,
                    ticks: counters.ticksStarted
                ))
                guard (try? await safeTaskSleep(for: .milliseconds(10))) != nil else { break }
            }
            return samples
        }
        try await safeTaskSleep(for: duration)
        sampler.cancel()
        let samples = await sampler.value
        let times = await f.transport.timedMessages(for: f.session)
            .filter { decodeItems($0.data, encoding: .json).contains { if case .state = $0 { return true } else { return false } } }
            .map(\.at)
        await f.keeper.forceShutdown()

        let start = times.first ?? .now
        let ms: (Duration) -> Int = { Int($0 / .milliseconds(1)) }
        func at(_ instant: ContinuousClock.Instant) -> CadenceSample? {
            samples.last { $0.at <= instant } ?? samples.first
        }
        var longGaps: [String] = []
        for (from, to) in zip(times, times.dropFirst()) where to - from > .milliseconds(75) {
            guard let a = at(from), let b = at(to) else { continue }
            var causes: [String] = []
            if b.backlogSkips > a.backlogSkips { causes.append("backlogSkip×\(b.backlogSkips - a.backlogSkips)") }
            if b.busySkips > a.busySkips { causes.append("busySkip×\(b.busySkips - a.busySkips)") }
            if b.deferredTurns > a.deferredTurns { causes.append("deferredTurn×\(b.deferredTurns - a.deferredTurns)") }
            if b.foldedSyncs > a.foldedSyncs { causes.append("fold×\(b.foldedSyncs - a.foldedSyncs)") }
            let ticks = b.ticks - a.ticks
            // At 20 ms a 75 ms window holds three or more ticks; fewer means the tick loop stalled.
            if Int(ticks) * 20 < ms(to - from) - 30 { causes.append("tickStall(ticks=\(ticks))") }
            let label = causes.isEmpty ? "unattributed" : causes.joined(separator: "+")
            longGaps.append("@\(ms(from - start))ms \(ms(to - from))ms \(label)")
        }
        let last = samples.last
        let totals = "backlogSkips=\(last?.backlogSkips ?? 0) busySkips=\(last?.busySkips ?? 0) deferredTurns=\(last?.deferredTurns ?? 0) folded=\(last?.foldedSyncs ?? 0) ticks=\(last?.ticks ?? 0)"
        return CadenceReport(
            inTurn: inTurn,
            gaps: zip(times.dropFirst(), times).map { $0 - $1 },
            longGaps: longGaps,
            totals: totals
        )
    }

    // MARK: - No lost requests (A.4)

    @Test("a turn's sync during a legacy cycle is not lost: it runs as a sync-only turn after endSync")
    func syncDuringLegacyCycleRunsAfterEndSync() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .json)
        let gate = InTurnGate()
        await f.adapter.setDebugCycleHoldBeforeEndSync { await gate.wait() }
        // A legacy cycle (the adapter's own syncNow), held before its endSync.
        let legacy = Task { await f.adapter.syncNow() }
        for _ in 0..<400 where await gate.waiting == 0 {
            try await safeTaskSleep(for: .milliseconds(5))
        }
        #expect(await gate.waiting == 1)
        await f.adapter.setDebugCycleHoldBeforeEndSync(nil)

        let before = await f.frameCount()
        await f.keeper.stepTickOnce()  // requests a sync while the legacy cycle holds the flag
        let held = await f.transport.messages(for: f.session).dropFirst(before)
            .flatMap { decodeItems($0, encoding: .json) }
        #expect(!held.contains(.state("ticks", 1)), "no state while the cycle is in flight: \(held)")

        await gate.release()
        await legacy.value
        for _ in 0..<200 {
            let items = await f.transport.messages(for: f.session).dropFirst(before)
                .flatMap { decodeItems($0, encoding: .json) }
            if items.contains(.state("ticks", 1)) { break }
            try await safeTaskSleep(for: .milliseconds(5))
        }
        let items = await f.transport.messages(for: f.session).dropFirst(before)
            .flatMap { decodeItems($0, encoding: .json) }
        #expect(items.contains(.state("ticks", 1)), "the request ran after endSync: \(items)")
        #expect(items.filter { $0 == .event("tick-event-1") }.count == 1, "event once: \(items)")
    }

    // MARK: - Events (A.7)

    @Test("opcode 107 order limit: a targeted event emitted before a broadcast one arrives after it")
    func opcode107MixedTargetOrder() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .messagepack)
        _ = try await f.keeper.handleActionEnvelope(
            ActionEnvelope(
                typeIdentifier: String(describing: InTurnMixedAction.self),
                payload: AnyCodable(InTurnMixedAction())
            ),
            playerID: f.player,
            clientID: f.client,
            sessionID: f.session
        )
        let items = await f.tick().flatMap { $0 }
        let targeted = try #require(items.firstIndex(of: .event("input-event-targeted")), "items: \(items)")
        let broadcast = try #require(items.firstIndex(of: .event("input-event-broadcast")), "items: \(items)")
        // Per session: the merged broadcast frame, then the targeted event frames, then the
        // per-player frame. Emit order holds within each frame kind only.
        #expect(broadcast < targeted, "documented order: broadcast first: \(items)")
    }

    // MARK: - Recorder (A.6)

    @Test("recorder: overlapping stepTickOnce calls record one frame per tick, in tick order")
    func recorderOverlappingSteps() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .json, recording: true)
        try await f.act(1)
        async let first: Void = f.keeper.stepTickOnce()
        async let second: Void = f.keeper.stepTickOnce()
        async let third: Void = f.keeper.stepTickOnce()
        _ = await (first, second, third)
        let recorder = try #require(await f.keeper.getReevaluationRecorder())
        let ticks = await recorder.getAllFrames().map(\.tickId)
        #expect(ticks == Array(Set(ticks)).sorted(), "unique, ascending: \(ticks)")
        let frames = await recorder.getAllFrames()
        #expect(frames.flatMap(\.actions).count == 1, "the input once")
    }
}

/// The switch itself; runs whatever the environment says.
@Suite("In-turn sync: the switch", .timeLimit(.minutes(1)))
struct InTurnSyncSwitchTests {
    @Test("the switch: an adapter with in-turn sync off keeps the legacy path for its own keeper")
    func switchOffKeepsLegacyPath() async throws {
        let f = try await InTurnSyncFixture.make(encoding: .json, inTurn: false)
        #expect(f.adapter.inTurnSyncEnabled == false)
        #expect(f.adapter.runsSyncPhaseInTurn(of: f.keeper) == false)
        #expect(await f.keeper.isUsingInTurnSync() == false)
        // The tick's sync request still syncs, through the legacy cycle.
        try await f.act(5)
        let items = await f.tick().flatMap { $0 }
        #expect(items.contains(.state("ticks", 1)), "items: \(items)")
        #expect(items.contains(.state("total", 5)), "items: \(items)")
    }

    @Test("the switch: IN_TURN_SYNC defaults on; an explicit off wins")
    func switchEnvironment() {
        #expect(InTurnSync.isEnabled(environment: [:]))
        #expect(InTurnSync.isEnabled(environment: [EnvKeys.Runtime.inTurnSync: "true"]))
        #expect(InTurnSync.isEnabled(environment: [EnvKeys.Runtime.inTurnSync: "false"]) == false)
    }
}
