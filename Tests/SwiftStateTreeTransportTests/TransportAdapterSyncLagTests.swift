import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
struct SyncLagTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    /// Dynamic keys, so MessagePack's broadcast key scope has slots to reset.
    @Sync(.broadcast)
    var tags: [String: Int] = [:]
}

/// Path hashes for the MessagePack fixture: dynamic key slots need them.
private let syncLagPathHashes: [String: UInt32] = Dictionary(
    uniqueKeysWithValues: ["count", "tags", "tags.*"].map { ($0, DeterministicHash.fnv1a32($0)) }
)

@Payload
struct SyncLagIncrementEvent: ClientEventPayload {
    public init() {}
}

@Payload
struct SyncLagIncrementAction: ActionPayload {
    typealias Response = SyncLagIncrementResponse
    public init() {}
}

@Payload
struct SyncLagIncrementResponse: ResponsePayload {
    let ok: Bool
}

/// Throws on its first call only.
final class FailOnce: @unchecked Sendable {
    struct Fault: Error {}
    private let lock = NSLock()
    private var fired = false
    var didFire: Bool { lock.withLock { fired } }
    func fire() throws {
        let first = lock.withLock { () -> Bool in
            defer { fired = true }
            return !fired
        }
        if first { throw Fault() }
    }
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

        /// The state-update frames recorded since the last call, in order, as `(opcode, seq)`;
        /// `merged` for one inside an opcode 107 frame.
        func stateFrames() async throws -> [(op: Int, seq: UInt64, merged: Bool)] {
            let messages = await transport.recordedMessages()
            await transport.clearMessages()
            if binary {
                // `[op, seq, …]`, or merged into opcode 107: `[107, [op, seq, …], …]`.
                func uint(_ value: MessagePackValue) -> UInt64? {
                    switch value {
                    case .uint(let n): return n
                    case .int(let n) where n >= 0: return UInt64(n)
                    default: return nil
                    }
                }
                return messages.compactMap { data in
                    guard case .array(var array)? = try? unpack(data), let first = array.first else { return nil }
                    var merged = false
                    if uint(first) == 107, array.count > 1, case .array(let inner) = array[1] {
                        array = inner
                        merged = true
                    }
                    guard array.count > 1, let op = uint(array[0]), (1...3).contains(op),
                          let seq = uint(array[1]) else { return nil }
                    return (Int(op), seq, merged)
                }
            }
            return try messages.compactMap { data in
                guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                      let op = array.first as? Int, (1...3).contains(op) else { return nil }
                let seq = try #require(array.count > 1 ? SyncAckFrame.syncSequence(array[1]) : nil)
                return (op, seq, false)
            }
        }

        /// Changes the state (an action the keeper has applied when this returns), then syncs.
        func bump() async throws {
            try await change()
            await adapter.syncNow()
            #expect(await adapter.waitForOutboundDrain())
        }

