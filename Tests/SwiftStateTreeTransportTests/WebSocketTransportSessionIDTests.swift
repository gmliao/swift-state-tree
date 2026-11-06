// Tests/SwiftStateTreeTransportTests/WebSocketTransportSessionIDTests.swift
//
// One SessionID per connection (#69, join PR 4c): `handleConnection` rejects an ID the transport
// still holds (connected, being disconnected, or closed by the server and unconfirmed), and a
// closing frame is handed to the connection before the close (`closeSessionAfterQueuedFrames`).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

/// Records sends and the close in order; a send can be stalled on a gate.
private actor OrderedConnection: WebSocketConnection {
    enum Entry: Equatable {
        case frame(String)
        case close
    }

    private(set) var entries: [Entry] = []
    private var stall: TestGate?

    func setStall(_ gate: TestGate?) { stall = gate }

    func send(_ data: Data) async throws {
        if let stall { await stall.arrive() }
        entries.append(.frame(String(decoding: data, as: UTF8.self)))
    }

    func close() async throws { entries.append(.close) }
}

/// A delegate whose `onDisconnect` can be held, to keep a disconnect in progress.
private final class HoldingDelegate: TransportDelegate, @unchecked Sendable {
    let disconnectGate = TestGate()
    private let lock = NSLock()
    private var holdDisconnect = false
    private(set) var connects = 0

    func setHoldDisconnect(_ hold: Bool) { lock.withLock { holdDisconnect = hold } }

    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {
        lock.withLock { connects += 1 }
    }

    func onDisconnect(sessionID: SessionID, clientID: ClientID) async {
        if lock.withLock({ holdDisconnect }) { await disconnectGate.arrive() }
    }

    func onMessage(_ message: Data, from sessionID: SessionID) async {}
}

private func orderedPoll(_ condition: () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(5)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await safeTaskSleep(for: .milliseconds(5))
    }
    return await condition()
}

@Suite("WebSocketTransport: one SessionID per connection, and final frames before the close")
struct WebSocketTransportSessionIDTests {
    @Test("A connection whose SessionID is connected is rejected and closed, with no onConnect")
    func connectedIDIsRejected() async {
        let transport = WebSocketTransport()
        let delegate = HoldingDelegate()
        await transport.setDelegate(delegate)
        let id = SessionID("held")
        let first = OrderedConnection(), second = OrderedConnection()
        #expect(await transport.handleConnection(sessionID: id, connection: first) == .accepted)
        #expect(await transport.handleConnection(sessionID: id, connection: second) == .rejected(.sessionIDInUse))
        #expect(await second.entries == [.close])
        #expect(await first.entries.isEmpty, "the holder is untouched")
        #expect(delegate.connects == 1)
        #expect(await transport.connectionsRejectedSessionIDInUse == 1)
    }

    @Test("A SessionID is held while its disconnect runs, the delegate's cleanup included (#216)")
    func closingIDIsRejected() async {
        let transport = WebSocketTransport()
        let delegate = HoldingDelegate()
        await transport.setDelegate(delegate)
        let id = SessionID("closing")
        await transport.handleConnection(sessionID: id, connection: OrderedConnection())
        delegate.setHoldDisconnect(true)
        let disconnect = Task { await transport.handleDisconnection(sessionID: id) }
        #expect(await delegate.disconnectGate.waitForArrivals(1))
        // The queue is gone, the delegate is still cleaning up: the ID is still held.
        let late = OrderedConnection()
        #expect(await transport.handleConnection(sessionID: id, connection: late) == .rejected(.sessionIDInUse))
        delegate.disconnectGate.open()
        await disconnect.value
        // Fully gone: a fresh connection is accepted.
        #expect(await transport.handleConnection(sessionID: id, connection: OrderedConnection()) == .accepted)
    }

    @Test("A SessionID the server closed is held until its disconnect callback confirms it")
    func serverClosedIDIsRejected() async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("server-closed")
        await transport.handleConnection(sessionID: id, connection: OrderedConnection())
        await transport.closeSession(id)
        #expect(await transport.handleConnection(sessionID: id, connection: OrderedConnection()) == .rejected(.sessionIDInUse))
        // The server's own disconnect callback confirms the close; then the ID is free.
        await transport.handleDisconnection(sessionID: id)
        #expect(await transport.handleConnection(sessionID: id, connection: OrderedConnection()) == .accepted)
    }

    @Test("closeSessionAfterQueuedFrames hands every queued frame over before the close; later frames are dropped")
    func finalFrameThenClose() async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("final")
        let connection = OrderedConnection()
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        let frame = { (text: String) in SessionFrame(data: Data(text.utf8), sessionID: id, connectionGeneration: generation) }
        await transport.sendSessionFrames([frame("one"), frame("error")])
        await transport.closeSessionAfterQueuedFrames(id, timeout: .seconds(5))
        await transport.sendSessionFrames([frame("after")])
        #expect(await orderedPoll { await connection.entries.contains(.close) })
        #expect(await connection.entries == [.frame("one"), .frame("error"), .close])
        #expect(await transport.framesDroppedAfterCloseMarker == 1)
    }

    @Test("Called on the concrete type from async code, the one-argument close still waits for the queued frames")
    func concreteCallerGetsTheQueuedClose() async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("concrete")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        await transport.sendSessionFrames([SessionFrame(data: Data("error".utf8), sessionID: id, connectionGeneration: generation)])
        #expect(await stall.waitForArrivals(1))
        // The drain is held writing the frame: a close that doesn't queue behind it would
        // reach the connection first.
        await transport.closeSessionAfterQueuedFrames(id)
        stall.open()
        #expect(await orderedPoll { await connection.entries.contains(.close) })
        #expect(await connection.entries == [.frame("error"), .close])
    }

    @Test("A client that stopped reading is closed after the timeout; the close happens once")
    func stalledClientIsClosedAfterTimeout() async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("stalled")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        await transport.sendSessionFrames([SessionFrame(data: Data("error".utf8), sessionID: id, connectionGeneration: generation)])
        #expect(await stall.waitForArrivals(1))
        await transport.closeSessionAfterQueuedFrames(id, timeout: .milliseconds(50))
        // The timer closes the session although the frame is still being written: on NIO the
        // guarantee is the handoff order, not delivery to a stalled client.
        #expect(await orderedPoll { await connection.entries.contains(.close) })
        stall.open()
        // The stalled send finishes after the close; the marker's own close doesn't run again.
        #expect(await orderedPoll { await connection.entries.contains(.frame("error")) })
        #expect(await connection.entries.filter { $0 == .close }.count == 1)
    }
}
