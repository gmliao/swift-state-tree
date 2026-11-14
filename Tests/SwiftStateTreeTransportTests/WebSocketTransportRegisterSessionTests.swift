// Tests for #549: `WebSocketTransport.registerSession` doesn't map a session that isn't connected.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

private struct RegisterTestConnection: WebSocketConnection {
    func send(_ data: Data) async throws {}
    func close() async throws {}
}

/// A delegate whose `onDisconnect` waits at a gate: the disconnect cleanup has run (the queue
/// and the player mapping are gone) while the session ID is still held.
private final class HeldDisconnectDelegate: TransportDelegate, @unchecked Sendable {
    let gate = TestGate()
    func onConnect(sessionID: SessionID, clientID: ClientID, authInfo: AuthenticatedInfo?) async {}
    func onDisconnect(sessionID: SessionID, clientID: ClientID) async { await gate.arrive() }
    func onMessage(_ message: Data, from sessionID: SessionID) async {}
}

@Suite("WebSocketTransport.registerSession maps only a connected session (#549)", .timeLimit(.minutes(1)))
struct WebSocketTransportRegisterSessionTests {
    private let player = PlayerID("p1")

    @Test("a connected session is mapped and gets its generation")
    func connectedSessionIsMapped() async {
        let transport = WebSocketTransport()
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: RegisterTestConnection())
        #expect(await transport.registerSession(session, for: player) != nil)
        #expect(await transport.playerSessionsForTesting(player) == [session])
    }

    @Test("a registration after the disconnect cleanup maps nothing and returns nil")
    func registrationAfterTheCleanupMapsNothing() async {
        let transport = WebSocketTransport()
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: RegisterTestConnection())
        await transport.handleDisconnection(sessionID: session)
        #expect(await transport.registerSession(session, for: player) == nil)
        #expect(await transport.playerSessionsForTesting(player).isEmpty)
    }

    @Test("a registration while the disconnect's delegate call is held maps nothing, and nothing is left after it")
    func registrationDuringTheHeldDisconnectMapsNothing() async {
        let transport = WebSocketTransport()
        let delegate = HeldDisconnectDelegate()
        await transport.setDelegate(delegate)
        let session = SessionID("s1")
        _ = await transport.handleConnection(sessionID: session, connection: RegisterTestConnection())
        let disconnect = Task { await transport.handleDisconnection(sessionID: session) }
        // The cleanup ran; the session ID is still held (`closingSessions`) until the call returns.
        #expect(await delegate.gate.waitForArrivals(1))
        #expect(await transport.registerSession(session, for: player) == nil)
        delegate.gate.open()
        await disconnect.value
        #expect(await transport.playerSessionsForTesting(player).isEmpty, "no mapping outlives the session")
    }

    @Test("a session that never connected is not mapped")
    func unknownSessionIsNotMapped() async {
        let transport = WebSocketTransport()
        #expect(await transport.registerSession(SessionID("never"), for: player) == nil)
        #expect(await transport.playerSessionsForTesting(player).isEmpty)
    }
}
