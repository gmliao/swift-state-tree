// Tests/SwiftStateTreeTransportTests/TransportAdapterSyncDirtyWindowTests.swift
//
// Regression tests for #68: a sync cycle must not clear dirty flags of mutations that happen
// after it took its state copy. `LandKeeper.beginSync()` returns a copy of the state; the cycle
// then awaits (encoding, sends, actor hops), and the keeper can run actions or ticks in that
// window. Those mutations are not in the copy, so their dirty flags must survive the cycle;
// otherwise the next dirty-tracking cycle skips them and clients keep the stale value.
//
// The window is injected deterministically, never raced:
// - keeper-level: call `keeper.beginSync()` directly, mutate, then `keeper.endSync()`;
// - adapter-level: a transport whose `sendBatch` suspends until the test releases it.
//
// Every scenario dirties one more field of the same policy category before the checked cycle.
// A cycle with nothing dirty falls back to `.all`, which would repair the lost update and hide it.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test state and action

@StateNodeBuilder
struct DirtyWindowTestState: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: Int = 0
    @Sync(.perPlayerSlice()) var scores: [PlayerID: Int] = [:]
    init() {}
}

@Payload
struct DirtyWindowSetAction: ActionPayload {
    typealias Response = DirtyWindowSetResponse
    /// "a", "b" or "score" (the calling player's `scores` entry).
    let field: String
    let value: Int
}

@Payload
struct DirtyWindowSetResponse: ResponsePayload {
    let ok: Bool
}

private func makeDirtyWindowLand() -> LandDefinition<DirtyWindowTestState> {
    Land("dirty-window-test", using: DirtyWindowTestState.self) {
        Rules {
            OnJoin { (state: inout DirtyWindowTestState, ctx: LandContext) in
                state.scores[ctx.playerID] = 0
            }
            HandleAction(DirtyWindowSetAction.self) { (state: inout DirtyWindowTestState, action: DirtyWindowSetAction, ctx: LandContext) in
                switch action.field {
                case "a": state.a = action.value
                case "b": state.b = action.value
                default: state.scores[ctx.playerID] = action.value
                }
                return DirtyWindowSetResponse(ok: true)
            }
        }
    }
}

// MARK: - Transport that can hold a sync cycle in flight

/// Records every send. When armed with `holdNextBatch()`, the next `sendBatch` records its
/// frames and then suspends until `release()`, keeping the adapter's sync cycle in flight.
private actor DirtyWindowTransport: Transport {
    var delegate: TransportDelegate?
    private var sent: [(target: SwiftStateTreeTransport.EventTarget, data: Data)] = []
    private var shouldHoldNextBatch = false
    private var heldBatch: CheckedContinuation<Void, Never>?
    private var holdWaiter: CheckedContinuation<Void, Never>?

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
        guard shouldHoldNextBatch else { return }
        shouldHoldNextBatch = false
        await withCheckedContinuation { continuation in
            heldBatch = continuation
            holdWaiter?.resume()
            holdWaiter = nil
        }
    }

    func holdNextBatch() { shouldHoldNextBatch = true }

    /// Returns once a `sendBatch` call is suspended.
    func waitUntilHeld() async {
        if heldBatch != nil { return }
        await withCheckedContinuation { continuation in
            holdWaiter = continuation
        }
    }

    func release() {
        heldBatch?.resume()
        heldBatch = nil
    }

    func messages(for sessionID: SessionID) -> [Data] {
        sent.compactMap { entry in
            if case .session(let id) = entry.target, id == sessionID { return entry.data }
            return nil
        }
    }
}

// MARK: - Client-side model

/// The client's view of `DirtyWindowTestState` for one player, rebuilt from received patches.
private struct DirtyWindowClientView: Equatable, CustomStringConvertible {
    var a: Int
    var b: Int
    var score: Int?

    init(a: Int, b: Int, score: Int?) {
        self.a = a
        self.b = b
        self.score = score
    }

    /// The projection the server state implies for `player`.
    init(server state: DirtyWindowTestState, player: PlayerID) {
        self.init(a: state.a, b: state.b, score: state.scores[player])
    }

