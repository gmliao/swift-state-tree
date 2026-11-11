import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

// The two `Diagnostics` hooks a benchmark needs to drive lands through a router by hand: a land
// manager whose live keepers don't start their loops, and a transport flush that returns once
// every session's connection has its queued frames.

private func steppedLand(_ landID: LandID) -> LandDefinition<ManagerTestState> {
    Land("stepped", using: ManagerTestState.self) {
        Rules {}
        Lifetime {
            Tick(every: .milliseconds(50)) { (state: inout ManagerTestState, _: LandContext) in
                state.ticks += 1
            }
            StateSync(every: .milliseconds(50)) { (_: ManagerTestState, _: LandContext) in }
        }
    }
}

private func landManager(autoStartLoops: Bool?) -> LandManager<ManagerTestState> {
    if let autoStartLoops {
        return LandManager<ManagerTestState>(
            landFactory: steppedLand,
            initialStateFactory: { _ in ManagerTestState() },
            autoStartLoops: autoStartLoops,
            syncLag: nil
        )
    }
    return LandManager<ManagerTestState>(landFactory: steppedLand, initialStateFactory: { _ in ManagerTestState() })
}

@Suite("Benchmark diagnostics: a land manager without loops")
struct LandManagerWithoutLoopsTests {
    @Test("Its live keepers start no loop, and one step moves the tick by exactly one")
    func noLoops() async throws {
        let manager = landManager(autoStartLoops: false)
        let landID = LandID("stepped:room-1")
        let container = try await manager.getOrCreateLand(
            landID: landID, definition: steppedLand(landID), initialState: ManagerTestState(), metadata: [:]
        )
        let keeper = container.keeper
        // The keeper's initialization runs in a task of its own, and starts the loops at its end:
        // only after it can "no loop" mean the flag kept them off.
        await keeper.awaitInitialization()
        #expect(keeper.hasPeriodicSync == false)
        #expect(await keeper.hasTickLoopForTesting() == false)
        #expect(await keeper.hasSyncLoopForTesting() == false)
        #expect(await keeper.currentState().ticks == 0)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 1)
        await keeper.stepTickOnce()
        #expect(await keeper.currentState().ticks == 2)
        await manager.shutdownAllLands()
    }

    @Test("With autoStartLoops true, and through the public init, the loops start as before")
    func loopsByDefault() async throws {
        for manager in [landManager(autoStartLoops: true), landManager(autoStartLoops: nil)] {
            let landID = LandID("stepped:room-1")
            let container = try await manager.getOrCreateLand(
                landID: landID, definition: steppedLand(landID), initialState: ManagerTestState(), metadata: [:]
            )
            // As above: the loops start at the end of the keeper's initialization, not in its init.
            await container.keeper.awaitInitialization()
            #expect(container.keeper.hasPeriodicSync)
            #expect(await container.keeper.hasTickLoopForTesting())
            #expect(await container.keeper.hasSyncLoopForTesting())
            await manager.shutdownAllLands()
        }
    }
}

/// A connection whose sends wait at a gate, recording what was handed to it.
private final class HeldConnection: WebSocketConnection, @unchecked Sendable {
    let gate = TestGate()
    private let lock = NSLock()
    private var sent: [Data] = []
    private let failing: Bool

    init(failing: Bool = false) {
        self.failing = failing
    }

    var received: [Data] {
        lock.lock()
        defer { lock.unlock() }
        return sent
    }

    func send(_ data: Data) async throws {
        await gate.arrive()
        if failing { throw CancellationError() }
        lock.withLock { sent.append(data) }
    }

    func close() async throws {}
}

/// A transport whose `flushSessionQueues` holds after queuing its markers, and a flush running
/// on it whose return is counted.
private struct HeldFlush {
    let transport: WebSocketTransport
    /// Arrived at once the flush's markers are queued; holds the flush there until opened.
    let markersQueued = TestGate()
    /// Open: arrived when the flush returns.
    let returned = TestGate()
    let task: Task<Void, Never>

