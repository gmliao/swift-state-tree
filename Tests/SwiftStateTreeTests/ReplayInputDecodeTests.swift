// Tests/SwiftStateTreeTests/ReplayInputDecodeTests.swift
//
// Replay keeps main's input decode until #521 PR 2b (plan §9.1, "Replay under PR 2"): a recorded
// action is decoded when applied, with the round trip and one depth check, and a recorded client
// event by its handler, which drops one that doesn't decode. PR 2b's staged batch (A5) makes such
// an event fail the run.

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
                HandleAction(ReplayDecodeAction.self) { (state: inout ReplayDecodeState, action: ReplayDecodeAction, _: LandContext) in
                    state.hits.append("action:\(action.tag)")
                    return ReplayDecodeResponse(count: state.hits.count)
                }
                HandleEvent(ReplayDecodeEvent.self) { (state: inout ReplayDecodeState, event: ReplayDecodeEvent, _: LandContext) in
                    state.hits.append("event:\(event.tag)")
                }
            }
        }
    }

    static func record(actions: [String], events: [String]) -> Data {
        var sequence = 0
        func action(_ payload: String) -> String {
            defer { sequence += 1 }
            return #"{"kind":"action","sequence":\#(sequence),"typeIdentifier":"\#(String(describing: ReplayDecodeAction.self))","payload":\#(payload),"playerID":"p","clientID":"c","sessionID":"s","resolverOutputs":{},"resolvedAtTick":0}"#
        }
        func event(_ payload: String) -> String {
            defer { sequence += 1 }
            return #"{"kind":"clientEvent","sequence":\#(sequence),"typeIdentifier":"\#(payloadEventName(for: ReplayDecodeEvent.self))","payload":\#(payload),"playerID":"p","clientID":"c","sessionID":"s","resolvedAtTick":0}"#
        }
        let actionRecords = actions.map(action).joined(separator: ",")
        let eventRecords = events.map(event).joined(separator: ",")
        let text = #"{"recordMetadata":{"landID":"l","landType":"replay-decode","createdAt":"1970-01-01T00:00:00Z","metadata":{},"version":"2.6"},"tickFrames":[{"tickId":0,"actions":["#
            + actionRecords + #"],"clientEvents":["# + eventRecords + #"],"lifecycleEvents":[]}]}"#
        return Data(text.utf8)
    }

    @Test("Each replayed input is walked once, as on main; a recorded client event that doesn't decode is still dropped")
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
        // One depth check per replayed input: the action at apply, each event in its handler.
        #expect(walks.count == 3)
    }
}
