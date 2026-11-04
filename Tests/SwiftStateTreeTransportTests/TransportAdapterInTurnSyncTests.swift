// Tests/SwiftStateTreeTransportTests/TransportAdapterInTurnSyncTests.swift
//
// Layer-3 spike: the sync phase runs inside the keeper's tick turn. The adapter shares the
// keeper's executor; the keeper calls `runSyncPhaseInTurn` synchronously after the tick handler,
// so inputs, tick, events, sync plan + commit and the writer enqueue form one actor turn.
//
// The reentrancy probe enqueues jobs on the shared executor while the turn runs (one on the
// keeper, one on the adapter) and records the order: if the turn had a suspension point anywhere
// between its start and its commit, a job could run inside it.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct InTurnSyncTestState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    init() {}
}

@Payload
struct InTurnSyncEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

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

/// Each tick increments `ticks`, emits a broadcast event and requests a sync, so every tick turn
/// includes the sync phase.
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
        Rules {}
    }
}

private struct InTurnSyncFixture {
    let keeper: LandKeeper<InTurnSyncTestState>
    let adapter: TransportAdapter<InTurnSyncTestState>
    let transport: InTurnSyncTransport
    let session = SessionID("its-session")

    static func make(encodingConfig: TransportEncodingConfig) async throws -> InTurnSyncFixture {
        let transport = InTurnSyncTransport()
        let keeper = LandKeeper<InTurnSyncTestState>(
            definition: makeInTurnSyncLand(),
            initialState: InTurnSyncTestState(),
            autoStartLoops: false
        )
        let adapter = TransportAdapter<InTurnSyncTestState>(
            keeper: keeper,
            transport: transport,
            landID: "in-turn-sync-test",
            encodingConfig: encodingConfig
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)
        let fixture = InTurnSyncFixture(keeper: keeper, adapter: adapter, transport: transport)
        await adapter.onConnect(sessionID: fixture.session, clientID: ClientID("its-client"))
        try await simulateRouterJoin(
            adapter: adapter,
            keeper: keeper,
            sessionID: fixture.session,
            clientID: ClientID("its-client"),
            playerID: PlayerID("its-player")
        )
        #expect(await adapter.waitForOutboundDrain())
        return fixture
    }
}

private func contains(_ marker: String, _ frame: Data) -> Bool {
    frame.range(of: Data(marker.utf8)) != nil
}

@Suite("Layer-3 spike: sync inside the keeper turn", .timeLimit(.minutes(1)))
struct TransportAdapterInTurnSyncTests {

    @Test("the adapter runs on the keeper's executor")
    func adapterSharesKeeperExecutor() async throws {
        let f = try await InTurnSyncFixture.make(encodingConfig: .json)
        #expect(f.adapter.runsSyncPhaseOnKeeperExecutor)
        // `runSyncPhaseInTurn` enters the adapter with `assumeIsolated`, which traps unless the
        // keeper's executor is the adapter's: a tick turn with sync proves they are shared.
        await f.keeper.stepTickOnce()
        #expect(await f.adapter.syncFailedPlans == 0)
    }

    @Test("reentrancy probe: jobs enqueued on the shared executor during the turn run after its commit")
    func jobsEnqueuedDuringTheTurnRunAfterCommit() async throws {
        let f = try await InTurnSyncFixture.make(encodingConfig: .messagepack)
        let log = InTurnProbeLog()
        let keeper = f.keeper
        let adapter = f.adapter
        let spawned = InTurnProbeLog()
        await keeper.setInTurnProbeForTesting { label in
            log.append(label)
            guard label == "turn-begin", spawned.snapshot.isEmpty else { return }
            spawned.append("spawned")
            // Jobs on the shared executor, enqueued while the turn runs.
            Task { await keeper.recordInTurnProbeForTesting("keeper-job") }
            Task {
                _ = await adapter.pendingEventCounts()
                log.append("adapter-job")
            }
        }

        await keeper.stepTickOnce()
        for _ in 0..<100 where !(log.snapshot.contains("keeper-job") && log.snapshot.contains("adapter-job")) {
            try await safeTaskSleep(for: .milliseconds(10))
        }
        let order = log.snapshot
        #expect(Array(order.prefix(3)) == ["turn-begin", "sync-committed", "turn-end"], "order: \(order)")
        #expect(Set(order.dropFirst(3)) == ["keeper-job", "adapter-job"], "both jobs ran after the turn: \(order)")
    }

    @Test(
        "json / opcodeJsonArray: the tick's events reach the writer in emit order, before its state frame",
        arguments: [TransportEncodingConfig.json, .jsonOpcode]
    )
    func eventsPrecedeTheTurnStateFrame(encodingConfig: TransportEncodingConfig) async throws {
        let f = try await InTurnSyncFixture.make(encodingConfig: encodingConfig)
        let before = await f.transport.messages(for: f.session).count

        await f.keeper.stepTickOnce()
        #expect(await f.adapter.waitForOutboundDrain())

        let frames = Array(await f.transport.messages(for: f.session).dropFirst(before))
        #expect(frames.count == 2, "one event frame, one state frame: \(frames.count)")
        #expect(frames.first.map { contains("tick-event-1", $0) } == true, "the event comes first")
        #expect(frames.last.map { contains("tick-event-1", $0) } == false, "then the state frame")
        #expect(await f.adapter.syncFailedPlans == 0)
    }

    @Test("opcode 107: the tick's event rides in the merged frame of the same turn")
    func eventMergedIntoTheTurnFrame() async throws {
        let f = try await InTurnSyncFixture.make(encodingConfig: .messagepack)
        let before = await f.transport.messages(for: f.session).count

        await f.keeper.stepTickOnce()
        #expect(await f.adapter.waitForOutboundDrain())

        let frames = Array(await f.transport.messages(for: f.session).dropFirst(before))
        #expect(frames.contains { contains("tick-event-1", $0) }, "the event is sent in this turn")
        let counts = await f.adapter.pendingEventCounts()
        #expect(counts.targeted == 0 && counts.broadcast == 0, "consumed by the turn's commit")
    }

    @Test("the turn's commit clears the dirty flags in the same turn")
    func commitClearsDirtyFlags() async throws {
        let f = try await InTurnSyncFixture.make(encodingConfig: .json)
        await f.keeper.stepTickOnce()
        #expect(await f.keeper.currentState().isDirty() == false)
    }
}
