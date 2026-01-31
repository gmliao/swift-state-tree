import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport

@Test("Broadcast scope does not reuse per-player dynamic keys")
func testBroadcastScopeUsesSharedKeyTable() throws {
    let pathHasher = PathHasher(pathHashes: ["monsters.*.hp": 123])
    let encoder = OpcodeJSONStateUpdateEncoder(pathHasher: pathHasher)
    let landID = "land-1"
    let playerA = PlayerID("player-a")
    let perPlayerUpdateA = StateUpdate.diff([
        StatePatch(path: "/monsters/dragon/hp", operation: .set(.int(1)))
    ])
    _ = try encoder.encode(
        update: perPlayerUpdateA,
        landID: landID,
        playerID: playerA,
        playerSlot: nil,
        scope: .perPlayer
    )

    let broadcastUpdate = StateUpdate.diff([
        StatePatch(path: "/monsters/dragon/hp", operation: .set(.int(2)))
    ])
    let data = try encoder.encode(
        update: broadcastUpdate,
        landID: landID,
        playerID: playerA,
        playerSlot: nil,
        scope: .broadcast
    )

    let json = try JSONSerialization.jsonObject(with: data) as? [Any]
    guard let patch = json?[1] as? [Any], patch.count > 1 else {
        Issue.record("Expected patch entry in broadcast update")
        return
    }
    let dynamicKey = patch[1]

    if let dynamicKeyArray = dynamicKey as? [Any], dynamicKeyArray.count > 1 {
        #expect((dynamicKeyArray[1] as? String) == "dragon")
    } else {
        Issue.record("Expected broadcast scope to encode dynamic key definition")
    }
}
