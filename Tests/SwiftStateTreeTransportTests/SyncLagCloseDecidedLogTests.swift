// Tests/SwiftStateTreeTransportTests/SyncLagCloseDecidedLogTests.swift
//
// The adapter's `syncLagCloseDecided` lifecycle line (#490): written once per decision, in the
// segment that decides it, next to the counters, whether or not the close then reaches the
// connection. The close is held at `.syncLagClose` while the connection goes away or is replaced,
// so the interleaving is forced, not timed.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

/// A connection that records the closes asked of it and hands each frame to `sent`, as it
/// arrives (the transport drains frames on its own task).
fileprivate actor RecordingCloseConnection: WebSocketConnection {
    private(set) var closes: [SessionClose?] = []
    nonisolated let sent: AsyncStream<Data>
    private let continuation: AsyncStream<Data>.Continuation
    init() { (sent, continuation) = AsyncStream.makeStream(of: Data.self) }
    func send(_ data: Data) async throws { continuation.yield(data) }
    func close() async throws { closes.append(nil) }
    func close(with close: SessionClose) async throws { closes.append(close) }
}

/// Lifecycle lines kept in memory (the sync-lag suites read the decision lines).
final class LifecycleLines: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private(set) lazy var log = LandLifecycleLog(write: { [unowned self] line in
        self.lock.lock()
        self.stored.append(line)
        self.lock.unlock()
    })

    var records: [SessionLifecycleRecord] {
        lock.lock()
        defer { lock.unlock() }
        return stored.compactMap { try? JSONDecoder().decode(SessionLifecycleRecord.self, from: Data($0.utf8)) }
            .filter { $0.event == .syncLagCloseDecided }
    }

    var rawLines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}

@Suite("Sync lag: the syncLagCloseDecided line (#490)", .timeLimit(.minutes(1)))
struct SyncLagCloseDecidedLogTests {
    fileprivate struct Fixture {
        let adapter: TransportAdapter<SyncLagTestState>
        let keeper: LandKeeper<SyncLagTestState>
        let transport: WebSocketTransport
        let connection: RecordingCloseConnection
        let clock: SyncLagManualClock
        let lines: LifecycleLines
        let sessionID = SessionID("sess-decided")
        let clientID = ClientID("cli-decided")
        let playerID = PlayerID("player-decided")

        /// Changes the state, then syncs and waits for the frames to reach the connection.
        func bump() async throws {
            let envelope = ActionEnvelope(
                typeIdentifier: String(describing: SyncLagIncrementAction.self),
                payload: AnyCodable(SyncLagIncrementAction())
            )
            _ = try await keeper.handleActionEnvelope(envelope, playerID: playerID, clientID: clientID, sessionID: sessionID)
            await adapter.syncNow()
            #expect(await adapter.waitForOutboundDrain())
        }

        /// The sequence of the first state-update frame the connection receives, awaited as it
        /// arrives.
        func firstSyncSequence() async throws -> UInt64 {
            for await data in connection.sent {
                guard let array = try JSONSerialization.jsonObject(with: data) as? [Any],
                      let op = array.first as? Int, (1...3).contains(op), array.count > 1,
                      let seq = SyncAckFrame.syncSequence(array[1]) else { continue }
                return seq
            }
            throw FixtureError.noStateFrame
        }

        /// Acks the firstSync, changes the state, then lets 10.5 s pass with no further ack:
        /// the next sync decides an unresponsive close (4011) and holds it at `.syncLagClose`.
        func decideUnresponsiveClose(gate: TestGate) async throws {
            await adapter.onMessage(SyncAckFrame.encode(seq: try await firstSyncSequence(), binary: false), from: sessionID)
            try await bump()
            clock.advance(10.5)
            try await bump()
            #expect(await gate.waitForArrivals(1), "the close is decided and held")
        }
    }

    enum FixtureError: Error { case noStateFrame }

