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

@Payload
struct HooksPingAction: ActionPayload {
    typealias Response = HooksPingResponse
    let tag: String
}

@Payload
struct HooksPingResponse: ResponsePayload {
    let tag: String
}

struct HooksPingOutput: ResolverOutput {}

/// Returns at once; with it the ping is a pending job, answered by the adapter's response task.
struct HooksPingResolver: ContextResolver {
    typealias Output = HooksPingOutput
    static func resolve(ctx: ResolverContext) async throws -> HooksPingOutput { HooksPingOutput() }
}

private func makeHooksLand() -> LandDefinition<HarnessHooksState> {
    Land("harness-hooks", using: HarnessHooksState.self) {
        Rules {
            HandleAction(HooksPingAction.self, resolvers: HooksPingResolver.self) { (_: inout HarnessHooksState, action: HooksPingAction, _: LandContext) in
                HooksPingResponse(tag: action.tag)
            }
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

    /// A `HooksPingAction`, a pending job (it has a resolver): its answer finishing is one action
    /// response finished.
    func ping(_ session: SessionID, tag: String) async throws {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: HooksPingAction.self), payload: AnyCodable(HooksPingAction(tag: tag)))
        let frame = try JSONEncoder().encode(TransportMessage.action(requestID: "ping-\(tag)", action: envelope))
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

/// Entries in the order they were appended.
private actor OrderLog {
    private(set) var entries: [String] = []
    func append(_ entry: String) { entries.append(entry) }
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

    @Test("The action-response waiter returns on a real completion after it registered, and on cancellation, registered or not yet")
    func actionResponseWaiterIsCancellable() async throws {
        let h = try await HooksHarness.make()
        let session = SessionID("s1")
        let connection = await h.connect(session)
        try await h.join(session, player: "p1")
        #expect(await connection.waitForFirstSync())

        // Registered, then a real completion: the first action's response finishing resumes it.
        let registered = TestGate()
        let first = Task { await h.adapter.waitForActionResponsesFinishedForTesting(1) { await registered.arrive() } }
        #expect(await registered.waitForArrivals(1), "the waiter registered before the action")
        registered.open()
        try await h.ping(session, tag: "one")
        #expect(await bounded { await first.value }, "the completion resumed the registered waiter")

        // Registered, cancelled, then completed: the cancellation resumes it, and the later
        // completion finds no waiter to resume a second time.
        let cancelledRegistration = TestGate()
        let cancelled = Task { await h.adapter.waitForActionResponsesFinishedForTesting(2) { await cancelledRegistration.arrive() } }
        #expect(await cancelledRegistration.waitForArrivals(1))
        cancelledRegistration.open()
        cancelled.cancel()
        #expect(await bounded { await cancelled.value }, "the registered waiter returned on cancellation")
        try await h.ping(session, tag: "two")
        #expect(await bounded { await h.adapter.waitForActionResponsesFinishedForTesting(2) }, "the second completion counted")

        // Cancelled before it registered: it returns without being stored.
        let early = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await h.adapter.waitForActionResponsesFinishedForTesting(3) { Issue.record("a cancelled waiter registered") }
        }
        #expect(await bounded { await early.value }, "the waiter cancelled first returned")
        #expect(await connection.waitUntilFrames { $0.filter { $0.kind == .actionResponse }.count == 2 })
    }

    @Test("The action-response waiter returns only after its acknowledgement ends, across a cancellation and a completion")
    func actionResponseWaiterJoinsItsAcknowledgement() async throws {
        let h = try await HooksHarness.make()
        let session = SessionID("s1")
        let connection = await h.connect(session)
        try await h.join(session, player: "p1")
        #expect(await connection.waitForFirstSync())

        // Held across a cancellation: the waiter is resumed, but returns only after the ack.
        let log = OrderLog()
        let heldAcrossCancel = TestGate()
        let cancelled = Task {
            await h.adapter.waitForActionResponsesFinishedForTesting(1) {
                await heldAcrossCancel.arrive()
                await log.append("ack ended")
            }
            await log.append("returned")
        }
        #expect(await heldAcrossCancel.waitForArrivals(1))
        cancelled.cancel()
        heldAcrossCancel.open()
        #expect(await bounded { await cancelled.value })
        #expect(await log.entries == ["ack ended", "returned"])

        // Held across a completion: the same.
        let completionLog = OrderLog()
        let heldAcrossCompletion = TestGate()
        let completed = Task {
            await h.adapter.waitForActionResponsesFinishedForTesting(1) {
                await heldAcrossCompletion.arrive()
                await completionLog.append("ack ended")
            }
            await completionLog.append("returned")
        }
        #expect(await heldAcrossCompletion.waitForArrivals(1))
        try await h.ping(session, tag: "one")
        #expect(await bounded { await h.adapter.waitForActionResponsesFinishedForTesting(1) }, "the completion counted")
        heldAcrossCompletion.open()
        #expect(await bounded { await completed.value })
        #expect(await completionLog.entries == ["ack ended", "returned"])
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

    // MARK: Named observations through the router

    @Test("admittedNotRegistered and the join commits through a real router attempt: keyed by the router's attempt number")
    func observationsThroughTheRouter() async throws {
        let h = try await HooksHarness.make(autoStartLoops: false)
        // The in-turn join's observations; the IN_TURN_SYNC=false leg covers the other path.
        guard await h.keeper.isUsingInTurnSync() else { return }
        await h.adapter.captureJoinCommitsForTesting()
        let gate = TestGate()
        await h.adapter.installHolds(HoldRegistry.at(.keeperJoinReturned) { await gate.arrive() })
        let session = SessionID("s-real-attempt")
        _ = await h.connect(session)
        let join = Task { try await h.join(session, player: "p1") }
        #expect(await gate.waitForArrivals(1), "the join reached keeperJoinReturned")
        // Admitted, and neither the adapter nor the transport's player table has it registered.
        #expect(await h.adapter.admittedNotRegisteredForTesting(session))
        #expect(await h.transport.playerSessionsForTesting(PlayerID("p1")).isEmpty)
        gate.open()
        try await join.value
        await h.router.waitForNoPendingFlipForTesting()
        #expect(await h.transport.playerSessionsForTesting(PlayerID("p1")) == [session])
        #expect(await !h.adapter.admittedNotRegisteredForTesting(session))
        typealias Key = TransportAdapter<HarnessHooksState>.JoinAttemptKey
        // The router's first attempt is number 1.
        #expect(await h.adapter.joinFlippedForTesting(Key(sessionID: session, attempt: 1)))
        #expect(await h.adapter.initialSyncCommittedForTesting(Key(sessionID: session, attempt: 1)))
        #expect(await !h.adapter.joinFlippedForTesting(Key(sessionID: session, attempt: nil)))
        #expect(await !h.adapter.joinFlippedForTesting(Key(sessionID: session, attempt: 2)))
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
