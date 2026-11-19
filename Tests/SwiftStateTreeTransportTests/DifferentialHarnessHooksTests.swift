// Tests/SwiftStateTreeTransportTests/DifferentialHarnessHooksTests.swift
//
// The hooks the differential harness (#555) needs, each on its own: stable client IDs per
// connection attempt, the router's pending-flip report and its land-stop leave hold, a
// cancellable action-response waiter, an explicit "no flip timeout", and the record decoder
// entry. Orders are forced with hold points, never timing.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

@StateNodeBuilder
struct HarnessHooksState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [String] = []
    @Sync(.broadcast)
    var leaves: [String] = []
}

private func makeHooksLand() -> LandDefinition<HarnessHooksState> {
    Land("harness-hooks", using: HarnessHooksState.self) {
        Rules {
            OnJoin { (state: inout HarnessHooksState, ctx: LandContext) in
                state.players.append(ctx.playerID.rawValue)
            }
            OnLeave { (state: inout HarnessHooksState, ctx: LandContext) in
                state.players.removeAll { $0 == ctx.playerID.rawValue }
                state.leaves.append(ctx.playerID.rawValue)
            }
        }
    }
}

/// Router, manager and one land, as `NIOLandServer` assembles them, over a real transport.
private struct HooksHarness {
    let transport: WebSocketTransport
    let router: LandRouter<HarnessHooksState>
    let container: LandContainer<HarnessHooksState>

    var adapter: TransportAdapter<HarnessHooksState> { container.transportAdapter }
    var keeper: LandKeeper<HarnessHooksState> { container.keeper }

    static func make(autoStartLoops: Bool = true) async throws -> HooksHarness {
        let definition = makeHooksLand()
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry(
            landFactory: { _, _ in definition },
            initialStateFactory: { _, _ in HarnessHooksState() }
        )
        let manager = LandManager<HarnessHooksState>(
            landFactory: { _ in definition },
            initialStateFactory: { _ in HarnessHooksState() },
            transport: transport,
            syncLagPolicy: nil,
            autoStartLoops: autoStartLoops
        )
        let router = LandRouter<HarnessHooksState>(
            landManager: manager,
            landTypeRegistry: registry,
            transport: transport,
            allowAutoCreateOnJoin: true
        )
        await transport.setDelegate(router)
        let landID = LandID(landType: "harness-hooks", instanceId: "one")
        let container = try await manager.getOrCreateLand(
            landID: landID, definition: definition, initialState: HarnessHooksState(), metadata: [:]
        )
        return HooksHarness(transport: transport, router: router, container: container)
    }

    func connect(_ session: SessionID) async -> RecordingConnection {
        let connection = RecordingConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        return connection
    }

    func join(_ session: SessionID, player: String) async throws {
        let frame = try JSONEncoder().encode(TransportMessage.join(
            requestID: "join-\(player)", landType: "harness-hooks", landInstanceId: "one",
            playerID: player, deviceID: nil, metadata: nil
        ))
        await router.onMessage(frame, from: session)
    }
}

/// Records the client ID each connection was given.
private actor ClientIDRecorder: TransportDelegate {
    private(set) var clientIDs: [ClientID] = []
    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        clientIDs.append(clientID)
    }
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {}
    func onMessage(_ message: Data, from sessionID: SessionID) async {}
}

/// `body`, or false when it doesn't return within the hang bound.
private func bounded(_ body: @escaping @Sendable () async -> Void) async -> Bool {
    switch await raceDeadline(testHangBound, body) {
    case .finished: return true
    case .timedOut: return false
    }
}

@Suite("Differential harness hooks (#555)")
struct DifferentialHarnessHooksTests {
    // MARK: Client IDs

    @Test("The client-ID supplier names each connection attempt, a reused SessionID included")
    func clientIDPerAttempt() async throws {
        let transport = WebSocketTransport()
        let recorder = ClientIDRecorder()
        await transport.setDelegate(recorder)
        await transport.setClientIDSupplierForTesting { ClientID("conn-\($0)") }
        let a = SessionID("a"), b = SessionID("b")
        await transport.handleConnection(sessionID: a, connection: RecordingConnection())
        await transport.handleConnection(sessionID: b, connection: RecordingConnection())
        await transport.handleDisconnection(sessionID: a)
        await transport.handleConnection(sessionID: a, connection: RecordingConnection())
        #expect(await recorder.clientIDs == [ClientID("conn-1"), ClientID("conn-2"), ClientID("conn-3")])

        // Without it, the random six-character default.
        await transport.setClientIDSupplierForTesting(nil)
        await transport.handleConnection(sessionID: SessionID("c"), connection: RecordingConnection())
        let last = try #require(await recorder.clientIDs.last)
        #expect(last.rawValue.count == 6 && !last.rawValue.hasPrefix("conn-"))
    }