        /// Changes the state without a sync of its own (an in-turn sync may still run in the
        /// action's turn).
        func change() async throws {
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: SyncLagIncrementAction.self),
                payload: AnyCodable(SyncLagIncrementAction())
            )
            _ = try await keeper.handleActionEnvelope(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID)
        }

        func ack(_ seq: UInt64, from session: SessionID? = nil) async {
            await adapter.onMessage(SyncAckFrame.encode(seq: seq, binary: binary), from: session ?? sessionID)
        }
    }

    /// `timerInterval`: the lag timer's period. Plan-driven tests keep it out of the way, so
    /// only their own syncs plan.
    func makeFixture(
        timerInterval: Duration = .seconds(3600), binary: Bool = false, syncSequence: Bool = true,
        inTurnSync: Bool = true,
        failFirstSync: Bool = false
    ) async throws -> Fixture {
        let definition = Land("sync-lag-test", using: SyncLagTestState.self) {
            ClientEvents { Register(SyncLagIncrementEvent.self) }
            ServerEvents { Register(Opcode107MessageEvent.self) }
            Rules {
                HandleEvent(SyncLagIncrementEvent.self) { (state: inout SyncLagTestState, _: SyncLagIncrementEvent, _) in
                    state.count += 1
                }
                HandleAction(SyncLagIncrementAction.self) { (state: inout SyncLagTestState, _: SyncLagIncrementAction, _: LandContext) in
                    state.count += 1
                    state.tags["k\(state.count)"] = state.count
                    return SyncLagIncrementResponse(ok: true)
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
                ? TransportEncodingConfig(
                    message: .messagepack, stateUpdate: .opcodeMessagePack, pathIndex: false, fieldMerge: false, syncSequence: true
                )
                : TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray, syncSequence: syncSequence),
            pathHashes: binary ? syncLagPathHashes : nil,
            inTurnSync: inTurnSync
        )
        await transport.setDelegate(adapter)
        let clock = SyncLagManualClock()
        await adapter.setSyncLagClockForTesting { clock.now }
        await adapter.setSyncLagTimerIntervalForTesting(timerInterval)
        if failFirstSync {
            let once = FailOnce()
            await adapter.setFirstSyncPlanFaultForTesting { try once.fire() }
        }
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
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(9.5)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        #expect(await f.adapter.syncLagUnresponsiveCloses == 0, "within the ack timeout")
        f.clock.advance(1)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
    }

    @Test("Tickless: the timer requests a sync for a due resync; an idle land with empty FIFOs gets none")
    func timerRequestsSync() async throws {
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        // Idle with nothing unacked, for long: a pass requests no sync.
        f.clock.advance(30)
        await f.ack(firstSync.seq)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        #expect(await f.adapter.syncLagTimerSyncRequests == 0)
        // One frame left unacked, acks fresh, lag past 3 s: the pass requests a sync that resyncs.
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.5)
        await f.ack(firstSync.seq)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        // The requested sync runs in a background task: wait for it, then for its frames.
        #expect(await f.adapter.waitForSyncQuiescenceForTesting())
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.adapter.syncLagResyncs == 1)
        #expect(await f.adapter.syncLagTimerSyncRequests == 1)
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

    @Test("JSON encodings send events at emit: a pending session's are dropped and counted too")
    func pendingDropsImmediateEvents() async throws {
        let f = try await makeFixture()
        await f.ack(.max >> 1)
        try await f.bump()
        f.clock.advance(3.5)
        // The plan past 3 s with stale acks marks it pending.
        try await f.bump()
        #expect(await f.adapter.syncLagPendingMarks == 1)
        await f.transport.clearMessages()
        let droppedBefore = await f.adapter.syncLagDroppedEvents
        await f.adapter.sendEvent(AnyServerEvent(Opcode107MessageEvent(message: "lost")), to: .client(f.clientID))
        await f.adapter.sendEvent(AnyServerEvent(Opcode107MessageEvent(message: "lost too")), to: .all)
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.transport.recordedMessages().isEmpty)
        #expect(await f.adapter.syncLagDroppedEvents == droppedBefore + 2)
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
        let f = try await makeFixture()
        let gate = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.syncLagTimerSync) { await gate.arrive() })
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(3.5)
        await f.ack(firstSync.seq)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        #expect(await gate.waitForArrivals(1))
        await f.adapter.onDisconnect(sessionID: f.sessionID, clientID: f.clientID)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        gate.open()
        #expect(await f.adapter.waitForSyncQuiescenceForTesting(), "the held sync ran")
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
        let closed = TestGate()
        closed.open()
        await f.adapter.installHolds(
            HoldRegistry<TransportAdapterHoldPoint>()
                .on(.syncLagClose) { await gate.arrive() }
                .on(.syncLagClosed) { await closed.arrive() }
                .hook
        )
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
        #expect(await closed.waitForArrivals(1), "the close Task finished")
        // A second disconnect (the transport's, after its close) changes nothing either.
        await f.adapter.onDisconnect(sessionID: f.sessionID, clientID: f.clientID)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        #expect(await f.keeper.playerCount() == 0)
    }

    @Test(
        "The transport profile counts what the adapter counts: resyncs, alongside, resets, pending, closes by code, dropped acks",
        arguments: [false, true]
    )
    func profileCounters(binary: Bool) async throws {
        let f = try await makeFixture(binary: binary)
        let counters = TransportProfilerCounters()
        await f.adapter.setSyncLagProfilerCountersForTesting(counters)
        let second = SessionID("sess-lag-2")
        await f.adapter.onConnect(sessionID: second, clientID: ClientID("cli-lag-2"))
        await f.adapter.registerSession(sessionID: second, clientID: ClientID("cli-lag-2"), playerID: f.playerID, authInfo: nil)
        await f.adapter.syncStateForNewPlayer(playerID: f.playerID, sessionID: second)
        #expect(await f.adapter.waitForOutboundDrain())
        let firstSeq = try #require(try await f.stateFrames().first).seq
        await f.ack(.max >> 1, from: second)
        await f.ack(firstSeq)
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.3)
        await f.ack(firstSeq)
        await f.ack(.max >> 1, from: second)
        try await f.bump()
        let resyncFrames = try await f.stateFrames().map(\.op)
        // MessagePack merges the broadcast part into an opcode 107 frame for every recipient,
        // ahead of the snapshots; the key-scope reset types it as a firstSync (op 1).
        #expect(binary ? resyncFrames.sorted() == [1, 1, 3, 3] : resyncFrames == [3, 3])

        let resync = counters.takeAndResetSyncLag()
        #expect(resync.resyncs == 1)
        #expect(resync.resyncsAlongside == 1, "the second session got the snapshot too")
        #expect(await f.adapter.syncLagResyncsAlongside == 1)
        #expect(resync.keyScopeResets == (await f.adapter.syncLagKeyScopeResets))
        #expect(resync.keyScopeResetBytes == (await f.adapter.syncLagKeyScopeResetBytes))
        if binary {
            // MessagePack compresses dynamic keys: the resync resets the broadcast key scope once.
            #expect(resync.keyScopeResets == 1)
            #expect(resync.keyScopeResetBytes >= 1)
        }
        #expect(counters.takeAndResetSyncLag() == TransportProfilerCounters.SyncLagWindow(), "reset per window")

        // Both sessions silent past the ack timeout: unresponsive closes, then their acks drop.
        f.clock.advance(10.5)
        try await f.bump()
        await f.ack(99)
        let closes = counters.takeAndResetSyncLag()
        #expect(closes.unresponsiveCloses == (await f.adapter.syncLagUnresponsiveCloses))
        #expect(closes.unresponsiveCloses >= 1)
        #expect(closes.slowConsumerCloses == (await f.adapter.syncLagSlowConsumerCloses))
        #expect(closes.droppedAcks == 1)
        #expect(closes.pendingMarks == (await f.adapter.syncLagPendingMarks))
    }

    @Test("A resync due when a broadcast-only cycle runs: that cycle runs full and resyncs; an ack after it leaves the client correct")
    func resyncDueInBroadcastOnlyCycle() async throws {
        // Legacy sync: an OnLeave's broadcast-only cycle is its own cycle there.
        let f = try await makeFixture(inTurnSync: false)
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        _ = try await f.stateFrames()
        // The diff unacked past 3 s while acks stay fresh: a resync is due.
        f.clock.advance(3.3)
        await f.ack(firstSync.seq)
        try await f.change()
        await f.adapter.syncBroadcastOnly()
        #expect(await f.adapter.waitForOutboundDrain())
        let frames = try await f.stateFrames()
        #expect(frames.map(\.op) == [3], "the broadcast-only cycle ran full and resynced")
        #expect(await f.adapter.syncLagResyncs == 1)
        // An ack brings the lag under 3 s; the next full plan has nothing owed and sends a diff.
        await f.ack(try #require(frames.first).seq)
        try await f.bump()
        #expect(try await f.stateFrames().map(\.op) == [2])
        #expect(await f.adapter.syncLagResyncs == 1)
    }

    @Test("After a lag close decision, the session's actions don't reach the keeper while the close is held")
    func inboundClosedAtDecision() async throws {
        let f = try await makeFixture()
        let gate = TestGate()
        await f.adapter.installHolds(HoldRegistry.at(.syncLagClose) { await gate.arrive() })
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        f.clock.advance(10.5)
        #expect(await f.adapter.syncLagTimerPassForTesting())
        #expect(await gate.waitForArrivals(1))
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        let before = await f.keeper.currentState().count
        let droppedBefore = await f.adapter.inboundDroppedForJoiningSessions
        let action = TransportMessage.action(
            requestID: "after-close",
            action: ActionEnvelope(
                typeIdentifier: String(describing: SyncLagIncrementAction.self),
                payload: AnyCodable(SyncLagIncrementAction())
            )
        )
        await f.adapter.onMessage(try JSONTransportMessageEncoder().encode(action), from: f.sessionID)
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.adapter.inboundDroppedForJoiningSessions == droppedBefore + 1, "dropped at the adapter")
        #expect(await f.keeper.currentState().count == before)
        gate.open()
    }

    @Test("Legacy join whose firstSync plan fails: the next cycle's full view starts tracking")
    func trackingAfterFailedFirstSync() async throws {
        let f = try await makeFixture(inTurnSync: false, failFirstSync: true)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0, "no firstSync committed")
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        let frames = try await f.stateFrames()
        #expect(frames.map(\.op) == [1], "served as an unsynced recipient")
        #expect(await f.adapter.syncLagTrackedSessionCount == 1)
        await f.ack(try #require(frames.first).seq)
        #expect(await f.adapter.syncLagDroppedAcks == 0)
    }

    @Test("MessagePack: a resynced session gets its snapshot before the merged frame; a stopped reader gets 1 resync, then 4010 about 10 s after it")
    func messagePackResyncOrderAndStoppedReader() async throws {
        let f = try await makeFixture(binary: true)
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        // The reader stops at t0: it keeps acking the last sequence it applied, as a paused
        // socket's ack timer does, and applies nothing more.
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.3)
        await f.ack(firstSync.seq)
        try await f.bump()
        let frames = try await f.stateFrames()
        #expect(frames.map(\.op).first == 3, "the snapshot first")
        #expect(frames.count == 2 && frames[1].merged, "then the merged broadcast frame")
        #expect(Set(frames.map(\.seq)).count == 1, "both at the resync's sequence")
        #expect(await f.adapter.syncLagResyncs == 1)
        // Still reading nothing: the snapshot stays unacked while the acks stay fresh.
        var closedAt: Double?
        var elapsed = 3.3
        for _ in 0..<14 where closedAt == nil {
            f.clock.advance(1)
            elapsed += 1
            await f.ack(firstSync.seq)
            try await f.bump()
            if await f.adapter.syncLagSlowConsumerCloses == 1 { closedAt = elapsed }
        }
        #expect(await f.adapter.syncLagResyncs == 1, "exactly one resync")
        let at = try #require(closedAt, "closed with 4010")
        #expect(at > 13.3 && at <= 14.3, "about 10 s after the snapshot")
        #expect(await f.adapter.syncLagUnresponsiveCloses == 0)
    }

    @Test("A plan fault with a resync due commits nothing; the next plan resyncs")
    func planFaultWithResyncDue() async throws {
        let f = try await makeFixture()
        let firstSync = try #require(try await f.stateFrames().first)
        await f.ack(firstSync.seq)
        try await f.bump()
        _ = try await f.stateFrames()
        f.clock.advance(3.3)
        await f.ack(firstSync.seq)
        let once = FailOnce()
        await f.adapter.setSyncPlanFaultForTesting { try once.fire() }
        try await f.bump()
        #expect(once.didFire)
        #expect(try await f.stateFrames().isEmpty, "the faulted plan sent nothing")
        #expect(await f.adapter.syncLagResyncs == 0, "no resync recorded")
        // The next plan decides again: had the faulted plan recorded its resync, the lag would
        // have restarted and no op 3 follow.
        await f.adapter.syncNow()
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(try await f.stateFrames().map(\.op) == [3])
        #expect(await f.adapter.syncLagResyncs == 1)
    }

    @Test("A newer join of the player supersedes the tracked session: its lag state goes, the new one is tracked")
    func supersedeRemovesLagState() async throws {
        let f = try await makeFixture()
        #expect(await f.adapter.syncLagTrackedSessionCount == 1)
        let newer = SessionID("sess-lag-new")
        await f.adapter.onConnect(sessionID: newer, clientID: ClientID("cli-lag-new"))
        let joined = try #require(try await f.adapter.performJoin(
            playerSession: PlayerSession(playerID: f.playerID.rawValue, deviceID: "dev", metadata: [:]),
            clientID: ClientID("cli-lag-new"),
            sessionID: newer,
            authInfo: nil
        ))
        await f.adapter.syncStateForNewPlayer(playerID: joined.playerID, sessionID: newer)
        #expect(await f.adapter.waitForOutboundDrain())
        #expect(await f.adapter.supersededSessionCount == 1)
        #expect(await f.adapter.syncLagTrackedSessionCount == 1, "only the newer session")
        await f.ack(1)
        #expect(await f.adapter.syncLagDroppedAcks == 1, "the superseded session's ack")
    }

    @Test("Rebinding a session to another player removes its lag state")
    func rebindRemovesLagState() async throws {
        let f = try await makeFixture()
        #expect(await f.adapter.syncLagTrackedSessionCount == 1)
        await f.adapter.registerSession(sessionID: f.sessionID, clientID: f.clientID, playerID: PlayerID("other"), authInfo: nil)
        #expect(await f.adapter.syncLagTrackedSessionCount == 0)
        await f.ack(1)
        #expect(await f.adapter.syncLagDroppedAcks == 1)
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
