// Tests/SwiftStateTreeTests/ReplayInputDecodeTests.swift
//
// Replay decodes each recorded input once. From 3.7 (#700 K1a) it decodes the recorded bytes when
// it builds the items, with the live decoder for their encoding: a JSON payload's depth is checked
// on its bytes, and no tree is built or walked. A recorded client event that doesn't decode is
// dropped, as before. PR 2b's staged batch (A5) makes such an event fail the run.

import Foundation
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct ReplayDecodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var hits: [String] = []
}

@Payload
struct ReplayDecodeAction: ActionPayload {
    typealias Response = ReplayDecodeResponse
    let tag: String
}

@Payload
struct ReplayDecodeResponse: ResponsePayload {
    let count: Int
}

@Payload
struct ReplayDecodeEvent: ClientEventPayload {
    let tag: String
}

@Suite("Replay decodes its recorded inputs as before #521 PR 2, until PR 2b")
struct ReplayInputDecodeTests {
    static func definition() -> LandDefinition<ReplayDecodeState> {
        Land("replay-decode", using: ReplayDecodeState.self) {
            ClientEvents { Register(ReplayDecodeEvent.self) }
            Rules {
                HandleAction(ReplayDecodeAction.self) { state, action, _ in
                    state.hits.append("action:\(action.tag)")
                    return ReplayDecodeResponse(count: state.hits.count)
                }
                HandleEvent(ReplayDecodeEvent.self) { state, event, _ in
                    state.hits.append("event:\(event.tag)")
                }
            }
        }
    }

    static func record(actions: [String], events: [String]) -> Data {
        var sequence = 0
        func action(_ payload: String) -> String {
            defer { sequence += 1 }
            return #"{"kind":"action","sequence":\#(sequence),"typeIdentifier":"\#(String(describing: ReplayDecodeAction.self))","payload":"\#(Data(payload.utf8).base64EncodedString())","playerID":"p","clientID":"c","sessionID":"s","resolverOutputs":{},"resolvedAtTick":0}"#
        }
        func event(_ payload: String) -> String {
            defer { sequence += 1 }
            return #"{"kind":"clientEvent","sequence":\#(sequence),"typeIdentifier":"\#(payloadEventName(for: ReplayDecodeEvent.self))","payload":"\#(Data(payload.utf8).base64EncodedString())","playerID":"p","clientID":"c","sessionID":"s","resolvedAtTick":0}"#
        }
        let actionRecords = actions.map(action).joined(separator: ",")
        let eventRecords = events.map(event).joined(separator: ",")
        let text = #"{"recordMetadata":{"landID":"l","landType":"replay-decode","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"\#(ReevaluationRecordVersion.current)"},"tickFrames":[{"tickId":0,"actions":["#
            + actionRecords + #"],"clientEvents":["# + eventRecords + #"],"lifecycleEvents":[]}]}"#
        return Data(text.utf8)
    }

    @Test("A replayed JSON input walks no tree (its depth is checked on its bytes); a recorded client event that doesn't decode is still dropped")
    func replayedInputsDecodedAtApply() async throws {
        let data = Self.record(
            actions: [#"{"tag":"a"}"#],
            events: [#"{"tag":"e"}"#, #"{"tag":5}"#]
        )
        let source = try JSONReevaluationSource(data: data)
        let keeper = LandKeeper<ReplayDecodeState>(
            definition: Self.definition(),
            initialState: ReplayDecodeState(),
            mode: .reevaluation,
            reevaluationSource: source,
            autoStartLoops: false
        )
        let walks = PayloadNesting.WalkCounter()
        await PayloadNesting.$walks.withValue(walks) {
            await keeper.stepTickOnce()
        }
        // The action and the decodable event applied; the event with a number for `tag` dropped
        // by its handler, without failing the tick (N3 (b) lands with A5 in PR 2b).
        #expect(await keeper.currentState().hits == ["action:a", "event:e"])
        // No tree walk: a 3.7 JSON payload is checked on its bytes (`JSONRecordBytesSource`), which
        // `RecordPayloadBytesTests.deepJSONBytesAreRefused` pins.
        #expect(walks.count == 0)
    }
}