    // MARK: Pending flips

    @Test("No pending flip: returns at once with none, and not before an in-turn join's flip wait ends")
    func noPendingFlip() async throws {
        let h = try await HooksHarness.make()
        #expect(await bounded { await h.router.waitForNoPendingFlipForTesting() }, "none pending: returns at once")
        guard h.adapter.inTurnSyncEnabled else { return }  // only an in-turn join has a flip wait

        let flipped = TestGate()
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.flipWaitResumed, arrival: 1) {
            await flipped.arrive()
        }.hook)
        let session = SessionID("s1")
        let connection = await h.connect(session)
        try await h.join(session, player: "p1")
        #expect(await flipped.waitForArrivals(1), "the flip wait resumed and is held")

        // Held inside `awaitFlip`: its wait is still counted, so the waiter below registers and
        // can't return before the gate opens.
        #expect(await h.router.pendingFlipWaitCountForTesting() == 1)
        let registered = TestGate()
        let ended = Task { await h.router.waitForNoPendingFlipForTesting { await registered.arrive() } }
        #expect(await registered.waitForArrivals(1), "the waiter registered while the flip wait is held")
        registered.open()
        flipped.open()
        #expect(await bounded { await ended.value }, "returns once the flip wait ended")
        #expect(await h.router.pendingFlipWaitCountForTesting() == 0)
        #expect(await connection.waitUntilFrames { $0.contains { $0.kind == .joinResponse } })
    }

    @Test("The no-pending-flip waiter returns when its task is cancelled, registered or not yet")
    func noPendingFlipWaiterIsCancellable() async throws {
        let h = try await HooksHarness.make()
        guard h.adapter.inTurnSyncEnabled else { return }  // only an in-turn join has a flip wait
        let flipped = TestGate()
        await h.router.installHolds(HoldRegistry<LandRouterHoldPoint>().on(.flipWaitResumed, arrival: 1) {
            await flipped.arrive()
        }.hook)
        let session = SessionID("s1")
        _ = await h.connect(session)
        try await h.join(session, player: "p1")
        #expect(await flipped.waitForArrivals(1), "the flip wait is held, so a waiter must register")

        // Cancelled after it registered: the cancellation handler removes and resumes it.
        let registered = TestGate()
        let waiter = Task { await h.router.waitForNoPendingFlipForTesting { await registered.arrive() } }
        #expect(await registered.waitForArrivals(1))
        registered.open()
        waiter.cancel()
        #expect(await bounded { await waiter.value }, "the registered waiter returned on cancellation")

        // Cancelled before it registered: it returns without being stored.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await h.router.waitForNoPendingFlipForTesting { Issue.record("a cancelled waiter registered") }
        }
        #expect(await bounded { await early.value }, "the waiter cancelled first returned")
        flipped.open()
        #expect(await bounded { await h.router.waitForNoPendingFlipForTesting() })
    }

    // MARK: Land-stop leaves

    @Test("A land stop's leaves stop at stopLeave(session) before they reach the membership queue, so a test orders them")
    func stopLeaveOrdersTheLeaves() async throws {
        let h = try await HooksHarness.make()
        let a = SessionID("a"), b = SessionID("b")
        let connectionA = await h.connect(a), connectionB = await h.connect(b)
        try await h.join(a, player: "pa")
        try await h.join(b, player: "pb")
        let syncedA = await connectionA.waitForFirstSync(), syncedB = await connectionB.waitForFirstSync()
        #expect(syncedA && syncedB)
        // Each first sync follows its OnJoin.
        #expect(await h.keeper.currentState().players.sorted() == ["pa", "pb"])

        let gateA = TestGate(), gateB = TestGate()
        await h.router.installHolds(
            HoldRegistry<LandRouterHoldPoint>()
                .on(.stopLeave(a), arrival: 1) { await gateA.arrive() }
                .on(.stopLeave(b), arrival: 1) { await gateB.arrive() }
                .hook
        )
        let queued = TestGate()
        let stop = Task {
            await h.router.closeSessions(boundTo: h.container.epoch) { SessionClose(code: 1001, reason: "stop") }
        }
        let heldA = await gateA.waitForArrivals(1), heldB = await gateB.waitForArrivals(1)
        #expect(heldA && heldB, "both leaves held before their onDisconnect")
        #expect(await h.keeper.currentState().leaves.isEmpty, "no leave ran yet")

        // B first, then A: the forced order, against whatever order the task group started them.
        await h.adapter.installHolds(HoldRegistry<TransportAdapterHoldPoint>().on(.membershipQueued, arrival: 1) {
            await queued.arrive()
        }.hook)
        gateB.open()
        #expect(await queued.waitForArrivals(1), "B's leave is in the membership queue")
        queued.open()
        gateA.open()
        #expect(await bounded { await stop.value })
        #expect(await h.keeper.currentState().leaves == ["pb", "pa"])
        let codeA = await connectionA.closeCode, codeB = await connectionB.closeCode
        #expect(codeA == 1001 && codeB == 1001)
    }

    // MARK: Action-response waiter

    @Test("The action-response waiter returns when its task is cancelled, registered or not yet, for a count that never comes")
    func actionResponseWaiterIsCancellable() async throws {
        let h = try await HooksHarness.make()

        // Cancelled after it registered: the cancellation handler removes and resumes it.
        let registered = TestGate()
        let waiter = Task { await h.adapter.waitForActionResponsesFinishedForTesting(1) { await registered.arrive() } }
        #expect(await registered.waitForArrivals(1), "the waiter registered")
        registered.open()
        waiter.cancel()
        #expect(await bounded { await waiter.value }, "the registered waiter returned on cancellation")

        // Cancelled before it registered: it returns without being stored.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await h.adapter.waitForActionResponsesFinishedForTesting(1) { Issue.record("a cancelled waiter registered") }
        }
        #expect(await bounded { await early.value }, "the waiter cancelled first returned")
        // A cancelled waiter is gone: a later finish resumes nothing twice.
        #expect(await bounded { await h.adapter.waitForActionResponsesFinishedForTesting(0) })
    }

    // MARK: Flip timeout

    @Test("An explicit .zero flip timeout override means none; any other override, or none, gives a timeout")
    func zeroFlipTimeoutMeansNone() {
        typealias Adapter = TransportAdapter<HarnessHooksState>
        let now = ContinuousClock.now
        #expect(Adapter.joinFlipTimeout(override: .zero, deadline: now + .seconds(5)) == nil)
        #expect(Adapter.joinFlipTimeout(override: .zero, deadline: nil) == nil)
        #expect(Adapter.joinFlipTimeout(override: .milliseconds(30), deadline: now + .seconds(5)) == .milliseconds(30))
        // No override: what is left of the budget, and an expired budget times out at once.
        let left = Adapter.joinFlipTimeout(override: nil, deadline: now + .seconds(5))
        #expect(left.map { $0 > .zero && $0 <= .seconds(5) } == true)
        #expect(Adapter.joinFlipTimeout(override: nil, deadline: now - .seconds(1)) == .zero)
    }

    // MARK: Record decoder

    @Test("The record decoder entry reads a saved record's 3.x contents, complete")
    func recordDecoderEntry() async throws {
        let landID = "harness-hooks:record"
        let keeper = LandKeeper<HarnessHooksState>(
            definition: makeHooksLand(),
            initialState: HarnessHooksState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        await keeper.setLandID(landID)
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await recorder.setMetadata(ReevaluationRecordMetadata(
            landID: landID,
            landType: "harness-hooks",
            createdAt: Date(timeIntervalSince1970: 1_800_000_000),
            metadata: [:],
            landDefinitionID: "harness-hooks",
            rngSeed: DeterministicSeed.fromLandID(landID),
            recordsSyncStream: await keeper.recordsSyncStream,
            syncConfig: nil
        ))
        await keeper.waitForRecorderSubmissionsForTesting()

        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harness-hooks-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let path = directory.appendingPathComponent("record.sstr").path
        try await recorder.save(to: path)

        let contents = try ReevaluationRecordLog.decodeForTesting(Array(try Data(contentsOf: URL(fileURLWithPath: path))))
        #expect(contents.completeness == .complete)
        #expect(contents.metadata.landID == landID)
        #expect(contents.metadata.landDefinitionID == "harness-hooks")
    }
}