    var description: String { "a=\(a) b=\(b) score=\(score.map { String($0) } ?? "nil")" }

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

private struct DirtyWindowFixture {
    let keeper: LandKeeper<DirtyWindowTestState>
    let adapter: TransportAdapter<DirtyWindowTestState>
    let transport: DirtyWindowTransport
    let session = SessionID("dw-session")
    let client = ClientID("dw-client")
    let player = PlayerID("dw-player")

    /// - Parameter envConfig: `nil` uses the adapter's default configuration (env lookup).
    static func make(envConfig: TransportEnvConfig?) async throws -> DirtyWindowFixture {
        let transport = DirtyWindowTransport()
        let keeper = LandKeeper<DirtyWindowTestState>(
            definition: makeDirtyWindowLand(),
            initialState: DirtyWindowTestState()
        )
        let adapter = TransportAdapter<DirtyWindowTestState>(
            keeper: keeper,
            transport: transport,
            landID: "dirty-window-test",
            transportEnvConfig: envConfig
        )
        await transport.setDelegate(adapter)
        let fixture = DirtyWindowFixture(keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: fixture.session, clientID: fixture.client)
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: fixture.client,
            playerID: fixture.player
        )
        try await Task.sleep(for: .milliseconds(100))
        return fixture
    }

    func set(_ field: String, _ value: Int) async throws {
        let envelope = ActionEnvelope(
            typeIdentifier: String(describing: DirtyWindowSetAction.self),
            payload: AnyCodable(DirtyWindowSetAction(field: field, value: value))
        )
        _ = try await keeper.handleActionEnvelope(
            envelope,
            playerID: player,
            clientID: client,
            sessionID: session
        )
    }

    /// The client view right after the join: initial state plus the OnJoin score entry.
    var initialView: DirtyWindowClientView {
        DirtyWindowClientView(a: 0, b: 0, score: 0)
    }

    /// Client view rebuilt from every state update this session received after the join.
    func clientView(from start: DirtyWindowClientView) async -> DirtyWindowClientView {
        var view = start
        view.apply(decodeStateUpdates(await transport.messages(for: session)), player: player)
        return view
    }

    func serverView() async -> DirtyWindowClientView {
        DirtyWindowClientView(server: await keeper.currentState(), player: player)
    }

    /// Runs one `syncNow` cycle and, while it is suspended in `sendBatch`, runs `duringCycle`.
    /// The cycle must have something to send, or it never reaches `sendBatch`.
    func syncNowHoldingSend(duringCycle: () async throws -> Void) async throws {
        let adapter = self.adapter
        await transport.holdNextBatch()
        let cycle = Task { await adapter.syncNow() }
        await transport.waitUntilHeld()
        try await duringCycle()
        await transport.release()
        await cycle.value
    }
}

private func makeDirtyWindowEnvConfig(
    useSnapshotForSync: Bool,
    enableDirtyTracking: Bool = true,
    enableAutoDirtyTracking: Bool = false,
    autoDirtyOffThreshold: Double = 0.55,
    autoDirtyOnThreshold: Double = 0.30,
    autoDirtyRequiredConsecutiveSamples: Int = 30
) -> TransportEnvConfig {
    TransportEnvConfig(
        enableDirtyTracking: enableDirtyTracking,
        useSnapshotForSync: useSnapshotForSync,
        syncStrategy: .delta,
        enableChangeObjectMetrics: false,
        changeObjectMetricsLogEvery: 10,
        changeObjectMetricsEmaAlpha: 0.2,
        enableAutoDirtyTracking: enableAutoDirtyTracking,
        autoDirtyOffThreshold: autoDirtyOffThreshold,
        autoDirtyOnThreshold: autoDirtyOnThreshold,
        autoDirtyRequiredConsecutiveSamples: autoDirtyRequiredConsecutiveSamples,
        profilingConfig: nil
    )
}

// MARK: - Tests

@Suite("TransportAdapter sync dirty-flag window (#68)", .timeLimit(.minutes(1)))
struct TransportAdapterSyncDirtyWindowTests {