    init(_ transport: WebSocketTransport) async {
        self.transport = transport
        let markersQueued = self.markersQueued
        let returned = self.returned
        returned.open()
        await transport.setFlushMarkersQueuedForTesting { await markersQueued.arrive() }
        task = Task {
            await transport.flushSessionQueues()
            await returned.arrive()
        }
    }
}

/// A transport with one session whose first frame's send is held at the connection's gate.
private func sessionWithHeldSend() async -> (WebSocketTransport, HeldConnection, SessionID) {
    let transport = WebSocketTransport()
    let connection = HeldConnection()
    let session = SessionID("s1")
    _ = await transport.handleConnection(sessionID: session, connection: connection)
    await transport.send(Data("frame".utf8), to: .session(session))
    #expect(await connection.gate.waitForArrivals(1))
    return (transport, connection, session)
}

@Suite("Benchmark diagnostics: flushing the transport's session queues")
struct WebSocketTransportFlushTests {
    @Test("A flush waits for a held send, and returns once it is handed to the connection")
    func waitsForHeldSend() async throws {
        let (transport, connection, _) = await sessionWithHeldSend()
        let flush = await HeldFlush(transport)
        // The marker is queued behind the held frame, and the flush goes on to wait for it.
        #expect(await flush.markersQueued.waitForArrivals(1))
        #expect(await transport.pendingFlushMarkersForTesting() == 1)
        flush.markersQueued.open()
        // Only the drain reaching the marker resumes the flush, and the drain is held in the
        // frame's send: the flush can't have returned, nor the frame been delivered.
        await Task.yield()
        #expect(flush.returned.arrivalCount == 0)
        #expect(connection.received.isEmpty)

        connection.gate.open()
        #expect(await flush.returned.waitForArrivals(1))
        #expect(connection.received == [Data("frame".utf8)])
    }

    @Test("A flush with no sessions returns at once")
    func noSessions() async {
        await WebSocketTransport().flushSessionQueues()
    }

    @Test("A session disconnected while its drain is held in a send releases the flush")
    func disconnectedDuringFlush() async throws {
        let (transport, connection, session) = await sessionWithHeldSend()
        let flush = await HeldFlush(transport)
        #expect(await flush.markersQueued.waitForArrivals(1))
        // Markers queued, the send held: the session goes. Its drain stays in the send past its
        // cancellation, so only the retirement itself can release the flush.
        await transport.handleDisconnection(sessionID: session)
        flush.markersQueued.open()
        #expect(await flush.returned.waitForArrivals(1))
        #expect(connection.received.isEmpty)
        connection.gate.open()
    }

    @Test("A transport stopped while a drain is held in a send releases the flush")
    func stoppedDuringFlush() async throws {
        let (transport, connection, _) = await sessionWithHeldSend()
        let flush = await HeldFlush(transport)
        #expect(await flush.markersQueued.waitForArrivals(1))
        try await transport.stop()
        flush.markersQueued.open()
        #expect(await flush.returned.waitForArrivals(1))
        #expect(connection.received.isEmpty)
        connection.gate.open()
    }

    @Test("A session whose drain ended on a failed send counts as flushed")
    func drainEndedOnFailedSend() async throws {
        let transport = WebSocketTransport()
        let connection = HeldConnection(failing: true)
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: connection)
        connection.gate.open()
        await transport.send(Data("frame".utf8), to: .session(session))
        // The failed send ends the drain; a flush after it finds the stream terminated.
        #expect(await connection.gate.waitForArrivals(1))
        await transport.flushSessionQueues()
        // And a second one, after the drain released its waiters for good.
        await transport.flushSessionQueues()
    }
}

