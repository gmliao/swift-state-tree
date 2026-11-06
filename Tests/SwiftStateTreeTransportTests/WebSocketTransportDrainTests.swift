// Tests/SwiftStateTreeTransportTests/WebSocketTransportDrainTests.swift
//
// The per-session drain task (#61): after a failed send the drain task ends and releases its
// stream, so later frames are dropped (and now counted), not buffered until the disconnect.

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
}
