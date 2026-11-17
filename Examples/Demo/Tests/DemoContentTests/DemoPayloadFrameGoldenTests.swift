// The bytes the message encoders write for every Demo payload type (the cookie and counter
// lands), recorded before the typed payload writer (#521 PR 1a) into
// `Fixtures/PayloadFrames/demo-payload-frames.json`. The writer must reproduce them, in the three
// message encodings, with payload compression on and off, from the typed value and from an
// `AnyCodable` box of it.

import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack
@testable import DemoContent

enum DemoPayloadFrameEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_PAYLOAD_FRAMES"
}

@Suite("Demo payload frames: the bytes per payload type and encoding (#521)")
struct DemoPayloadFrameGoldenTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PayloadFrames/demo-payload-frames.json").path

    struct Case {
        let name: String
        let typed: TransportMessage
        let untyped: TransportMessage
        let serverEvent: AnyServerEvent?
    }

    static func serverEvent<E: ServerEventPayload>(_ name: String, _ value: E) -> Case {
        let typed = AnyServerEvent(value)
        return Case(
            name: name,
            typed: .event(event: .fromServer(event: typed)),
            untyped: .event(event: .fromServer(event: AnyServerEvent(type: typed.type, payload: AnyCodable(value)))),
            serverEvent: typed
        )
    }

    static func clientEvent<E: ClientEventPayload>(_ name: String, _ value: E) -> Case {
        let typed = AnyClientEvent(value)
        return Case(
            name: name,
            typed: .event(event: .fromClient(event: typed)),
            untyped: .event(event: .fromClient(event: AnyClientEvent(type: typed.type, payload: AnyCodable(value)))),
            serverEvent: nil
        )
    }

    static func response(_ name: String, _ value: some ResponsePayload) -> Case {
        let message = TransportMessage.actionResponse(requestID: "r-\(name)", response: AnyCodable(value))
        return Case(name: name, typed: message, untyped: message, serverEvent: nil)
    }

    static func action<A: ActionPayload>(_ name: String, _ value: A) -> Case {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(value))
        let message = TransportMessage.action(requestID: "a-\(name)", action: envelope)
        return Case(name: name, typed: message, untyped: message, serverEvent: nil)
    }

    static var cases: [Case] {
        [
            // The cookie land
            clientEvent("click-cookie", ClickCookieEvent(amount: 3)),
            clientEvent("click-cookie-default", ClickCookieEvent()),
            action("buy-upgrade", BuyUpgradeAction(upgradeID: "grandma")),
            response("buy-upgrade-response", BuyUpgradeResponse(success: true, newCookies: -5, newCookiesPerSecond: 12, upgradeLevel: Int.max)),
            // The counter land
            action("increment", IncrementAction()),
            response("increment-response", IncrementResponse(newCount: 42)),
        ]
    }

    static let eventHashes: [String: Int] = [:]
    static let clientEventHashes = ["ClickCookie": 0]

    static func record(_ binary: Bool, _ encode: () throws -> Data) -> String {
        guard let data = try? encode() else { return "error" }
        return binary ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
    }

    static func frames(_ message: TransportMessage) -> [String: String] {
        let pack = { (compressed: Bool) in
            MessagePackTransportMessageEncoder(
                eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: compressed)
        }
        let json = { (compressed: Bool) in
            OpcodeTransportMessageEncoder(
                eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: compressed)
        }
        return [
            "messagePack": record(true) { try pack(true).encode(message) },
            "messagePackPlain": record(true) { try pack(false).encode(message) },
            "opcodeJSON": record(false) { try json(true).encode(message) },
            "opcodeJSONPlain": record(false) { try json(false).encode(message) },
            "jsonObject": record(false) { try JSONTransportMessageEncoder().encode(message) },
        ]
    }

    static func fixture() throws -> Data {
        let body = MessagePackTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: true)
        var records: [AnyCodable] = []
        for c in cases {
            var record = frames(c.typed).mapValues { AnyCodable($0) }
            record["name"] = AnyCodable(c.name)
            if let event = c.serverEvent {
                record["messagePackBody"] = AnyCodable(Self.record(true) { try pack(body.encodeServerEventBody(event)) })
            }
            records.append(AnyCodable(record))
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(["cases": AnyCodable(records)]) + Data("\n".utf8)
    }

    @Test("The fixture is current, and no frame failed")
    func fixtureIsCurrent() throws {
        let data = try Self.fixture()
        if EnvHelpers.getEnvBool(key: DemoPayloadFrameEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(DemoPayloadFrameEnvKeys.regenerate)=1, and say why in the PR")
        #expect(!String(decoding: committed, as: UTF8.self).contains("\"error\""))
    }

    @Test("A payload without its typed value gives the same frames")
    func untypedFormMatches() {
        for c in Self.cases {
            #expect(Self.frames(c.untyped) == Self.frames(c.typed), "\(c.name)")
        }
    }
}
