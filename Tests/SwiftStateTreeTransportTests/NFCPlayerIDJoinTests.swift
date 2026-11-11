// A player ID given in another spelling (NFD) is the same player, with the same bytes everywhere
// a client sees it (#446).

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

@StateNodeBuilder
private struct NFCJoinState: StateNodeProtocol {
    @Sync(.broadcast) var joined: [PlayerID: Int] = [:]
    @Sync(.broadcast) var last: PlayerID? = nil
    init() {}
}

private actor NFCJoinTransport: Transport {
    var delegate: TransportDelegate?
    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) {}
}

@Test("A join under the NFD spelling of an ID is the NFC player: one ID, one slot, one state key")
func nfdPlayerIDJoinsAsNFC() async throws {
    let nfc = "\u{E9}-player", nfd = "e\u{301}-player"
    let definition = Land("nfc-join-test", using: NFCJoinState.self) {
        Rules {
            OnJoin { (state: inout NFCJoinState, ctx: LandContext) in
                state.joined[ctx.playerID, default: 0] += 1
                state.last = ctx.playerID
            }
        }
    }
    let transport = NFCJoinTransport()
    let keeper = LandKeeper<NFCJoinState>(definition: definition, initialState: NFCJoinState())
    let adapter = TransportAdapter<NFCJoinState>(keeper: keeper, transport: transport, landID: "nfc-join-test")
    await transport.setDelegate(adapter)

    // The session carries the spelling the client sent; the keeper makes the ID from it.
    let decision = try await keeper.join(
        session: PlayerSession(playerID: nfd, deviceID: "d1", metadata: [:]),
        clientID: ClientID("c1"),
        sessionID: SessionID("s1"),
        services: LandServices()
    )
    guard case .allow(let playerID) = decision else {
        Issue.record("join denied")
        return
    }
    // The join response is built from this ID, so the client is told the NFC spelling.
    #expect(Array(playerID.rawValue.utf8) == Array(nfc.utf8))

    await adapter.registerSession(sessionID: SessionID("s1"), clientID: ClientID("c1"), playerID: playerID, authInfo: nil)
    let slot = await adapter.allocatePlayerSlot(accountKey: playerID.rawValue, for: playerID)
    // The slot is hashed from the stored bytes: either spelling of the ID gets the same one.
    #expect(await adapter.getPlayerSlot(for: PlayerID(nfc)) == slot)
    #expect(await adapter.getPlayerSlot(for: PlayerID(nfd)) == slot)
    #expect(await adapter.getPlayerID(for: slot).map { Array($0.rawValue.utf8) } == Array(nfc.utf8))
    #expect(await adapter.getPlayerID(for: SessionID("s1")).map { Array($0.rawValue.utf8) } == Array(nfc.utf8))

    let state = await keeper.currentState()
    #expect(state.joined.keys.map { Array($0.rawValue.utf8) } == [Array(nfc.utf8)])
    #expect(state.last.map { Array($0.rawValue.utf8) } == Array(nfc.utf8))
    let snapshot = try state.snapshot(for: nil, dirtyFields: nil).values
    guard case .object(let joined)? = snapshot["joined"], case .string(let last)? = snapshot["last"] else {
        Issue.record("unexpected snapshot \(snapshot)")
        return
    }
    #expect(joined.keys.map { Array($0.utf8) } == [Array(nfc.utf8)])
    #expect(Array(last.utf8) == Array(nfc.utf8))

    // A fresh adapter given the NFC spelling allocates the same slot: no slot moves for an ID
    // that was NFC already, and the two spellings agree.
    let other = TransportAdapter<NFCJoinState>(keeper: keeper, transport: transport, landID: "nfc-join-test-2")
    #expect(await other.allocatePlayerSlot(accountKey: PlayerID(nfc).rawValue, for: PlayerID(nfc)) == slot)
}