    fileprivate func makeFixture(gate: TestGate, closed: TestGate) async throws -> Fixture {
        let transport = WebSocketTransport()
        let keeper = LandKeeper<SyncLagTestState>(definition: syncLagTestLand(), initialState: SyncLagTestState())
        let adapter = TransportAdapter<SyncLagTestState>(
            keeper: keeper,
            transport: transport,
            landID: "sync-lag-test",
            encodingConfig: TransportEncodingConfig(message: .json, stateUpdate: .opcodeJsonArray, syncSequence: true),
            inTurnSync: true
        )
        let lines = LifecycleLines()
        await adapter.attachLifecycleLog(lines.log, instance: 1)
        await adapter.installHolds(
            HoldRegistry<TransportAdapterHoldPoint>()
                .on(.syncLagClose) { await gate.arrive() }
                .on(.syncLagClosed) { await closed.arrive() }
                .hook
        )
        let clock = SyncLagManualClock()
        await adapter.setSyncLagClockForTesting { clock.now }
        await adapter.setSyncLagTimerIntervalForTesting(.seconds(3600))
        let connection = RecordingCloseConnection()
        let fixture = Fixture(
            adapter: adapter, keeper: keeper, transport: transport, connection: connection, clock: clock, lines: lines
        )
        // The connection is registered before the adapter is the delegate, so the adapter's
        // connect uses the fixture's client ID.
        #expect(await transport.handleConnection(sessionID: fixture.sessionID, connection: connection) == .accepted)
        await transport.setDelegate(adapter)
        await adapter.onConnect(sessionID: fixture.sessionID, clientID: fixture.clientID)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper,
            sessionID: fixture.sessionID, clientID: fixture.clientID, playerID: fixture.playerID
        )
        return fixture
    }

    @Test("No loss while held: one decision line with the code, the counter counts it, and the close reaches the connection")
    func decisionThenClose() async throws {
        let gate = TestGate()
        let closed = TestGate()
        closed.open()
        let f = try await makeFixture(gate: gate, closed: closed)
        try await f.decideUnresponsiveClose(gate: gate)
        // Written in the deciding segment, before the held close runs.
        #expect(f.lines.records.map(\.code) == [Int(SessionClose.Code.unresponsive)])
        #expect(f.lines.records.first?.sessionID == f.sessionID.rawValue)
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
        #expect(await f.connection.closes.isEmpty)
        gate.open()
        #expect(await closed.waitForArrivals(1))
        #expect(await f.connection.closes.map { $0?.code } == [SessionClose.Code.unresponsive])
        #expect(f.lines.records.count == 1)
    }

    @Test("The connection is lost while the close is held: the decision line and the counter stay, and no close is sent")
    func lossWhileHeld() async throws {
        let gate = TestGate()
        let closed = TestGate()
        closed.open()
        let f = try await makeFixture(gate: gate, closed: closed)
        try await f.decideUnresponsiveClose(gate: gate)
        await f.transport.handleDisconnection(sessionID: f.sessionID)
        gate.open()
        #expect(await closed.waitForArrivals(1))
        #expect(await f.connection.closes.isEmpty, "the transport has no queue for the session: superseded by the loss")
        #expect(f.lines.records.map(\.code) == [Int(SessionClose.Code.unresponsive)])
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
    }

    @Test("A new connection takes the session while the close is held: the close is not sent to it")
    func newGenerationWhileHeld() async throws {
        let gate = TestGate()
        let closed = TestGate()
        closed.open()
        let f = try await makeFixture(gate: gate, closed: closed)
        try await f.decideUnresponsiveClose(gate: gate)
        await f.transport.handleDisconnection(sessionID: f.sessionID)
        let replacement = RecordingCloseConnection()
        #expect(await f.transport.handleConnection(sessionID: f.sessionID, connection: replacement) == .accepted)
        gate.open()
        #expect(await closed.waitForArrivals(1))
        #expect(await replacement.closes.isEmpty, "the close carries the old connection's generation")
        #expect(await f.connection.closes.isEmpty)
        #expect(f.lines.records.count == 1)
        #expect(await f.adapter.syncLagUnresponsiveCloses == 1)
    }

    @Test("The decision line has exactly the fields the analysis reads: event, sessionID, code, wallMs (and uptimeNs)")
    func decisionLineFields() async throws {
        let gate = TestGate()
        let closed = TestGate()
        closed.open()
        let f = try await makeFixture(gate: gate, closed: closed)
        try await f.decideUnresponsiveClose(gate: gate)
        gate.open()
        let line = try #require(f.lines.rawLines.first { $0.contains("syncLagCloseDecided") })
        let object = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(Set(object.keys) == ["event", "sessionID", "code", "wallMs", "uptimeNs"])
        #expect(object["code"] as? Int == Int(SessionClose.Code.unresponsive))
    }
}
