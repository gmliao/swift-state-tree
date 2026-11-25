// Tests/SwiftStateTreeTransportTests/ActionResponseFrameTests.swift
//
// #700 K1a, C7: the adapter encodes an action's reply from the keeper's outcome, so the response
// isn't boxed into `AnyCodable` on its way to the frame. The frame's bytes must be the ones the
// boxed message gives, on every encoder and both payload forms.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTurns
@_spi(Diagnostics) @testable import SwiftStateTreeTransport

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

/// Shapes `@Payload` doesn't take: an optional, data, an enum with an associated value and a map,
/// with synthesized `Codable` and no typed writer. (A `Date` isn't plain data, so no response
/// holds one.)
@PlainData
struct ActionResponseFrameWide: ResponsePayload {
    let note: String?
    let blob: Data
    let pick: ActionResponseFramePick
    let counts: [String: Int]

    static func getFieldMetadata() -> [FieldMetadata] { [] }
}

@PlainData
enum ActionResponseFramePick: Codable, Sendable, Equatable {
    case none
    case one(Int)
    case named(label: String, rank: Int)
}

/// A hand-written `encode(to:)` that writes a `Decimal`, which no typed payload can store: every
/// encoder must refuse it, on both paths (#597).
@PlainData
struct ActionResponseFrameDecimal: ResponsePayload {
    let cents: Int

    init(cents: Int) { self.cents = cents }

    private enum CodingKeys: String, CodingKey { case amount }

    init(from decoder: Decoder) throws {
        let amount = try decoder.container(keyedBy: CodingKeys.self).decode(Decimal.self, forKey: .amount)
        cents = NSDecimalNumber(decimal: amount * 100).intValue
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Decimal(cents) / 100, forKey: .amount)
    }

    static func getFieldMetadata() -> [FieldMetadata] { [] }
}

@StateNodeBuilder
struct ActionResponseFrameState: StateNodeProtocol {
    @Sync(.broadcast)
    var total: Int = 0
}

@Payload
struct ActionResponseFrameAction: ActionPayload {
    typealias Response = ActionResponseFrameReply
    let amount: Int
}

/// Records every frame sent.
private actor ActionResponseFrameTransport: Transport {
    var delegate: TransportDelegate?
    private(set) var frames: [Data] = []

    func setDelegate(_ delegate: TransportDelegate?) { self.delegate = delegate }
    func start() async throws {}
    func stop() async throws {}
    func send(_ message: Data, to target: SwiftStateTreeTransport.EventTarget) { frames.append(message) }
    func sendBatch(_ updates: [(Data, SwiftStateTreeTransport.EventTarget)]) async {
        frames.append(contentsOf: updates.map(\.0))
    }
}

/// Each preset's message encoding.
enum ActionResponseFrameConfig: String, CaseIterable, Sendable {
    case json, jsonOpcode, opcode, messagepack

    var config: TransportEncodingConfig {
        switch self {
        case .json: return .json
        case .jsonOpcode: return .jsonOpcode
        case .opcode: return .opcode
        case .messagepack: return .messagepack
        }
    }

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

    /// The same bytes as the boxed message, or a refusal on both paths.
    private static func expectSameFrame(_ outcome: InputOutcome, _ label: String) {
        for (encoderName, encoder) in Self.encoders {
            guard let outcomeEncoder = encoder as? any ActionResponseFrameEncoder else {
                Issue.record("\(encoderName) has no outcome entry")
                continue
            }
            let boxed = Result { try encoder.encode(.actionResponse(requestID: "r-1", response: outcome.boundaryValue)) }
            let direct = Result { try outcomeEncoder.encodeActionResponse(requestID: "r-1", outcome: outcome) }
            switch (boxed, direct) {
            case let (.success(b), .success(d)):
                #expect(d == b, "\(encoderName), \(label)")
            case (.failure, .failure):
                break
            default:
                Issue.record("\(encoderName), \(label): boxed \(boxed), direct \(direct)")
            }
        }
    }

    @Test("An optional set to nil, data, an enum with an associated value and a map: the boxed message's bytes, or a refusal on both paths")
    func wideShapesMatchTheBoxedMessage() {
        for (name, pick) in [("none", ActionResponseFramePick.none), ("one", .one(-3)), ("named", .named(label: "b", rank: 2))] {
            for note in [nil, "n"] as [String?] {
                Self.expectSameFrame(.response(ActionResponseFrameWide(
                    note: note, blob: Data([0, 1, 0xff]),
                    pick: pick, counts: ["z": 1, "a": 2, "\u{e9}": 3, "m": 0]
                )), "\(name), note \(note ?? "nil")")
            }
        }
    }

    @Test("A hand-written encode that writes a Decimal is refused on every encoder, on both paths")
    func decimalInACustomEncodeIsRefusedOnBothPaths() {
        let outcome = InputOutcome.response(ActionResponseFrameDecimal(cents: 1234))
        for (encoderName, encoder) in Self.encoders {
            let outcomeEncoder = encoder as? any ActionResponseFrameEncoder
            #expect(throws: (any Error).self, "\(encoderName), boxed") {
                try encoder.encode(.actionResponse(requestID: "r-1", response: outcome.boundaryValue))
            }
            #expect(throws: (any Error).self, "\(encoderName), direct") {
                try outcomeEncoder?.encodeActionResponse(requestID: "r-1", outcome: outcome)
            }
        }
    }

    @Test("Every preset's adapter sends an action's reply from the outcome, never through the boxed fallback", arguments: ActionResponseFrameConfig.allCases)
    func adapterRepliesWithoutBoxing(_ preset: ActionResponseFrameConfig) async throws {
        // Tickless, so the action's response itself is the reply.
        let definition = Land("action-response-frame", using: ActionResponseFrameState.self) {
            Rules {
                HandleAction(ActionResponseFrameAction.self) { state, action, _ in
                    state.total += action.amount
                    return ActionResponseFrameReply(
                        label: "t", ratio: 0.5, count: state.total, tags: [],
                        nested: ActionResponseFrameNested(flag: true, note: "")
                    )
                }
            }
        }
        let transport = ActionResponseFrameTransport()
        let keeper = LandKeeper(definition: definition, initialState: ActionResponseFrameState())
        let adapter = TransportAdapter<ActionResponseFrameState>(
            keeper: keeper,
            transport: transport,
            landID: "action-response-frame",
            encodingConfig: preset.config,
            suppressMissingPathHashesWarning: true
        )
        await transport.setDelegate(adapter)
        await keeper.setTransport(adapter)

        let session = SessionID("s1"), client = ClientID("c1")
        await adapter.onConnect(sessionID: session, clientID: client)
        try await simulateRouterJoin(
            adapter: adapter, keeper: keeper, sessionID: session, clientID: client, playerID: PlayerID("p1"), waitsByEvent: true
        )

        let envelope = ActionEnvelope(
            typeIdentifier: "ActionResponseFrameAction",
            payload: AnyCodable(ActionResponseFrameAction(amount: 2))
        )
        // An inline answer: sent before `onMessage` returns, and out once the writer is idle.
        await adapter.onMessage(try preset.config.makeCodec().encode(TransportMessage.action(requestID: "arf-1", action: envelope)), from: session)
        await adapter.waitForOutboundIdleForTesting()

        let replies = await transport.frames.filter { $0.range(of: Data("arf-1".utf8)) != nil }
        #expect(replies.count == 1, "\(preset): one reply")
        #expect(await adapter.boxedActionResponsesForTesting == 0, "\(preset)")
    }
}