    @Test("a mutation after beginSync is sent by the next dirty-tracking sync", arguments: [true, false])
    func mutationInsideKeeperWindowIsSentNextCycle(useSnapshotForSync: Bool) async throws {
        let f = try await DirtyWindowFixture.make(envConfig: makeDirtyWindowEnvConfig(useSnapshotForSync: useSnapshotForSync))
        await f.adapter.syncNow()

        // A sync cycle has taken its copy; the keeper mutates `a` before the cycle ends.
        guard await f.keeper.beginSync() != nil else {
            Issue.record("beginSync rejected with no cycle in flight")
            return
        }
        try await f.set("a", 1)
        await f.keeper.endSync()

        // Next cycle: `b` (same broadcast category) is dirty too, so no `.all` fallback.
        try await f.set("b", 2)
        await f.adapter.syncNow()

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("a broadcast-only sync does not drop pending per-player changes")
    func broadcastOnlySyncKeepsPerPlayerDirtyFlags() async throws {
        // Default adapter configuration (no env config override).
        let f = try await DirtyWindowFixture.make(envConfig: nil)
        await f.adapter.syncNow()

        try await f.set("score", 5)
        await f.adapter.syncBroadcastOnly()

        // A broadcast field is dirty in the next cycle, so it is not an `.all` cycle.
        try await f.set("a", 1)
        await f.adapter.syncNow()

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client.score == 5, "per-player change must reach the client; client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("dirty tracking switching off->on at the end of a cycle loses no in-cycle mutation")
    func autoSwitchOnDoesNotClearInCycleMutations() async throws {
        // Dirty tracking starts off; the auto-switch turns it on after the first sampled cycle.
        // Thresholds outside [0, 1] make the switch unconditional on the first sample.
        let f = try await DirtyWindowFixture.make(envConfig: makeDirtyWindowEnvConfig(
            useSnapshotForSync: true,
            enableDirtyTracking: false,
            enableAutoDirtyTracking: true,
            autoDirtyOffThreshold: 20,
            autoDirtyOnThreshold: 10,
            autoDirtyRequiredConsecutiveSamples: 1
        ))
        #expect(await f.adapter.isDirtyTrackingEnabled() == false)

        try await f.set("b", 1)  // something for the held cycle to send
        try await f.syncNowHoldingSend {
            try await f.set("a", 7)
        }
        #expect(await f.adapter.isDirtyTrackingEnabled() == true, "precondition: the cycle switched dirty tracking on")

        try await f.set("b", 2)
        await f.adapter.syncNow()

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client.a == 7, "mutation during the switching cycle must be sent; client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("a sync request rejected while a cycle is in flight loses no mutation")
    func rejectedSyncRequestLosesNoMutation() async throws {
        let f = try await DirtyWindowFixture.make(envConfig: makeDirtyWindowEnvConfig(useSnapshotForSync: true))
        await f.adapter.syncNow()

        try await f.set("a", 1)  // something for the held cycle to send
        try await f.syncNowHoldingSend {
            try await f.set("b", 2)
            // Rejected: the held cycle still owns the sync flag.
            #expect(await f.keeper.beginSync() == nil)
            await f.adapter.syncNow()
        }

        try await f.set("a", 3)
        await f.adapter.syncNow()

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client.b == 2, "mutation during the in-flight cycle must be sent; client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
    }

    @Test("mutations during an in-flight adapter cycle reach the client next cycle", arguments: [true, false])
    func inFlightCycleMutationsReachClient(useSnapshotForSync: Bool) async throws {
        let f = try await DirtyWindowFixture.make(envConfig: makeDirtyWindowEnvConfig(useSnapshotForSync: useSnapshotForSync))
        await f.adapter.syncNow()

        try await f.set("a", 1)  // something for the held cycle to send
        try await f.syncNowHoldingSend {
            try await f.set("b", 4)
            try await f.set("score", 9)
        }

        // `a` (same broadcast category as `b`) is dirty in the next cycle, so it is not an `.all` cycle.
        try await f.set("a", 2)
        await f.adapter.syncNow()

        let client = await f.clientView(from: f.initialView)
        let server = await f.serverView()
        #expect(client.b == 4, "broadcast mutation during the cycle must be sent; client \(client)")
        #expect(client.score == 9, "per-player mutation during the cycle must be sent; client \(client)")
        #expect(client == server, "client \(client) must equal server \(server)")
    }
}
