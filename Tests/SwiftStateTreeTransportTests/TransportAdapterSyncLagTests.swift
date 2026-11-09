import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct SyncLagTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
}

@Payload
struct SyncLagIncrementEvent: ClientEventPayload {
    public init() {}
}

/// A clock the test moves by hand.
final class SyncLagManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current = ContinuousClock.now
    var now: ContinuousClock.Instant { lock.withLock { current } }
    func advance(_ seconds: Double) {
        lock.withLock { current = current + .milliseconds(Int64(seconds * 1000)) }
    }
}

/// The adapter side of sync-lag tracking (#332): frames carry an increasing sequence, acks reach
/// the lag state without the keeper, and a lagging reader is resynced in place.
@Suite("Sync lag: the adapter")
struct TransportAdapterSyncLagTests {
    struct Fixture {
        let adapter: TransportAdapter<SyncLagTestState>
        let keeper: LandKeeper<SyncLagTestState>
        let transport: Opcode107RecordingTransport
        let clock: SyncLagManualClock
        let binary: Bool
        let sessionID = SessionID("sess-lag")
        let clientID = ClientID("cli-lag")
        let playerID = PlayerID("player-lag")

        /// The state-update frames recorded since the last call, as `(opcode, seq)`.
        func stateFrames() async throws -> [(op: Int, seq: UInt64)] {
            let messages = await transport.recordedMessages()
            await transport.clearMessages()
            return try messages.compactMap { data in
                guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                      let op = array.first as? Int, (1...3).contains(op) else { return nil }
                let seq = try #require(array.count > 1 ? SyncAckFrame.syncSequence(array[1]) : nil)
                return (op, seq)
            }
        }

        func bump() async throws {
            let message = TransportMessage.event(event: .fromClient(event: AnyClientEvent(SyncLagIncrementEvent())))
            let data = binary
                ? try MessagePackTransportMessageEncoder().encode(message)
                : try JSONTransportMessageEncoder().encode(message)
            await adapter.onMessage(data, from: sessionID)
            try await Task.sleep(for: .milliseconds(20))
            await adapter.syncNow()
            #expect(await adapter.waitForOutboundDrain())
        }

        func ack(_ seq: UInt64, from session: SessionID? = nil) async {
            await adapter.onMessage(SyncAckFrame.encode(seq: seq, binary: binary), from: session ?? sessionID)
        }
    }