@Suite("Benchmark diagnostics: an adapter's effective state-update features")
struct EffectiveStateUpdateFeaturesTests {
    /// Joins one session declaring every feature, and returns the joinResponse's echo and the
    /// bound land's `effectiveStateUpdateFeatures`.
    private func joined(_ encoding: TransportEncodingConfig) async throws -> (echo: [String]?, effective: [String]) {
        let (transport, router, manager) = try PathIndexTests.router(encoding: encoding)
        await transport.setDelegate(router)
        let session = SessionID("s-effective")
        let connection = PathIndexReplyConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        await transport.handleIncomingMessage(sessionID: session, data: try PathIndexTests.join(features: StateUpdateFeature.supported))
        let reply = try await PathIndexTests.waitForReply(connection)
        guard case .joinResponse(let response) = reply.payload else {
            Issue.record("not a joinResponse: \(reply)")
            return (nil, [])
        }
        #expect(response.success)
        let land = try #require(await router.getBoundLandID(for: session))
        let adapter = try #require(await manager.getLand(landID: land)?.transportAdapter)
        await manager.shutdownAllLands()
        return (response.stateUpdateFeatures, adapter.effectiveStateUpdateFeatures)
    }

    @Test("Without rowAddressing requested, it is the joinResponse's echo and has no rowAddressing")
    func withoutRowAddressing() async throws {
        let (echo, effective) = try await joined(PathIndexTests.messagepack.withPathIndex(true).withFieldMerge(true).withSyncSequence(true))
        #expect(effective == echo)
        #expect(!effective.isEmpty)
        #expect(!effective.contains(StateUpdateFeature.rowAddressing))
    }

    @Test("With rowAddressing in effect, it is the joinResponse's echo and has rowAddressing", .enabled(if: InTurnSync.isEnabled()))
    func withRowAddressing() async throws {
        let (echo, effective) = try await joined(
            PathIndexTests.messagepack.withPathIndex(true).withFieldMerge(true).withSyncSequence(true).withRowAddressing(true)
        )
        #expect(effective == echo)
        #expect(effective.contains(StateUpdateFeature.rowAddressing))
    }
}

@Suite("Benchmark diagnostics: a land manager with a sync-lag policy")
struct LandManagerSyncLagTests {
    /// A router over the diagnostics manager, path hashes on, loops off: as a benchmark builds it.
    static func router(syncLag: SyncLagPolicy?) throws -> (WebSocketTransport, LandRouter<PathIndexState>, LandManager<PathIndexState>) {
        let encoding = PathIndexTests.messagepack.withPathIndex(true).withFieldMerge(true)
        let transport = WebSocketTransport()
        let registry = try LandTypeRegistry<PathIndexState>(
            landFactory: { landType, _ in Land(landType, using: PathIndexState.self) { Rules {} } },
            initialStateFactory: { _, _ in PathIndexState() }
        )
        let manager = LandManager<PathIndexState>(
            landFactory: { landID in registry.getLandDefinition(landType: landID.landType, landID: landID) },
            initialStateFactory: { landID in registry.initialStateFactory(landID.landType, landID) },
            transport: transport,
            transportEncoding: encoding,
            pathHashes: try PathIndexTests.pathHashes(PathIndexState.self, PathIndexTests.landType),
            autoStartLoops: false,
            syncLag: syncLag
        )
        let router = LandRouter<PathIndexState>(
            landManager: manager, landTypeRegistry: registry, transport: transport,
            allowAutoCreateOnJoin: true, transportEncoding: encoding
        )
        return (transport, router, manager)
    }

    /// Joins one session declaring every feature; returns its adapter, keeper and the echo.
    static func join(
        _ transport: WebSocketTransport, _ router: LandRouter<PathIndexState>, _ manager: LandManager<PathIndexState>,
        session: SessionID
    ) async throws -> (TransportAdapter<PathIndexState>, LandKeeper<PathIndexState>, [String]?) {
        await transport.setDelegate(router)
        let connection = PathIndexReplyConnection()
        await transport.handleConnection(sessionID: session, connection: connection, authInfo: nil)
        await transport.handleIncomingMessage(sessionID: session, data: try PathIndexTests.join(features: StateUpdateFeature.supported))
        let reply = try await PathIndexTests.waitForReply(connection)
        guard case .joinResponse(let response) = reply.payload, response.success else {
            Issue.record("not a successful joinResponse: \(reply)")
            throw CancellationError()
        }
        let land = try #require(await router.getBoundLandID(for: session))
        let container = try #require(await manager.getLand(landID: land))
        return (container.transportAdapter, container.keeper, response.stateUpdateFeatures)
    }

