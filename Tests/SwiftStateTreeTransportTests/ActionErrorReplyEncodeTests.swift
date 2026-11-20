// Tests/SwiftStateTreeTransportTests/ActionErrorReplyEncodeTests.swift
//
// #691: an action's error reply that doesn't encode ends the land, as its response would
// (#544), instead of being logged while the land runs on and the client waits for an answer.

import Foundation
import Testing
@testable import SwiftStateTree
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

private struct ErrorReplyTestError: Error {}

/// A land whose one action is refused by its `validate`, which writes no state, so the adapter
/// answers with an error reply.
private func makeThrowingActionLand() -> LandDefinition<UntypedPayloadState> {
    Land("error-reply", using: UntypedPayloadState.self) {
        Rules {
            HandleAction(
                UntypedResponseAction.self,
                validate: { (_: UntypedPayloadState, _: UntypedResponseAction, _: ValidateContext) throws in
                    throw ErrorReplyTestError()
                },
                apply: { (_: inout UntypedPayloadState, _: UntypedResponseAction, _: LandContext) in
                    UntypedResponseReply(count: 0)
                }
            )
        }
    }
}

@Suite("An action's error reply that doesn't encode ends the land (#691)", .serialized, .timeLimit(.minutes(1)))
struct ActionErrorReplyEncodeTests {
    @Test("the error reply reaches the client, and the land runs on", arguments: UntypedPayloadEncoding.allCases)
    func errorReplyIsSent(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeThrowingActionLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        let sentBefore = await land.transport.sends
        try await land.sendAction(requestID: "r1")
        await land.adapter.waitForOutboundIdleForTesting()
        let answers = await land.transport.sent.dropFirst(sentBefore)
            .filter { String(decoding: $0, as: UTF8.self).contains("r1") }
        #expect(answers.count == 1, "\(encoding): the error reply reached the client")
        #expect(land.keeper.failure == nil, "\(encoding)")
        #expect(!land.adapter.outputGate.isClosed, "\(encoding)")
    }

    @Test("an error reply that doesn't encode ends the land with .responseEncode and closes the session",
          arguments: UntypedPayloadEncoding.allCases)
    func errorReplyEncodeFailureEndsTheLand(encoding: UntypedPayloadEncoding) async throws {
        let land = try await UntypedPayloadLand.make(makeThrowingActionLand(), encoding: encoding)
        await land.adapter.waitForOutboundIdleForTesting()
        await land.adapter.setErrorReplyEncodingFaultForTesting(true)
        let sentBefore = await land.transport.sends
        try await land.sendAction(requestID: "r1")
        await land.adapter.waitForOutboundIdleForTesting()

        try #require(await land.keeper.waitForFailureForTesting(), "\(encoding): the land failed")
        await land.keeper.waitUntilDrained()
        let failure = land.keeper.failure
        #expect(failure?.kind == .responseEncode, "\(encoding)")
        #expect(failure?.position.stage == .actionResponse, "\(encoding)")
        #expect(failure?.detail.contains("error reply") == true, "\(encoding): \(String(describing: failure))")
        #expect(failure?.detail.contains("UntypedResponseAction") == true, "\(encoding): \(String(describing: failure))")
        #expect(land.adapter.outputGate.isClosed, "\(encoding)")
        #expect(await land.transport.sends == sentBefore, "\(encoding): no answer and no frame after the failure")
        #expect(await land.transport.closes == [SessionClose.Code.landFailed], "\(encoding)")
    }
}
