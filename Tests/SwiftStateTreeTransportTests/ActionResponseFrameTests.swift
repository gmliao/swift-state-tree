// Tests/SwiftStateTreeTransportTests/ActionResponseFrameTests.swift
//
// #700 K1a, C7: the adapter encodes an action's reply from the keeper's outcome, so the response
// isn't boxed into `AnyCodable` on its way to the frame. The frame's bytes must be the ones the
// boxed message gives, on every encoder and both payload forms.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@Payload
struct ActionResponseFrameReply: ResponsePayload {
    let label: String
    let ratio: Double
    let count: Int
    let tags: [String]
    let nested: ActionResponseFrameNested
}

@Payload
struct ActionResponseFrameNested: ResponsePayload {
    let flag: Bool
    let note: String
}

@Suite("An action's reply is encoded from the outcome, with the boxed message's bytes (#700 K1a)")
struct ActionResponseFrameTests {
    static let encoders: [(name: String, encoder: any TransportMessageEncoder)] = [
        ("json", JSONTransportMessageEncoder()),
        ("opcode", OpcodeTransportMessageEncoder()),
        ("opcode positional", OpcodeTransportMessageEncoder(enablePayloadCompression: true)),
        ("messagepack", MessagePackTransportMessageEncoder()),
        ("messagepack positional", MessagePackTransportMessageEncoder(enablePayloadCompression: true)),
    ]

    static let outcomes: [(name: String, outcome: InputOutcome)] = [
        ("none", .none),
        ("response", .response(ActionResponseFrameReply(
            label: "a/b \u{e9}", ratio: 1.5, count: -7, tags: ["x", "y"],
            nested: ActionResponseFrameNested(flag: true, note: "")
        ))),
        ("whole double", .response(ActionResponseFrameReply(
            label: "", ratio: 2.0, count: 0, tags: [],
            nested: ActionResponseFrameNested(flag: false, note: "n")
        ))),
    ]

    @Test("Every encoder writes the boxed message's bytes for no response and for a response")
    func outcomeFrameMatchesTheBoxedMessage() throws {
        for (encoderName, encoder) in Self.encoders {
            let outcomeEncoder = try #require(encoder as? any ActionResponseFrameEncoder, "\(encoderName)")
            for (outcomeName, outcome) in Self.outcomes {
                let boxed = try encoder.encode(.actionResponse(requestID: "r-1", response: outcome.boundaryValue))
                let direct = try outcomeEncoder.encodeActionResponse(requestID: "r-1", outcome: outcome)
                #expect(direct == boxed, "\(encoderName), \(outcomeName)")
            }
        }
    }
}
