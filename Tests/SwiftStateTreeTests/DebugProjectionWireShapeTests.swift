// Tests/SwiftStateTreeTests/DebugProjectionWireShapeTests.swift
//
// The debug projection must carry values in the same shape as the state wire, so a client's
// reconstructed state can be compared with it directly; fixed-point types stay raw integers (#79).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@StateNodeBuilder
struct DebugProjectionWireShapeState: StateNodeProtocol {
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 1.5, y: -0.25)

    public init() {}
}

private actor WireShapeRecordingTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var sent: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {
        sent.append(message)
    }
}

@Test("Debug projection carries Position2 in the state-wire shape (raw fixed-point integers)")
func debugProjectionUsesWireShapeForFixedPoint() async throws {
    let definition = Land("debug-projection-wire-shape", using: DebugProjectionWireShapeState.self) {
        Rules {}
    }
    let keeper = LandKeeper<DebugProjectionWireShapeState>(
        definition: definition,
        initialState: DebugProjectionWireShapeState()
    )
    let transport = WireShapeRecordingTransport()
    let adapter = TransportAdapter<DebugProjectionWireShapeState>(
        keeper: keeper,
        transport: transport,
        landID: "debug-projection-wire-shape"
    )
    await transport.setDelegate(adapter)
    await keeper.setTransport(adapter)

    let session = SessionID("s1")
    let client = ClientID("c1")
    let player = PlayerID("p1")
    await adapter.onConnect(sessionID: session, clientID: client)
    _ = try await adapter.performJoin(
        playerSession: PlayerSession(playerID: player.rawValue),
        clientID: client,
        sessionID: session,
        authInfo: nil
    )
    // As the router does after the join response: the joiner's firstSync.
    await adapter.syncStateForNewPlayer(playerID: player, sessionID: session)
    #expect(await adapter.waitForOutboundDrain(), "outbound writer did not drain")

    // The value the state wire carried for `position` in the joiner's firstSync.
    let decoder = JSONStateUpdateDecoder()
    let wirePatches: [StatePatch] = await transport.sent.compactMap { try? decoder.decode(data: $0).update }
        .flatMap { update -> [StatePatch] in
            switch update {
            case .firstSync(let patches), .diff(let patches): return patches
            case .noChange: return []
            }
        }
    let wireValue = wirePatches.first { $0.path == "/position" }.flatMap { patch -> SnapshotValue? in
        if case .set(let value) = patch.operation { return value }
        return nil
    }
    let wire = try #require(wireValue, "state wire did not carry /position")

    let freeze = try await adapter.debugFreeze()
    let projection = try await adapter.debugProjection(playerID: player)
    #expect(projection.state["position"] == wire)

    // Encoded DTO: fixed-point stays integer, nested as the wire nests it.
    let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(projection)) as? [String: Any]
    let position = (json?["state"] as? [String: Any])?["position"] as? [String: Any]
    let vector = position?["v"] as? [String: Any]
    #expect(vector?["x"] as? Int == 1500)
    #expect(vector?["y"] as? Int == -250)

    _ = await adapter.debugResume(freezeToken: freeze.freezeToken)
}
