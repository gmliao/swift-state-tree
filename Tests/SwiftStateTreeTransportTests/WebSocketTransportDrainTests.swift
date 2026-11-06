// Tests/SwiftStateTreeTransportTests/WebSocketTransportDrainTests.swift
//
// The per-session drain task (#61): after a failed send the drain task ends and releases its
// stream, so later frames are dropped (and now counted), not buffered until the disconnect; and a
// reused SessionID ends the previous queue's stream and drain task instead of leaking them
// (a behaviour change: the old queue's undelivered frames are dropped). The old drain task
// touches only its own stream, never the queue table by key, so finishing it after the reuse
// leaves the new queue alone.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Every send fails.
private actor FailingConnection: WebSocketConnection {
    private(set) var sends = 0
    func send(_ data: Data) async throws {
        sends += 1
        throw CancellationError()
    }
    func close() async throws {}
}

/// Each send arrives at `gate`, then fails (`fails`) or records its bytes.
private actor GatedConnection: WebSocketConnection {
    let gate: TestGate
    let fails: Bool
    private(set) var received: [Data] = []
    init(gate: TestGate, fails: Bool) { self.gate = gate; self.fails = fails }
    func send(_ data: Data) async throws {
        await gate.arrive()
        if fails { throw CancellationError() }
        received.append(data)
    }
    func close() async throws {}
}

private actor SilentConnection: WebSocketConnection {
    func send(_ data: Data) async throws {}
    func close() async throws {}
}

@Suite("WebSocketTransport drain task (#61)")
struct WebSocketTransportDrainTests {
    @Test("After a failed send, later frames are dropped and counted, not buffered")
    func framesAfterSendFailureAreDropped() async throws {
        let transport = WebSocketTransport()
        let connection = FailingConnection()
        let session = SessionID("s1")
        await transport.handleConnection(sessionID: session, connection: connection)
        let drain = try #require(await transport.sendQueueDrainTaskForTesting(session))

        await transport.send(Data([1]), to: .session(session))
        await drain.value  // the drain task ended at its failed send

        await transport.send(Data([2]), to: .session(session))
        await transport.sendBatch([(Data([3]), .session(session))])
        #expect(await transport.framesDroppedAfterSendFailure == 2)
        #expect(await connection.sends == 1)
    }

    @Test("A reused SessionID ends the previous queue's drain task")
    func reusedSessionIDEndsPreviousDrain() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("s1")
        await transport.handleConnection(sessionID: session, connection: SilentConnection())
        let previous = try #require(await transport.sendQueueDrainTaskForTesting(session))

        await transport.handleConnection(sessionID: session, connection: SilentConnection())
        #expect(previous.isCancelled)
        // Its stream was finished, so the drain loop ends. Without the fix it never would: only
        // await it when the cancel check passed, so a regression fails instead of hanging.
        if previous.isCancelled { await previous.value }
        let current = try #require(await transport.sendQueueDrainTaskForTesting(session))
        #expect(!current.isCancelled)
    }

    @Test("The replaced queue's drain, failing after the SessionID was reused, leaves the new queue alone")
    func replacedDrainFailureLeavesNewQueue() async throws {
        let transport = WebSocketTransport()
        let session = SessionID("s1")
        // The old connection's send is held inside the connection, then fails.
        let oldGate = TestGate()
        await transport.handleConnection(sessionID: session, connection: GatedConnection(gate: oldGate, fails: true))
        let old = try #require(await transport.sendQueueDrainTaskForTesting(session))
        await transport.send(Data([1]), to: .session(session))
        #expect(await oldGate.waitForArrivals(1))

        // The SessionID is reused while the old send is in flight.
        let newGate = TestGate()
        newGate.open()
        let newConnection = GatedConnection(gate: newGate, fails: false)
        await transport.handleConnection(sessionID: session, connection: newConnection)

        // The old send fails now: its drain finishes only its own stream and ends.
        oldGate.open()
        await old.value

        // The new queue still delivers, and nothing was counted as dropped.
        await transport.send(Data([2]), to: .session(session))
        #expect(await newGate.waitForArrivals(1))
        #expect(await newConnection.received == [Data([2])])
        #expect(await transport.framesDroppedAfterSendFailure == 0)
        let current = try #require(await transport.sendQueueDrainTaskForTesting(session))
        #expect(!current.isCancelled)
    }
}
