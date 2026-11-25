// Tests/SwiftStateTreeTests/InputOutcomeTests.swift
//
// The keeper holds an input's success as `InputOutcome` and converts it at its exits to the
// `AnyCodable` it returned before: an empty one for `.none`, the response's own value for
// `.response`. The public `invoke` / `invokeErased` box the same value.

import Foundation
import Logging
import Testing
@testable import SwiftStateTree

@StateNodeBuilder
struct InputOutcomeTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0

    public init() {}
}

@Payload
struct InputOutcomeReply: ResponsePayload {
    let total: Int
}

@Payload
struct InputOutcomeAction: ActionPayload {
    typealias Response = InputOutcomeReply
    let amount: Int
}

@Suite("The keeper's input outcome and its conversion at the exits")
struct InputOutcomeTests {
    @Test("`.none` converts to an empty AnyCodable, `.response` to the response's own value")
    func boundaryValue() throws {
        #expect(InputOutcome.none.boundaryValue.base is Void)
        let converted = InputOutcome.response(InputOutcomeReply(total: 7)).boundaryValue
        let reply = try #require(converted.base as? InputOutcomeReply)
        #expect(reply.total == 7)
        #expect(try CanonicalMessagePack.encode(converted) == CanonicalMessagePack.encode(AnyCodable(InputOutcomeReply(total: 7))))
    }

    @Test("The public invoke and invokeErased return the response boxed, as before; invokeTyped returns it unboxed")
    func invokeForms() throws {
        let handler = HandleAction(InputOutcomeAction.self) {
            (state: inout InputOutcomeTestState, action: InputOutcomeAction, _: LandContext) in
            state.total += action.amount
            return InputOutcomeReply(total: state.total)
        }
        let ctx = LandContext(
            landID: "input-outcome", playerID: PlayerID("p"), clientID: ClientID("c"), sessionID: SessionID("s"),
            services: LandServices(), logger: Logger(label: "test"), deviceID: nil, metadata: [:],
            emitEventHandler: { _, _ in }, requestSyncNowHandler: {}, requestSyncBroadcastOnlyHandler: {})
        var state = InputOutcomeTestState()
        let boxed = try handler.invoke(&state, action: InputOutcomeAction(amount: 2), ctx: ctx)
        #expect((boxed.base as? InputOutcomeReply)?.total == 2)
        let erased = try handler.invokeErased(&state, action: InputOutcomeAction(amount: 3), ctx: ctx)
        #expect((erased.base as? InputOutcomeReply)?.total == 5)
        let typed = try handler.invokeTyped(&state, action: InputOutcomeAction(amount: 4), ctx: ctx)
        #expect((typed as? InputOutcomeReply)?.total == 9)
    }
}
