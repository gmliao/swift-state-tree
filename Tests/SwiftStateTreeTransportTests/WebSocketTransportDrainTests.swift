// Tests/SwiftStateTreeTransportTests/WebSocketTransportDrainTests.swift
//
// The per-session drain task (#61): after a failed send, the session's stream is finished, so
// later frames are dropped and counted instead of buffering until the disconnect; and a
// reused SessionID ends the previous queue's stream and drain task instead of leaking them.

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
}