    @Test("With a policy, the lands run as hosted: syncSequence is in effect, the policy is the adapter's, an ack is accepted")
    func withPolicy() async throws {
        // The environment's with one field changed, so it differs from the adapter's own default
        // (the environment's) whatever the environment sets: only a policy passed through
        // reaches the adapter.
        var policy = SyncLagPolicy.fromEnvironment()
        policy.resyncAfter += .seconds(77)
        let (transport, router, manager) = try Self.router(syncLag: policy)
        let session = SessionID("s-lag")
        let (adapter, keeper, echo) = try await Self.join(transport, router, manager, session: session)
        #expect(adapter.effectiveStateUpdateFeatures.contains(StateUpdateFeature.syncSequence))
        #expect(echo == adapter.effectiveStateUpdateFeatures)
        #expect(await adapter.syncLagPolicyForTesting() == policy)
        // The firstSync commits in a step (loops are off): it is the session's newest unacked frame.
        await keeper.stepTickOnce()
        await adapter.syncNow()
        let seq = try #require(await adapter.syncLagLastCommittedSeqForTesting(session))
        await transport.handleIncomingMessage(sessionID: session, data: SyncAckFrame.encode(seq: seq, binary: true))
        #expect(await adapter.syncLagDroppedAcks == 0)
        #expect(await adapter.syncLagLastCommittedSeqForTesting(session) == nil)
        await manager.shutdownAllLands()
    }

    @Test("Without one (nil), there is no sync sequence and an ack is dropped")
    func withoutPolicy() async throws {
        let (transport, router, manager) = try Self.router(syncLag: nil)
        let session = SessionID("s-no-lag")
        let (adapter, keeper, echo) = try await Self.join(transport, router, manager, session: session)
        #expect(!adapter.effectiveStateUpdateFeatures.contains(StateUpdateFeature.syncSequence))
        #expect(echo == adapter.effectiveStateUpdateFeatures)
        await keeper.stepTickOnce()
        await adapter.syncNow()
        #expect(await adapter.syncLagLastCommittedSeqForTesting(session) == nil)
        await transport.handleIncomingMessage(sessionID: session, data: SyncAckFrame.encode(seq: 1, binary: true))
        #expect(await adapter.syncLagDroppedAcks == 1)
        await manager.shutdownAllLands()
    }
}

@Suite("Benchmark diagnostics: an adapter's sync-lag ack state")
struct SyncLagAckDiagnosticsTests {
    @Test("An accepted ack empties the session's frames; an ack from a session with no lag state counts as dropped")
    func ackState() async throws {
        let (transport, router, manager) = try LandManagerSyncLagTests.router(syncLag: .fromEnvironment())
        let session = SessionID("s-acks")
        let (adapter, keeper, _) = try await LandManagerSyncLagTests.join(transport, router, manager, session: session)
        await keeper.stepTickOnce()
        await adapter.syncNow()
        let seq = try #require(await adapter.syncLagLastCommittedSeqForTesting(session))
        #expect(await adapter.syncLagAckDiagnostics() == SyncLagAckDiagnostics(droppedAcks: 0, sessionsWithUnackedFrames: 1))
        await transport.handleIncomingMessage(sessionID: session, data: SyncAckFrame.encode(seq: seq, binary: true))
        #expect(await adapter.syncLagAckDiagnostics() == SyncLagAckDiagnostics(droppedAcks: 0, sessionsWithUnackedFrames: 0))
        // Straight to the adapter (a router drops it for an unbound session before the adapter).
        await adapter.onSyncAck(seq, from: SessionID("s-unknown"))
        #expect(await adapter.syncLagAckDiagnostics() == SyncLagAckDiagnostics(droppedAcks: 1, sessionsWithUnackedFrames: 0))
        await manager.shutdownAllLands()
    }
}
