// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncPhaseTests.swift
//
// The sync phase as plan + commit: a plan is synchronous and changes nothing but the diff
// caches; its commit removes the consumed events, applies the metric updates and enqueues the
// frames. A plan that fails commits nothing and makes the next plan a full-snapshot cycle
// (`.all` extraction, `.empty` baseline for broadcast and per-player diffs), because the failed
// cycle already advanced the caches and its `beginSync` already cleared the dirty flags.
//
// Failures are injected deterministically: a fault hook that throws at the end of a plan (after
// the caches advanced and every frame was encoded), or an encoder that fails on demand.

import Foundation
import Testing
import SwiftStateTreeMessagePack
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test state and action

@StateNodeBuilder
struct SyncPhaseTestState: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    @Sync(.perPlayerSlice()) var bonuses: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct SyncPhaseSetAction: ActionPayload {
    typealias Response = SyncPhaseSetResponse
    /// "a", "b", "score" or "bonus" (the calling player's `scores` / `bonuses` entry).
    let field: String
    let value: Int
}

@Payload
struct SyncPhaseSetResponse: ResponsePayload {
    let ok: Bool
}

@Payload
struct SyncPhaseEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

private func makeSyncPhaseLand() -> LandDefinition<SyncPhaseTestState> {
    Land("sync-phase-test", using: SyncPhaseTestState.self) {
        ServerEvents { Register(SyncPhaseEvent.self) }
        Lifetime {
            // Periodic sync configured but far apart: no follow-up cycles, no timer cycles.
            StateSync(every: .seconds(3600)) { (_: SyncPhaseTestState, _: LandContext) in }
        }
        Rules {
            OnJoin { (state: inout SyncPhaseTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
                state.bonuses[ctx.playerID] = 0
            }
            HandleAction(SyncPhaseSetAction.self) { (state: inout SyncPhaseTestState, action: SyncPhaseSetAction, ctx: LandContext) in
                switch action.field {
                case "a": state.a = action.value
                case "b": state.b = action.value
                case "bonus": state.bonuses[ctx.playerID] = action.value
                default: state.scores[ctx.playerID] = action.value
                }
                return SyncPhaseSetResponse(ok: true)
            }
        }
    }
}

// MARK: - Transport, encoder, fault

/// Records every frame per session.
private actor SyncPhaseTransport: Transport {
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

private struct SyncPhaseFault: Error {}

/// A switch the tests flip from outside the adapter.
private final class SyncPhaseSwitch: @unchecked Sendable {
    private let lock = NSLock()
    private var on = false
    var isOn: Bool { lock.lock(); defer { lock.unlock() }; return on }
    func set(_ value: Bool) { lock.lock(); on = value; lock.unlock() }
}

/// JSON encoder that fails every `.diff` update while `failDiffs` is on (firstSync and
/// `.noChange` still encode).
private struct FailingDiffEncoder: StateUpdateEncoder {
    let failDiffs: SyncPhaseSwitch
    private let inner = JSONStateUpdateEncoder()

    var encoding: StateUpdateEncoding { inner.encoding }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID) throws -> Data {
        try encode(update: update, landID: landID, playerID: playerID, playerSlot: nil)
    }

    func encode(update: StateUpdate, landID: String, playerID: PlayerID, playerSlot: Int32?) throws -> Data {
        if case .diff = update, failDiffs.isOn {
            throw SyncPhaseFault()
        }
        return try inner.encode(update: update, landID: landID, playerID: playerID, playerSlot: playerSlot)
    }
}

// MARK: - Client-side model

/// The client's view of `SyncPhaseTestState` for one player, rebuilt from received patches.
private struct SyncPhaseClientView: Equatable, CustomStringConvertible {
    var a = 0
    var b = 0
    var score: Int?
    var bonus: Int?

    init() {}

    init(server state: SyncPhaseTestState, player: PlayerID) {
        a = state.a
        b = state.b
        score = state.scores[player]
        bonus = state.bonuses[player]
    }

    var description: String {
        "a=\(a) b=\(b) score=\(score.map { String($0) } ?? "nil") bonus=\(bonus.map { String($0) } ?? "nil")"
    }

    mutating func apply(_ updates: [StateUpdate], player: PlayerID) {
        for update in updates {
            switch update {
            case .noChange:
                continue
            case .firstSync(let patches), .diff(let patches):
                for patch in patches {
                    apply(patch, player: player)
                }
            }
        }
    }

    private mutating func apply(_ patch: StatePatch, player: PlayerID) {
        let value: SnapshotValue?
        switch patch.operation {
        case .set(let v), .add(let v): value = v
        case .delete: value = nil
        }
        switch patch.path {
        case "/a": a = value.flatMap(Self.int) ?? 0
        case "/b": b = value.flatMap(Self.int) ?? 0
        case "/scores/\(player.rawValue)": score = value.flatMap(Self.int)
        case "/scores": score = value?.objectValue?[player.rawValue].flatMap(Self.int)
        case "/bonuses/\(player.rawValue)": bonus = value.flatMap(Self.int)
        case "/bonuses": bonus = value?.objectValue?[player.rawValue].flatMap(Self.int)
        default: break
        }
    }

    private static func int(_ value: SnapshotValue) -> Int? {
        switch value {
        case .int(let v): return v
        case .double(let v): return Int(v)
        default: return nil
        }
    }
}

// MARK: - Fixture

private func makeSyncPhaseEnvConfig(useSnapshotForSync: Bool) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: true,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: false,
        autoDirtyOffThreshold: 0.55,
        autoDirtyOnThreshold: 0.30,
        autoDirtyRequiredConsecutiveSamples: 30,
        profilingConfig: nil
    )
}

