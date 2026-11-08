import Foundation
import Testing
@testable import GameContent
import SwiftStateTree
@testable import SwiftStateTreeTransport

/// ServerLoadTest's joins must declare every state-update feature a server can require, or the
/// server refuses them (`JOIN_STATE_UPDATE_FEATURE_MISSING`) and the run measures nothing.
struct LoadTestJoinTests {

    @Test("A ServerLoadTest join declares every state-update feature a server can require")
    func joinDeclaresEveryFeature() throws {
        let message = makeLoadTestJoinMessage(landType: "hero-defense", roomIndex: 2, playerIndexInRoom: 3)
        // What the server sees: the join after the JSON codec ServerLoadTest sends it with.
        let codec = TransportEncoding.json.makeCodec()
        let decoded = try codec.decode(TransportMessage.self, from: codec.encode(message))
        guard case .join(let join) = decoded.payload else {
            Issue.record("not a join: \(decoded.kind)")
            return
        }
        #expect(join.requestID == "join-2-3")
        #expect(join.landInstanceId == "room-2")
        #expect(join.playerID == "p-2-3")

        let pathHashes: [String: UInt32] = ["round": 1]
        for name in ["json", "jsonopcode", "opcode", "messagepack"] {
            // Every feature on: what a server can require of this encoding.
            let config = resolveTransportEncoding(rawValue: name)
                .withPathIndex(true)
                .withFieldMerge(true)
                .effective(pathHashes: pathHashes)
            let missing = TransportAdapter<HeroDefenseState>.missingStateUpdateFeatures(
                required: config.stateUpdateFeatures,
                metadata: join.metadata
            )
            #expect(missing == nil, "\(name): missing \(missing ?? [])")
        }
    }
}
