// Tests/SwiftStateTreeTransportTests/TransportAdapterCrossLandBroadcastTests.swift
//
// One `WebSocketTransport` serves every land instance of a land type (`NIOLandHost.register`
// creates one per type; `LandManager` creates one adapter per instance on it). An `.all` server
// event of one land must reach only that land's sessions. In json and opcodeJsonArray the event
// is sent immediately; `.all` used to map to the transport's `.broadcast`, which reaches every
// session on the shared transport, i.e. other lands' players too. Event frames carry no landID,
// so the client cannot tell them apart.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct CrossLandTestState: StateNodeProtocol {
    @Sync(.broadcast) var value: Int = 0
    init() {}
}

@Payload
struct CrossLandEvent: ServerEventPayload {
    let message: String
    init(message: String) {
        self.message = message
    }
}

private actor CrossLandConnection: WebSocketConnection {
    private var frames: [Data] = []
    func send(_ data: Data) async throws { frames.append(data) }
    func close() async throws {}
    func recorded() -> [Data] { frames }
}

private struct CrossLandRoom {
    let adapter: TransportAdapter<CrossLandTestState>
    let session: SessionID
    let connection: CrossLandConnection
}

private func makeRoom(
    _ name: String,
    transport: WebSocketTransport,
    encoding: TransportEncodingConfig,
    playerID: PlayerID? = nil
) async throws -> CrossLandRoom {
    let definition = Land("cross-land", using: CrossLandTestState.self) {
        ServerEvents { Register(CrossLandEvent.self) }
        Rules {}
    }
    let keeper = LandKeeper<CrossLandTestState>(definition: definition, initialState: CrossLandTestState())
    let adapter = TransportAdapter<CrossLandTestState>(
        keeper: keeper,
        transport: transport,
        landID: "cross-land:\(name)",
        encodingConfig: encoding,
        suppressMissingPathHashesWarning: true
    )
    let session = SessionID("cl-session-\(name)")
    let client = ClientID("cl-client-\(name)")
    let connection = CrossLandConnection()
    await transport.handleConnection(sessionID: session, connection: connection)
    await adapter.onConnect(sessionID: session, clientID: client)
    try await simulateRouterJoin(
        adapter: adapter,
        keeper: keeper,
        sessionID: session,
        clientID: client,
        playerID: playerID ?? PlayerID("cl-player-\(name)")
    )
    return CrossLandRoom(adapter: adapter, session: session, connection: connection)
}

private func count(_ marker: String, in frames: [Data]) -> Int {
    frames.filter { $0.range(of: Data(marker.utf8)) != nil }.count
}

private func encodingNamed(_ name: String) -> TransportEncodingConfig {
    switch name {
    case "json": .json
    case "opcodeJsonArray": .opcode
    default: .messagepack
    }
}

/// Waits until land A's session got `marker`, then a little longer for a leaked copy to land.
private func settle(_ marker: String, at room: CrossLandRoom) async throws {
    let deadline = ContinuousClock.now + .seconds(3)
    while count(marker, in: await room.connection.recorded()) == 0, ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try await Task.sleep(for: .milliseconds(100))
}

@Suite("Server events stay inside their land on a shared transport", .timeLimit(.minutes(1)))
struct TransportAdapterCrossLandBroadcastTests {

    @Test(
        "land A's .all event reaches land A's session only",
        arguments: ["json", "opcodeJsonArray", "opcodeMessagePack"]
    )
    func allEventDoesNotLeakToOtherLand(encodingName: String) async throws {
        let encoding = encodingNamed(encodingName)
        // No delegate: the test registers sessions with each adapter itself (the router's job).
        let transport = WebSocketTransport()
        let roomA = try await makeRoom("a-\(encodingName)", transport: transport, encoding: encoding)
        let roomB = try await makeRoom("b-\(encodingName)", transport: transport, encoding: encoding)

        let marker = "cross-land-event-\(encodingName)"
        await roomA.adapter.sendEvent(AnyServerEvent(CrossLandEvent(message: marker)), to: .all)
        // opcodeMessagePack queues events for the next sync cycle.
        await roomA.adapter.syncNow()
        await roomB.adapter.syncNow()

        try await settle(marker, at: roomA)

        let aFrames = await roomA.connection.recorded()
        let bFrames = await roomB.connection.recorded()
        #expect(count(marker, in: aFrames) == 1, "land A's session gets its own event once")
        let leaked = bFrames.filter { $0.range(of: Data(marker.utf8)) != nil }
        #expect(
            leaked.isEmpty,
            "land B's session must not get land A's event; got \(leaked.map { String(decoding: $0, as: UTF8.self) })"
        )
    }

    @Test(
        "land A's .player event reaches land A's session only, when both lands have that player ID",
        arguments: ["json", "opcodeJsonArray", "opcodeMessagePack"]
    )
    func playerEventDoesNotLeakToOtherLand(encodingName: String) async throws {
        let encoding = encodingNamed(encodingName)
        let transport = WebSocketTransport()
        let shared = PlayerID("cl-player-shared-\(encodingName)")
        let roomA = try await makeRoom("pa-\(encodingName)", transport: transport, encoding: encoding, playerID: shared)
        let roomB = try await makeRoom("pb-\(encodingName)", transport: transport, encoding: encoding, playerID: shared)

        let marker = "cross-land-player-event-\(encodingName)"
        await roomA.adapter.sendEvent(AnyServerEvent(CrossLandEvent(message: marker)), to: .player(shared))
        await roomA.adapter.syncNow()
        await roomB.adapter.syncNow()
        try await settle(marker, at: roomA)

        let aFrames = await roomA.connection.recorded()
        let bFrames = await roomB.connection.recorded()
        #expect(count(marker, in: aFrames) == 1, "land A's session gets its own event once")
        let leaked = bFrames.filter { $0.range(of: Data(marker.utf8)) != nil }
        #expect(
            leaked.isEmpty,
            "land B's session must not get land A's event; got \(leaked.map { String(decoding: $0, as: UTF8.self) })"
        )
    }
}