private struct SyncPhaseFixture {
    let keeper: LandKeeper<SyncPhaseTestState>
    let adapter: TransportAdapter<SyncPhaseTestState>
    let transport: SyncPhaseTransport
    /// JSON runs only: while on, the encoder fails every `.diff` update.
    let diffEncodingFails: SyncPhaseSwitch
    let session = SessionID("sp-session")
    let client = ClientID("sp-client")
    let player = PlayerID("sp-player")

    /// - Parameters:
    ///   - messagepack: opcode 107 (events queued for the next cycle); otherwise JSON with the
    ///     failing-on-demand encoder.
    ///   - join: run the join (and its firstSync) before returning.
    static func make(
        useSnapshotForSync: Bool = true,
        messagepack: Bool = false,
        join: Bool = true
    ) async throws -> SyncPhaseFixture {
        let transport = SyncPhaseTransport()
        let keeper = LandKeeper<SyncPhaseTestState>(
            definition: makeSyncPhaseLand(),
            initialState: SyncPhaseTestState()
        )
        let failDiffs = SyncPhaseSwitch()
        let adapter: TransportAdapter<SyncPhaseTestState>
        if messagepack {
            adapter = TransportAdapter<SyncPhaseTestState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-phase-test",
                transportEnvConfig: makeSyncPhaseEnvConfig(useSnapshotForSync: useSnapshotForSync),
                encodingConfig: .messagepack
            )
        } else {
            adapter = TransportAdapter<SyncPhaseTestState>(
                keeper: keeper,
                transport: transport,
                landID: "sync-phase-test",
                transportEnvConfig: makeSyncPhaseEnvConfig(useSnapshotForSync: useSnapshotForSync),
                stateUpdateEncoder: FailingDiffEncoder(failDiffs: failDiffs)
            )
        }
        await transport.setDelegate(adapter)
        let fixture = SyncPhaseFixture(keeper: keeper, adapter: adapter, transport: transport, diffEncodingFails: failDiffs)
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        if join {
            try await fixture.join()
        }
        return fixture
    }

    func join() async throws {
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: session,
            clientID: client,
            playerID: player
        )
    }

    func set(_ field: String, _ value: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: SyncPhaseSetAction.self),
            payload: AnyCodable(SyncPhaseSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: player,
            clientID: client,
            sessionID: session
        )
    }

    func sync() async {
        await adapter.syncNow()
        #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")
    }

    /// Makes the next plan (any kind) throw at its end; later plans run normally.
    func failNextPlan() async {
        let fired = SyncPhaseSwitch()
        await adapter.setSyncPlanFaultForTesting {
            guard !fired.isOn else { return }
            fired.set(true)
            throw SyncPhaseFault()
        }
    }

    func frameCount() async -> Int {
        await transport.messages(for: session).count
    }

    /// JSON runs: the client view rebuilt from every state update this session received.
    func clientView() async -> SyncPhaseClientView {
        var view = SyncPhaseClientView()
        view.apply(decodeStateUpdates(await transport.messages(for: session)), player: player)
        return view
    }

    func serverView() async -> SyncPhaseClientView {
        SyncPhaseClientView(server: await keeper.currentState(), player: player)
    }

    func queueEvent(_ message: String, to target: SwiftStateTree.EventTarget) async {
        await adapter.sendEvent(AnyServerEvent(SyncPhaseEvent(message: message)), to: target)
    }
}

private func count(_ message: String, in frames: [Data]) -> Int {
    let marker = Data(message.utf8)
    return frames.filter { $0.range(of: marker) != nil }.count
}

// MARK: - Tests

@Suite("TransportAdapter sync phase: plan + commit", .timeLimit(.minutes(1)))
struct TransportAdapterSyncPhaseTests {

