// Tests/SwiftStateTreeTransportTests/WebSocketTransportSessionIDTests.swift
//
// One SessionID per connection (#69, join PR 4c): `handleConnection` rejects an ID the transport
// still holds (connected, being disconnected, or closed by the server and unconfirmed), and a
// closing frame is handed to the connection before the close (`closeSessionAfterQueuedFrames`).

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeTestSupport

/// Records sends and the close in order; a send can be stalled on a gate, and each send and close
/// can signal a gate once recorded, so a test waits for the event instead of polling for it.
private actor OrderedConnection: WebSocketConnection {
    enum Entry: Equatable {
        case frame(String)
        case close
    }

    private(set) var entries: [Entry] = []
    private var stall: TestGate?
    private var closeSignal: TestGate?
    private var sendSignal: TestGate?

    func setStall(_ gate: TestGate?) { stall = gate }
    /// `gate` gets an arrival for each recorded send.
    func setSendSignal(_ gate: TestGate?) { sendSignal = gate }
    /// `gate` gets an arrival for each close.
    func setCloseSignal(_ gate: TestGate?) { closeSignal = gate }

    func send(_ data: Data, kind: WebSocketFrameKind) async throws {
        if let stall { await stall.arrive() }
        entries.append(.frame(String(decoding: data, as: UTF8.self)))
        if let sendSignal { await sendSignal.arrive() }
    }

    func close() async throws {
        entries.append(.close)
        if let closeSignal { await closeSignal.arrive() }
    }
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

/// An open gate that counts `connection`'s closes.
/// Arrives each time a close marker's close has run (`.didRun(.marker)`); never holds it.
private func markerCloseSignal(on transport: WebSocketTransport) async -> TestGate {
    let gate = TestGate()
    gate.open()
    await transport.setDelayedCloseForTesting { stage in
        if case .didRun(.marker) = stage { await gate.arrive() }
    }
    return gate
}

private func closeSignal(on connection: OrderedConnection) async -> TestGate {
    let gate = TestGate()
    gate.open()
    await connection.setCloseSignal(gate)
    return gate
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

    /// `waitsForBound`: the close's bound runs out while the first frame's send is held, the
    /// interleaving that failed on a loaded runner (#488); it is held, so the frames still go first.
    @Test("closeSessionAfterQueuedFrames hands every queued frame over before the close; later frames are dropped", arguments: [false, true])
    func finalFrameThenClose(waitsForBound: Bool) async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("final")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        let closed = await closeSignal(on: connection)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        let frame = { (text: String) in SessionFrame(data: Data(text.utf8), sessionID: id, connectionGeneration: generation) }
        await transport.sendSessionFrames([frame("one"), frame("error")])
        // The drain is held writing the first frame, so the close queues behind both frames.
        #expect(await stall.waitForArrivals(1))
        // The close's bound is held: only the queue's order can close the session (#488). Its
        // length doesn't matter then; a short one lets the bound run out at once.
        let bound = await transport.holdBoundClosesForTesting()
        defer { bound.open() }
        await transport.closeSessionAfterQueuedFrames(id, timeout: .milliseconds(1))
        await transport.sendSessionFrames([frame("after")])
        if waitsForBound {
            #expect(await bound.waitForArrivals(1), "the bound ran out")
        }
        stall.open()
        #expect(await closed.waitForArrivals(1), "the session was closed")
        let entries = await connection.entries
        #expect(entries == [.frame("one"), .frame("error"), .close], "entries: \(entries)")
        #expect(await transport.framesDroppedAfterCloseMarker == 1)
    }

    /// `waitsForBound`: the close's bound runs out while the send is held (#647); it is held, so the order is the same.
    @Test("Called on the concrete type from async code, the one-argument close still waits for the queued frames", arguments: [false, true])
    func concreteCallerGetsTheQueuedClose(waitsForBound: Bool) async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("concrete")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        let closed = await closeSignal(on: connection)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        await transport.sendSessionFrames([SessionFrame(data: Data("error".utf8), sessionID: id, connectionGeneration: generation)])
        #expect(await stall.waitForArrivals(1))
        // The default 1 s bound is held, so only the queue's order can close first (#647).
        let bound = await transport.holdBoundClosesForTesting()
        defer { bound.open() }
        // The drain is held writing the frame: a close that doesn't queue behind it would
        // reach the connection first.
        await transport.closeSessionAfterQueuedFrames(id)
        if waitsForBound {
            #expect(await bound.waitForArrivals(1), "the bound ran out")
        }
        stall.open()
        #expect(await closed.waitForArrivals(1), "the session was closed")
        #expect(await connection.entries == [.frame("error"), .close])
    }

    @Test("A client that stopped reading is closed after the timeout; the close happens once")
    func stalledClientIsClosedAfterTimeout() async throws {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("stalled")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        let closed = await closeSignal(on: connection)
        let sent = TestGate()
        sent.open()
        await connection.setSendSignal(sent)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        await transport.sendSessionFrames([SessionFrame(data: Data("error".utf8), sessionID: id, connectionGeneration: generation)])
        #expect(await stall.waitForArrivals(1))
        let markerClose = await markerCloseSignal(on: transport)
        // Taken before the close removes the queue.
        let drainEnd = try #require(await transport.drainEndForTesting(id))
        await transport.closeSessionAfterQueuedFrames(id, timeout: .milliseconds(50))
        // The timer closes the session although the frame is still being written: on NIO the
        // guarantee is the handoff order, not delivery to a stalled client.
        #expect(await closed.waitForArrivals(1), "the timer closed the session")
        stall.open()
        #expect(await sent.waitForArrivals(1), "the stalled send finished")
        // The stalled send finishes after the close; the marker's own close doesn't run again.
        // Counted once the drain has ended and, if it read the marker, once the marker's close
        // has run (#663).
        let end = await drainEnd.value
        #expect(end != .sendFailed)
        if end == .closeMarker {
            #expect(await markerClose.waitForArrivals(1), "the marker's close ran")
        }
        #expect(await connection.entries.filter { $0 == .close }.count == 1, "\(end)")
    }

    /// `disconnected`: the client disconnects while the drain is held in a send, before any close
    /// marker, so the drain ends with its stream. Otherwise the close queues its marker behind the
    /// frame and the drain reaches it. (A bound that closes the session while the drain is held
    /// still leaves the marker in the stream: the drain reads it once the send returns.)
    @Test("drainEndForTesting names how the drain ended: at its close marker, or with its stream (#663)", arguments: [false, true])
    func drainEndNamesBothEnds(disconnected: Bool) async throws {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("drain-end")
        let connection = OrderedConnection()
        let stall = TestGate()
        await connection.setStall(stall)
        await transport.handleConnection(sessionID: id, connection: connection)
        let generation = await transport.connectionGeneration(for: id)
        await transport.sendSessionFrames([SessionFrame(data: Data("error".utf8), sessionID: id, connectionGeneration: generation)])
        #expect(await stall.waitForArrivals(1))
        let markerClose = await markerCloseSignal(on: transport)
        let drainEnd = try #require(await transport.drainEndForTesting(id))
        if disconnected {
            await transport.handleDisconnection(sessionID: id)
        } else {
            // The bound is past the test: only the marker closes.
            await transport.closeSessionAfterQueuedFrames(id, timeout: .seconds(3600))
        }
        stall.open()
        let end = await drainEnd.value
        #expect(end == (disconnected ? .streamEnded : .closeMarker), "\(end)")
        if end == .closeMarker {
            #expect(await markerClose.waitForArrivals(1), "the marker's close ran")
        }
        #expect(await connection.entries.filter { $0 == .close }.count == (disconnected ? 0 : 1), "\(end)")
    }

    @Test("A queued close for an older connection leaves the connection that reuses the ID open (#531)", arguments: [false, true])
    func queuedCloseForOlderConnectionIsDropped(waitsForBound: Bool) async {
        let transport = WebSocketTransport()
        await transport.setDelegate(HoldingDelegate())
        let id = SessionID("reused")
        await transport.handleConnection(sessionID: id, connection: OrderedConnection())
        let older = await transport.connectionGeneration(for: id)
        await transport.handleDisconnection(sessionID: id)
        let connection = OrderedConnection()
        #expect(await transport.handleConnection(sessionID: id, connection: connection) == .accepted)
        let current = await transport.connectionGeneration(for: id)
        #expect(older != current)

        let closed = await closeSignal(on: connection)
        let stall = TestGate()
        await connection.setStall(stall)
        // The current close's bound is held: only the queue's order can close the session (#488).
        let bound = await transport.holdBoundClosesForTesting()
        defer { bound.open() }

        // The older connection's close does nothing; had it queued a close marker, the frame
        // after it would be dropped and the close would come first.
        await transport.closeSessionAfterQueuedFrames(id, timeout: .milliseconds(1), generation: older)
        await transport.sendSessionFrames([SessionFrame(data: Data("after".utf8), sessionID: id, connectionGeneration: current)])
        #expect(await stall.waitForArrivals(1))
        await transport.closeSessionAfterQueuedFrames(id, timeout: .milliseconds(1), generation: current)
        if waitsForBound {
            #expect(await bound.waitForArrivals(1), "the bound ran out")
        }
        stall.open()
        #expect(await closed.waitForArrivals(1), "the session was closed")
        #expect(await connection.entries == [.frame("after"), .close])
        #expect(await transport.framesDroppedAfterCloseMarker == 0)
    }
}