    /// `timerInterval`: the lag timer's period. Plan-driven tests keep it out of the way, so
    /// only their own syncs plan.
    func makeFixture(
        timerInterval: Duration = .seconds(3600), binary: Bool = false, syncSequence: Bool = true
    ) async throws -> Fixture {
        let definition = Land("sync-lag-test", using: SyncLagTestState.self) {
            ClientEvents { Register(SyncLagIncrementEvent.self) }
            ServerEvents { Register(Opcode107MessageEvent.self) }
            Rules {
                HandleEvent(SyncLagIncrementEvent.self) { (state: inout SyncLagTestState, _: SyncLagIncrementEvent, _) in
                    state.count += 1
                }
            }
        }
        let transport = Opcode107RecordingTransport()
        let keeper = LandKeeper<SyncLagTestState>(definition: definition, initialState: SyncLagTestState())
        let adapter = TransportAdapter<SyncLagTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-lag-test",
            encodingConfig: binary
                ? TransportEncodingConfig(message: .messagepack, stateUpdate: .opcodeMessagePack, syncSequence: true)
                : TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray, syncSequence: syncSequence)
        )
        await transport.setDelegate(adapter)
        let clock = SyncLagManualClock()
        await adapter.setSyncLagClockForTesting { clock.now }
        await adapter.setSyncLagTimerIntervalForTesting(timerInterval)
        let fixture = Fixture(adapter: adapter, keeper: keeper, transport: transport, clock: clock, binary: binary)
        await adapter.onConnect(sessionID: fixture.sessionID, clientID: fixture.clientID)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: fixture.sessionID, clientID: fixture.clientID, playerID: fixture.playerID
        )
        return fixture
    }

    @Test("Every state-update frame carries the plan's sequence, increasing per plan")
    func sequenceIncreases() async throws {
        let f = try await makeFixture()
        let first = try await f.stateFrames()
        #expect(first.map(\.op) == [1])
        try await f.bump()
        let second = try await f.stateFrames()
        #expect(second.map(\.op) == [2])
        #expect((second.first?.seq ?? 0) > (first.first?.seq ?? .max))
        try await f.bump()
        let third = try await f.stateFrames()
        #expect((third.first?.seq ?? 0) > (second.first?.seq ?? .max))
    }

    @Test("A reader acking an old value past 3 s gets an in-place resync, typed resync")
    func slowReaderResync() async throws {
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        _ = try await f.stateFrames()
        // Acks keep coming with the firstSync's value; the diff stays unacked.
        f.clock.advance(1.5)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(1.5)
        await f.ack(firstSync.seq)
        try await f.bump()
        #expect(try await f.stateFrames().map(\.op) == [2, 2])
        f.clock.advance(0.6)
        await f.ack(firstSync.seq)
        try await f.bump()
        let resync = try await f.stateFrames()
        #expect(resync.map(\.op) == [3])
        #expect(await f.adapter.syncLagResyncs == 1)
        // Back to diffs after the snapshot is acked.
        await f.ack(try #require(resync.first).seq)
        try await f.bump()
        #expect(try await f.stateFrames().map(\.op) == [2])
    }

    @Test("Silent past 3 s: frames are withheld; acks resuming bring a resync")
    func silentReaderPending() async throws {
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.5)
        try await f.bump()
        #expect(try await f.stateFrames().isEmpty, "pending: no frames")
        #expect(await f.adapter.syncLagPendingMarks == 1)
        try await f.bump()
        #expect(try await f.stateFrames().isEmpty)
        await f.ack(firstSync.seq)
        try await f.bump()
        #expect(try await f.stateFrames().map(\.op) == [3])
    }

    @Test("Tickless, no syncs: the timer closes a reader silent past the ack timeout")
    func timerClosesUnresponsive() async throws {
        let f = try await makeFixture(timerInterval: .milliseconds(10))
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(10.5)
        for _ in 0..<200 where await f.adapter.syncLagUnresponsiveCloses == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
    }

    @Test("Tickless: the timer requests a sync for a due resync; an idle land with empty FIFOs gets none")
    func timerRequestsSync() async throws {
        let f = try await makeFixture(timerInterval: .milliseconds(10))
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        // Idle with nothing unacked, for long: no sync requested.
        f.clock.advance(30)
        await f.ack(firstSync.seq)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await f.adapter.syncLagTimerSyncRequests == 0)
        // One frame left unacked, acks fresh, lag past 3 s: the timer's sync resyncs.
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.5)
        await f.ack(firstSync.seq)
        for _ in 0..<200 where await f.adapter.syncLagResyncs == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await f.adapter.syncLagResyncs == 1)
        #expect(await f.adapter.syncLagTimerSyncRequests >= 1)
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(try await f.stateFrames().map(\.op) == [3])
    }

    @Test("A pending session's targeted events are dropped and counted, not delivered later")
    func pendingDropsEvents() async throws {
        let f = try await makeFixture(binary: true)
        await f.ack(.max >> 1)
        try await f.bump()
        f.clock.advance(3.5)
        await f.transport.clearMessages()
        await f.adapter.sendEvent(AnyServerEvent(Opcode107MessageEvent(message: "lost")), to: .client(f.clientID))
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.adapter.syncLagPendingMarks == 1)
        #expect(await f.adapter.syncLagDroppedEvents >= 1)
        #expect(await f.transport.recordedMessages().isEmpty)
    }

    @Test("A player with two sessions, one lagging: both get the snapshot, one resync counted")
    func twoSessions() async throws {
        let f = try await makeFixture()
        let second = SessionID("sess-lag-2")
        await f.adapter.onConnect(sessionID: second, clientID: ClientID("cli-lag-2"))
        await f.adapter.registerSession(sessionID: second, clientID: ClientID("cli-lag-2"), playerID: f.playerID, authInfo: nil)
        await f.adapter.syncStateForNewPlayer(playerID: f.playerID, sessionID: second)
        #expect(await f.adapter.waitForOutboundDrain())
        let firstSyncs = try await f.stateFrames()
        let firstSeq = try #require(firstSyncs.first).seq
        await f.ack(.max >> 1, from: second)
        await f.ack(firstSeq)
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(1.5)
        await f.ack(firstSeq)
        await f.ack(.max >> 1, from: second)
        f.clock.advance(1.8)
        await f.ack(firstSeq)
        await f.ack(.max >> 1, from: second)
        try await f.bump()
        #expect(try await f.stateFrames().map(\.op) == [3, 3])
        #expect(await f.adapter.syncLagResyncs == 1)
    }

    @Test("The session disconnects while the timer's sync is held: nothing is recreated, no resync")
    func disconnectDuringTimerSync() async throws {
        let f = try await makeFixture(timerInterval: .milliseconds(10))
        let gate = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.syncLagTimerSync) { await gate.arrive() })
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(3.5)
        await f.ack(firstSync.seq)
        #expect(await gate.waitForArrivals(1))
        await f.adapter.onDisconnect(sessionID: f.sessionID, clientID: f.clientID)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        await f.adapter.syncNow()
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        #expect(await f.adapter.syncLagResyncs == 0)
    }

    @Test("A land without syncSequence: frames carry no sequence, acks are dropped, no lag state, never a resync")
    func trackingOff() async throws {
        let f = try await makeFixture(syncSequence: false)
        let messages = await f.transport.recordedMessages()
        await f.transport.clearMessages()
        let last = try #require(messages.last)
        let firstSync = try #require(try JSONSerialization.jsonObject(with: last) as? [Any])
        #expect(firstSync.first as? Int == 1)
        #expect(!(firstSync.count > 1 && firstSync[1] is NSNumber), "no sequence after the opcode")
        await f.ack(1)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        try await f.bump()
        f.clock.advance(30)
        try await f.bump()
        let ops = try (await f.transport.recordedMessages()).compactMap {
            (try JSONSerialization.jsonObject(with: $0) as? [Any])?.first as? Int
        }
        #expect(!ops.contains(3))
        #expect(await f.adapter.syncLagResyncs == 0)
        #expect(await f.adapter.syncLagUnresponsiveCloses == 0)
    }

    @Test("A lag close's Task held while the same session's leave runs: one leave, nothing recreated")
    func closeTaskDuringLeave() async throws {
        let f = try await makeFixture()
        let gate = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.syncLagClose) { await gate.arrive() })
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(10.5)
        try await f.bump()
        #expect(await gate.waitForArrivals(1))
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        await f.adapter.onDisconnect(sessionID: f.sessionID, clientID: f.clientID)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        #expect(await f.keeper.playerCount() == 0, "the leave ran once")
        gate.open()
        for _ in 0..<20 { await Task.yield() }
        // A second disconnect (the transport's, after its close) changes nothing either.
        await f.adapter.onDisconnect(sessionID: f.sessionID, clientID: f.clientID)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        #expect(await f.keeper.playerCount() == 0)
    }

    @Test("Silent past the ack timeout: closed as unresponsive")
    func unresponsiveClose() async throws {
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(10.5)
        try await f.bump()
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        // Its acks are ignored from now on.
        await f.ack(99)
        #expect(await f.adapter.syncLagDroppedAcks == 1)
    }
}