    @Test("a plan that throws after the dirty flags were cleared: the next cycle delivers the change", arguments: [true, false])
    func throwingPlanAfterClearIsRecoveredNextCycle(useSnapshotForSync: Bool) async throws {
        let f = try await SyncPhaseFixture.make(useSnapshotForSync: useSnapshotForSync)
        await f.sync()

        try await f.set("a", 1)
        try await f.set("score", 5)
        let framesBefore = await f.frameCount()
        await f.failNextPlan()
        await f.sync()
        #expect(await f.frameCount() == framesBefore, "a failed plan enqueues nothing")
        #expect(await f.keeper.currentState().isDirty() == false, "precondition: beginSync cleared the dirty flags")
        #expect(await f.adapter.isSyncRecoveryPending(), "a failed plan requests a recovery cycle")

        // Another field of each category is dirty, so the next cycle is a dirty-tracking cycle,
        // not an `.all` fallback that would repair the loss on its own.
        try await f.set("b", 2)
        try await f.set("bonus", 3)
        await f.sync()

        let client = await f.clientView()
        let server = await f.serverView()
        #expect(client.a == 1, "broadcast change of the failed cycle must arrive; client \(client)")
        #expect(client.score == 5, "per-player change of the failed cycle must arrive; client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
        #expect(await f.adapter.isSyncRecoveryPending() == false, "the recovery cycle's commit ends the recovery")
    }

    @Test("a failed broadcast-only plan is recovered by the next full cycle")
    func throwingBroadcastOnlyPlanIsRecovered() async throws {
        let f = try await SyncPhaseFixture.make()
        await f.sync()

        try await f.set("a", 4)
        await f.failNextPlan()
        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain(), "outbound writer did not drain")
        #expect(await f.adapter.isSyncRecoveryPending())

        try await f.set("b", 1)
        await f.sync()

        let client = await f.clientView()
        let server = await f.serverView()
        #expect(client.a == 4, "client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("a per-player encode failure requests recovery; the next cycle delivers the change")
    func perPlayerEncodeFailureIsRecovered() async throws {
        let f = try await SyncPhaseFixture.make(useSnapshotForSync: false)
        await f.sync()

        try await f.set("score", 7)
        f.diffEncodingFails.set(true)
        await f.sync()
        f.diffEncodingFails.set(false)
        #expect(await f.adapter.isSyncRecoveryPending(), "an encode failure requests a recovery cycle")

        try await f.set("bonus", 1)
        await f.sync()

        let client = await f.clientView()
        let server = await f.serverView()
        #expect(client.score == 7, "client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
        #expect(await f.adapter.isSyncRecoveryPending() == false)
    }

    @Test("a failed firstSync plan: the next cycle gives the joiner its full view")
    func throwingFirstSyncPlanIsRecovered() async throws {
        let f = try await SyncPhaseFixture.make(join: false)
        await f.failNextPlan()
        try await f.join()
        #expect(await f.frameCount() == 0, "the failed firstSync enqueues nothing")

        try await f.set("a", 2)
        await f.sync()

        let updates = decodeStateUpdates(await f.transport.messages(for: f.session))
        if case .firstSync = updates.first {} else {
            Issue.record("the joiner's first state update must be a firstSync, got \(String(describing: updates.first))")
        }
        let client = await f.clientView()
        let server = await f.serverView()
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("a failed plan keeps queued events; the next cycle delivers each once (opcode 107)")
    func throwingPlanKeepsQueuedEvents() async throws {
        let f = try await SyncPhaseFixture.make(messagepack: true)
        await f.sync()

        try await f.set("a", 1)
        await f.queueEvent("bc-kept", to: .all)
        await f.queueEvent("tg-kept", to: .player(f.player))
        let before = await f.adapter.pendingEventCounts()
        #expect(before.targeted == 1 && before.broadcast == 1, "precondition: both events queued")
        await f.failNextPlan()
        await f.sync()
        let after = await f.adapter.pendingEventCounts()
        #expect(after.targeted == 1 && after.broadcast == 1, "a failed plan removes no event")

        await f.sync()
        let frames = await f.transport.messages(for: f.session)
        #expect(count("bc-kept", in: frames) == 1, "broadcast event exactly once")
        #expect(count("tg-kept", in: frames) == 1, "targeted event exactly once")
        let drained = await f.adapter.pendingEventCounts()
        #expect(drained.targeted == 0 && drained.broadcast == 0)
    }

    @Test("per session: merged frame, then targeted event frames, then the per-player frame (opcode 107)")
    func frameOrderWithinACycle() async throws {
        let f = try await SyncPhaseFixture.make(messagepack: true)
        await f.sync()
        let start = await f.frameCount()

        try await f.set("a", 1)
        try await f.set("score", 2)
        await f.queueEvent("tg-order", to: .player(f.player))
        await f.sync()

        let frames = Array(await f.transport.messages(for: f.session).dropFirst(start))
        let kinds: [Int64] = frames.compactMap { frame in
            guard let unpacked = try? unpack(frame),
                  case .array(let array) = unpacked,
                  case .int(let opcode) = array.first else { return nil }
            return opcode
        }
        // 107 merged broadcast, 103 targeted event, 0...2 per-player state update.
        #expect(kinds.count == 3, "frames: \(kinds)")
        #expect(kinds.first == 107, "frames: \(kinds)")
        #expect(kinds.dropFirst().first == 103, "frames: \(kinds)")
        #expect(kinds.last.map { (0...2).contains($0) } == true, "frames: \(kinds)")
    }
}
