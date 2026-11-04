// Tests/SwiftStateTreeTransportTests/TransportAdapterInTurnSyncTests.swift
//
// Layer-3 spike: the sync phase runs inside the keeper's tick turn. The adapter shares the
// keeper's executor; the keeper calls `runSyncPhaseInTurn` synchronously after the tick handler,
// so inputs, tick, events, sync plan + commit and the writer enqueue form one actor turn.
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
@testable import SwiftStateTreeTransport

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

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}

    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append((target, message))
    }

    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        for (data, target) in updates {
            sent.append((target, data))
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
        await keeper.setInTurnSyncEnabledForTesting(inTurn)
        let adapter = TransportAdapter<InTurnSyncTestState>(
            keeper: keeper,
            transport: transport,
            landID: "in-turn-sync-test",
            encodingConfig: encoding.config,
            pathHashes: encoding == .json ? nil : inTurnPathHashes
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
private func recordedFramesJSON(_ keeper: LandKeeper<InTurnSyncTestState>) async throws -> Data {
    let recorder = try #require(await keeper.getReevaluationRecorder())
    let frames = await recorder.getAllFrames()
    #expect(!frames.isEmpty)
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    return try encoder.encode(frames)
}

// MARK: - Tests

@Suite("Layer-3 spike: sync inside the keeper turn", .timeLimit(.minutes(1)))
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
            let deadline = ContinuousClock.now + .seconds(2)
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

    @Test("writer back-pressure defers the turn's sync: flags, due and 107 events kept; the next turn sends them once")
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

        pressured.set(false)
        let frames = await f.tick()
        let items = frames.flatMap { $0 }
        #expect(items.contains(.state("ticks", 2)), "items: \(items)")
        #expect(items.filter { $0 == .event("tick-event-1") }.count == 1, "the deferred event exactly once: \(items)")
        #expect(items.contains(.event("tick-event-2")))
        #expect(await f.keeper.inTurnDeferredTurns == 1)
    }

    @Test("replay parity: in-turn and legacy paths record identical frames (sequences, ticks, watermarks, hashes)")
    func replayParity() async throws {
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
            recorded.append(try await recordedFramesJSON(f.keeper))
        }
        #expect(recorded[0] == recorded[1], "in-turn \(String(decoding: recorded[0], as: UTF8.self)) vs legacy \(String(decoding: recorded[1], as: UTF8.self))")
    }
}
