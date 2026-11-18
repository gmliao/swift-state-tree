// Tests/SwiftStateTreeTests/ReplayPayloadDepthTests.swift
//
// A recorded input replayed comes without its frame's bound (`DepthBounded`): a record is only
// bounded at the record limit (`CanonicalMessagePack.maxDepth`, 128), so its payloads are walked
// at the client limit (32) before their re-encode (#362).

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ReplayDepthState: StateNodeProtocol {
    @Sync(.broadcast)
    var hits: [String] = []
}

@Payload
struct ReplayDepthAction: ActionPayload {
    typealias Response = ReplayDepthResponse
    let tag: String
    let deep: AnyCodable
}

@Payload
struct ReplayDepthResponse: ResponsePayload {
    let count: Int
}

@Payload
struct ReplayDepthEvent: ClientEventPayload {
    let tag: String
    let deep: AnyCodable
}

@Suite("A replayed payload is walked for its depth: the record's bound is wider (#362)")
struct ReplayPayloadDepthTests {
    /// `[[...[]...]]`, `levels` arrays, as JSON text.
    static func nestedArrays(_ levels: Int) -> String {
        String(repeating: "[", count: levels) + String(repeating: "]", count: levels)
    }

    static func definition() -> LandDefinition<ReplayDepthState> {
        Land("replay-depth", using: ReplayDepthState.self) {
            ClientEvents { Register(ReplayDepthEvent.self) }
            Rules {
                HandleAction(ReplayDepthAction.self) { (state: inout ReplayDepthState, action: ReplayDepthAction, _: LandContext) in
                    state.hits.append("action:\(action.tag)")
                    return ReplayDepthResponse(count: state.hits.count)
                }
                HandleEvent(ReplayDepthEvent.self) { (state: inout ReplayDepthState, event: ReplayDepthEvent, _: LandContext) in
                    state.hits.append("event:\(event.tag)")
                }
            }
        }
    }

    @Test("A recorded action and client event deeper than the client limit, under the record's, are refused; the shallow ones apply")
    func deepRecordedInputsRefused() async throws {
        let limit = PayloadNesting.clientFrameMaxDepth
        // `deep` sits two levels into the payload (the payload object, then its `deep` value),
        // so a payload of `limit + 8` levels has `deep` at `limit + 7` arrays.
        let deep = Self.nestedArrays(limit + 7)
        let shallow = Self.nestedArrays(1)
        func action(_ sequence: Int, _ tag: String, _ value: String) -> String {
            #"{"kind":"action","sequence":\#(sequence),"typeIdentifier":"\#(String(describing: ReplayDepthAction.self))","payload":{"tag":"\#(tag)","deep":\#(value)},"playerID":"p","clientID":"c","sessionID":"s","resolverOutputs":{},"resolvedAtTick":0}"#
        }
        func event(_ sequence: Int, _ tag: String, _ value: String) -> String {
            #"{"kind":"clientEvent","sequence":\#(sequence),"typeIdentifier":"\#(payloadEventName(for: ReplayDepthEvent.self))","payload":{"tag":"\#(tag)","deep":\#(value)},"playerID":"p","clientID":"c","sessionID":"s","resolvedAtTick":0}"#
        }
        let record = #"{"recordMetadata":{"landID":"l","landType":"replay-depth","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":[{"tickId":0,"actions":["#
            + [action(0, "deep", deep), action(1, "shallow", shallow)].joined(separator: ",")
            + #"],"clientEvents":["#
            + [event(2, "deep", deep), event(3, "shallow", shallow)].joined(separator: ",")
            + #"],"lifecycleEvents":[]}]}"#
        let data = Data(record.utf8)
        // Under the record's bound: the source takes it.
        try PayloadNesting.checkJSON(data, limit: CanonicalMessagePack.maxDepth)
        let source = try JSONReevaluationSource(data: data)

        let droppedBefore = PayloadNesting.droppedClientEventCount
        let keeper = LandKeeper<ReplayDepthState>(
            definition: Self.definition(),
            initialState: ReplayDepthState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        await keeper.stepTickOnce()

        #expect(await keeper.currentState().hits == ["action:shallow", "event:shallow"])
        #expect(PayloadNesting.droppedClientEventCount >= droppedBefore + 1)
    }
}
