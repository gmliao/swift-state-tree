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
                .withSyncSequence(true)
                .withRowAddressing(true)
                .effective(pathHashes: pathHashes)
            if config.stateUpdate == .opcodeJsonArray || config.stateUpdate == .opcodeMessagePack {
                // A feature added to `StateUpdateFeature.supported` must be turned on above too,
                // or a join missing it would still pass here.
                #expect(Set(config.stateUpdateFeatures) == Set(StateUpdateFeature.supported), "\(name)")
            }
            let missing = TransportAdapter<HeroDefenseState>.missingStateUpdateFeatures(
                required: config.stateUpdateFeatures,
                metadata: join.metadata
            )
            #expect(missing == nil, "\(name): missing \(missing ?? [])")
        }
    }

    @Test("A ServerLoadTest run fails when fewer players joined than it targets")
    func runFailsOnJoinShortfall() {
        #expect(loadTestJoinFailure(peakJoinedPlayers: 6, expectedPlayers: 6) == nil)
        #expect(loadTestJoinFailure(peakJoinedPlayers: 0, expectedPlayers: 6) != nil)
        #expect(loadTestJoinFailure(peakJoinedPlayers: 5, expectedPlayers: 6) != nil)
    }

    @Test("A successful joinResponse's features are read in both forms; a failed one isn't a join")
    func joinResponseFeatures() throws {
        let object: [String: Any] = ["kind": "joinResponse", "payload": ["joinResponse": [
            "requestID": "r", "success": true, "stateUpdateFeatures": ["pathIndex", "fieldMerge"]]]]
        #expect(successfulJoinFeatures(object) == .some(["pathIndex", "fieldMerge"]))
        let none: [String: Any] = ["kind": "joinResponse", "payload": ["joinResponse": ["requestID": "r", "success": true]]]
        #expect(successfulJoinFeatures(none) == .some(nil))
        let refused: [String: Any] = ["kind": "joinResponse", "payload": ["joinResponse": ["requestID": "r", "success": false]]]
        #expect(successfulJoinFeatures(refused) == nil)
        #expect(successfulJoinFeatures([105, "r", 1, "hero-defense", "room-0", 0, "messagepack", NSNull(), ["fieldMerge"]] as [Any]) == .some(["fieldMerge"]))
        #expect(successfulJoinFeatures([105, "r", 0] as [Any]) == nil)
        #expect(successfulJoinFeatures(["kind": "event"] as [String: Any]) == nil)

        // What the server sends: a TransportMessage joinResponse through the JSON codec.
        let codec = TransportEncoding.json.makeCodec()
        let message = TransportMessage(kind: .joinResponse, payload: .joinResponse(TransportJoinResponsePayload(
            requestID: "r", success: true, stateUpdateFeatures: ["fieldMerge", "pathIndex"])))
        let json = try JSONSerialization.jsonObject(with: codec.encode(message))
        #expect(successfulJoinFeatures(json) == .some(["fieldMerge", "pathIndex"]))
    }

    @Test("Joins given different state-update features fail the run")
    func joinFeatureTally() {
        var tally = JoinFeatureTally()
        #expect(tally.agreed == nil && tally.failure == nil)
        tally.record(["pathIndex", "fieldMerge"])
        tally.record(["fieldMerge", "pathIndex"])
        #expect(tally.agreed == ["fieldMerge", "pathIndex"])
        #expect(tally.failure == nil)
        tally.record(nil)
        #expect(tally.agreed == nil)
        #expect(tally.joins == ["fieldMerge,pathIndex": 2, "": 1])
        #expect(tally.failure == "joins disagree on stateUpdateFeatures: []×1, [fieldMerge,pathIndex]×2")
        var bare = JoinFeatureTally()
        bare.record([])
        #expect(bare.agreed == [])
    }
}
