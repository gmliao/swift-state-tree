// The bytes of every positional payload the message encoders write, recorded from the encoders
// before the typed payload writer (#521 PR 1a) into `Fixtures/PayloadFrames/payload-frames.json`.
// The writer must reproduce them: server events (the standalone frame and the opcode 107 body),
// the merged 107 frame, action responses, actions and client events, in the three message
// encodings, with payload compression on and off. Each payload also goes through the form
// without a typed value (`AnyServerEvent(type:payload:)`, `AnyCodable` envelopes), which must
// give the same bytes. A value an encoding can't carry (NaN under JSON) is recorded as "error".

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeDeterministicMath
import SwiftStateTreeMessagePack
import SwiftStateTreeReevaluationMonitor
@testable import SwiftStateTreeTransport

enum PayloadFrameGoldenEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_PAYLOAD_FRAMES"
}

// MARK: - Fixture types: one field of each leaf type, and each fallback kind

@Payload
struct PFLeavesEvent: ServerEventPayload {
    let bool: Bool
    let int: Int
    let int8: Int8
    let int16: Int16
    let int32: Int32
    let int64: Int64
    let uint: UInt
    let uint8: UInt8
    let uint16: UInt16
    let uint32: UInt32
    let uint64: UInt64
    let float: Float
    let double: Double
    let string: String
    let player: PlayerID
    let client: ClientID
    let session: SessionID
    let land: LandID
}

@Payload
struct PFMathEvent: ServerEventPayload {
    let angle: Angle
    let ivec2: IVec2
    let ivec3: IVec3
    let position: Position2
    let velocity: Velocity2
    let acceleration: Acceleration2
}

struct PFNested: Codable, Sendable {
    let a: Int
    let b: String
}

enum PFKind: String, Codable, Sendable {
    case first
    case second
}

@Payload
struct PFFallbacksEvent: ServerEventPayload {
    let ints: [Int]
    let byName: [String: Int]
    let byPlayer: [PlayerID: Int]
    let nested: PFNested
    let anyObject: AnyCodable
    let anyArray: AnyCodable
    let date: Date
    let data: Data
    let decimal: Decimal
    let uuid: UUID
    let kind: PFKind
}

/// No fields: `[]` positional.
@Payload
struct PFEmptyEvent: ServerEventPayload {}

/// Its name isn't in the event table: the type goes out as its string name.
@Payload
struct PFUnhashedEvent: ServerEventPayload {
    let n: Int
}

@Payload
struct PFResponse: ResponsePayload {
    let ok: Bool
    let total: Int
    let at: Position2
    let tags: [String]
}

@Payload
struct PFEmptyResponse: ResponsePayload {}

@Payload
struct PFAction: ActionPayload {
    typealias Response = PFResponse
    let count: Int
    let label: String
    let target: Position2
    let ids: [PlayerID]
}

@Payload
struct PFClientEvent: ClientEventPayload {
    let player: PlayerID
    let to: Position2
    let step: Int
}

@Payload
struct PFEmptyClientEvent: ClientEventPayload {}

// MARK: - Cases

struct PayloadFrameCase: Sendable {
    enum Kind: String, Sendable {
        case serverEvent, actionResponse, action, clientEvent
    }

    let name: String
    let kind: Kind
    /// The message built from the typed value (`AnyServerEvent(_:)`, `AnyClientEvent(_:)`), and
    /// the same payload without it (`AnyServerEvent(type:payload:)`, `AnyClientEvent(type:payload:)`).
    /// Responses and actions are always `AnyCodable` boxes, so both are the same message.
    let typed: TransportMessage
    let untyped: TransportMessage
    /// The server event, for its opcode 107 body.
    let serverEvent: AnyServerEvent?
}

enum PayloadFrameCases {
    static func serverEvent<E: ServerEventPayload>(_ name: String, _ value: E) -> PayloadFrameCase {
        let typed = AnyServerEvent(value)
        let untyped = AnyServerEvent(type: typed.type, payload: AnyCodable(value))
        return PayloadFrameCase(
            name: name, kind: .serverEvent,
            typed: .event(event: .fromServer(event: typed)),
            untyped: .event(event: .fromServer(event: untyped)),
            serverEvent: typed
        )
    }

    static func response(_ name: String, _ value: Any) -> PayloadFrameCase {
        let message = TransportMessage.actionResponse(requestID: "r-\(name)", response: AnyCodable(value))
        return PayloadFrameCase(name: name, kind: .actionResponse, typed: message, untyped: message, serverEvent: nil)
    }

    static func action<A: ActionPayload>(_ name: String, _ value: A) -> PayloadFrameCase {
        let envelope = ActionEnvelope(typeIdentifier: String(describing: A.self), payload: AnyCodable(value))
        let message = TransportMessage.action(requestID: "a-\(name)", action: envelope)
        return PayloadFrameCase(name: name, kind: .action, typed: message, untyped: message, serverEvent: nil)
    }

    static func clientEvent<E: ClientEventPayload>(_ name: String, _ value: E) -> PayloadFrameCase {
        let typed = AnyClientEvent(value)
        let untyped = AnyClientEvent(type: typed.type, payload: AnyCodable(value))
        return PayloadFrameCase(
            name: name, kind: .clientEvent,
            typed: .event(event: .fromClient(event: typed)),
            untyped: .event(event: .fromClient(event: untyped)),
            serverEvent: nil
        )
    }

    static func leaves(
        bool: Bool = false, int: Int = 0, int8: Int8 = 0, int16: Int16 = 0, int32: Int32 = 0, int64: Int64 = 0,
        uint: UInt = 0, uint8: UInt8 = 0, uint16: UInt16 = 0, uint32: UInt32 = 0, uint64: UInt64 = 0,
        float: Float = 0, double: Double = 0, string: String = "", id: String = ""
    ) -> PFLeavesEvent {
        PFLeavesEvent(
            bool: bool, int: int, int8: int8, int16: int16, int32: int32, int64: int64,
            uint: uint, uint8: uint8, uint16: uint16, uint32: uint32, uint64: uint64,
            float: float, double: double, string: string,
            player: PlayerID(id), client: ClientID(id), session: SessionID(id), land: LandID(id)
        )
    }

    static func math(_ a: Int32, _ b: Int32, _ c: Int32) -> PFMathEvent {
        PFMathEvent(
            angle: Angle(degrees: a),
            ivec2: IVec2(fixedPointX: a, fixedPointY: b),
            ivec3: IVec3(fixedPointX: a, fixedPointY: b, fixedPointZ: c),
            position: Position2(v: IVec2(fixedPointX: b, fixedPointY: c)),
            velocity: Velocity2(v: IVec2(fixedPointX: c, fixedPointY: a)),
            acceleration: Acceleration2(v: IVec2(fixedPointX: a, fixedPointY: a))
        )
    }

    static let position = Position2(v: IVec2(fixedPointX: 1500, fixedPointY: -2250))

    static var all: [PayloadFrameCase] {
        [
            // Leaves
            serverEvent("leaves-zero", leaves()),
            serverEvent("leaves-min", leaves(
                bool: true, int: .min, int8: .min, int16: .min, int32: .min, int64: .min,
                float: -.greatestFiniteMagnitude, double: -.greatestFiniteMagnitude,
                string: "caf\u{E9}", id: "p\u{E9}"
            )),
            serverEvent("leaves-max", leaves(
                int: .max, int8: .max, int16: .max, int32: .max, int64: .max,
                uint: .max, uint8: .max, uint16: .max, uint32: .max, uint64: .max,
                float: .greatestFiniteMagnitude, double: .greatestFiniteMagnitude,
                string: "cafe\u{301}", id: "pe\u{301}"
            )),
            serverEvent("leaves-unsigned-above-int-max", leaves(uint: UInt(Int.max) + 1, uint64: UInt64(Int64.max) + 1)),
            serverEvent("leaves-negative-zero", leaves(float: -0.0, double: -0.0)),
            serverEvent("leaves-subnormal", leaves(float: .leastNonzeroMagnitude, double: .leastNonzeroMagnitude)),
            serverEvent("leaves-fractions", leaves(float: 0.1, double: 0.1, string: "a\"b\\c\n\u{1F600}")),
            serverEvent("leaves-nan", leaves(float: .nan, double: .nan)),
            serverEvent("leaves-infinity", leaves(float: .infinity, double: -.infinity)),
            // Deterministic math
            serverEvent("math-zero", math(0, 0, 0)),
            serverEvent("math-int32-min", math(.min, .min, .min)),
            serverEvent("math-int32-max", math(.max, .max, .max)),
            serverEvent("math-mixed", math(.min, .max, -1)),
            // Fallbacks
            serverEvent("fallbacks", PFFallbacksEvent(
                ints: [1, -2, 3],
                byName: ["b": 2, "a": 1, "\u{E9}": 3],
                byPlayer: [PlayerID("p1"): 10, PlayerID("p2"): 20],
                nested: PFNested(a: 7, b: "x"),
                anyObject: AnyCodable(["k": AnyCodable(1), "j": AnyCodable("v"), "n": AnyCodable([AnyCodable(true)])]),
                anyArray: AnyCodable([AnyCodable(1), AnyCodable("a"), AnyCodable(false)]),
                date: Date(timeIntervalSinceReferenceDate: 1.5),
                data: Data([0, 1, 254, 255]),
                decimal: Decimal(string: "12.5")!,
                uuid: UUID(uuidString: "E621E1F8-C36C-495A-93FC-0C247A3E6E5F")!,
                kind: .second
            )),
            serverEvent("fallbacks-empty", PFFallbacksEvent(
                ints: [], byName: [:], byPlayer: [:], nested: PFNested(a: 0, b: ""),
                anyObject: AnyCodable([String: AnyCodable]()), anyArray: AnyCodable([AnyCodable]()),
                date: Date(timeIntervalSinceReferenceDate: 0), data: Data(), decimal: 0,
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, kind: .first
            )),
            serverEvent("fallbacks-decimal-nan", PFFallbacksEvent(
                ints: [], byName: [:], byPlayer: [:], nested: PFNested(a: 0, b: ""),
                anyObject: AnyCodable([String: AnyCodable]()), anyArray: AnyCodable([AnyCodable]()),
                date: Date(timeIntervalSinceReferenceDate: 0), data: Data(), decimal: .nan,
                uuid: UUID(uuidString: "00000000-0000-0000-0000-000000000000")!, kind: .first
            )),
            serverEvent("empty", PFEmptyEvent()),
            serverEvent("unhashed", PFUnhashedEvent(n: 5)),
            // The reevaluation monitor's events
            serverEvent("monitor-tick-summary", TickSummaryEvent(tickId: 42, isMatch: false, expectedHash: "aa", actualHash: "bb")),
            serverEvent("monitor-tick-processed", TickProcessedEvent(
                tickId: .max,
                expectedState: AnyCodable(["hp": AnyCodable(3), "name": AnyCodable("x")]),
                actualState: AnyCodable(["hp": AnyCodable(4)]),
                isMatch: false, expectedHash: "aa", actualHash: "bb"
            )),
            serverEvent("monitor-progress", VerificationProgressEvent(processedTicks: 3, totalTicks: 9)),
            serverEvent("monitor-complete", VerificationCompleteEvent(
                totalTicks: 9, correctTicks: 8, mismatchedTicks: 1,
                mismatches: [TickMismatch(tickId: 4, computed: "c", recorded: "r")]
            )),
            serverEvent("monitor-failed", VerificationFailedEvent(errorMessage: "boom")),
            // Action responses
            response("response", PFResponse(ok: true, total: -3, at: position, tags: ["x", "y"])),
            response("response-empty", PFEmptyResponse()),
            response("response-void", ()),
            response("response-monitor-start", StartVerificationResponse()),
            response("response-monitor-pause", PauseVerificationResponse()),
            response("response-monitor-resume", ResumeVerificationResponse()),
            // Actions
            action("action", PFAction(count: 2, label: "go", target: position, ids: [PlayerID("p1")])),
            action("action-monitor-start", StartVerificationAction(landType: "hero-defense", recordFilePath: "/tmp/r.json")),
            action("action-monitor-pause", PauseVerificationAction()),
            action("action-monitor-resume", ResumeVerificationAction()),
            // Client events
            clientEvent("client-event", PFClientEvent(player: PlayerID("p1"), to: position, step: 3)),
            clientEvent("client-event-empty", PFEmptyClientEvent()),
        ]
    }

    /// Every server event name but `PFUnhashed` (sent as its string), numbered in sorted order as
    /// the schema numbers them.
    static var eventHashes: [String: Int] {
        let names = all.compactMap(\.serverEvent).map(\.type).filter { $0 != "PFUnhashed" }
        return Dictionary(uniqueKeysWithValues: Set(names).sorted().enumerated().map { ($1, $0) })
    }

    static let clientEventHashes: [String: Int] = ["PFClient": 0, "PFEmptyClient": 1]
}

// MARK: - Encoding

struct PayloadFrameEncoders {
    let messagePack: MessagePackTransportMessageEncoder
    let messagePackPlain: MessagePackTransportMessageEncoder
    let opcodeJSON: OpcodeTransportMessageEncoder
    let opcodeJSONPlain: OpcodeTransportMessageEncoder
    let jsonObject = JSONTransportMessageEncoder()

    init(eventHashes: [String: Int], clientEventHashes: [String: Int]) {
        messagePack = MessagePackTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: true)
        messagePackPlain = MessagePackTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: false)
        opcodeJSON = OpcodeTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: true)
        opcodeJSONPlain = OpcodeTransportMessageEncoder(
            eventHashes: eventHashes, clientEventHashes: clientEventHashes, enablePayloadCompression: false)
    }

    /// Base64 for binary encodings, the text for JSON ones, "error" when the encoder throws.
    static func record(_ binary: Bool, _ encode: () throws -> Data) -> String {
        guard let data = try? encode() else { return "error" }
        return binary ? data.base64EncodedString() : String(decoding: data, as: UTF8.self)
    }

    /// The frames of one message, keyed by encoding.
    func frames(_ message: TransportMessage) -> [String: String] {
        [
            "messagePack": Self.record(true) { try messagePack.encode(message) },
            "messagePackPlain": Self.record(true) { try messagePackPlain.encode(message) },
            "opcodeJSON": Self.record(false) { try opcodeJSON.encode(message) },
            "opcodeJSONPlain": Self.record(false) { try opcodeJSONPlain.encode(message) },
            "jsonObject": Self.record(false) { try jsonObject.encode(message) },
        ]
    }

    func body(_ event: AnyServerEvent) -> String {
        Self.record(true) { try pack(messagePack.encodeServerEventBody(event)) }
    }
}

@Suite("Payload frames: the bytes the message encoders write, per payload kind and encoding (#521)")
struct PayloadFrameGoldenTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/PayloadFrames/payload-frames.json").path

    static let encoders = PayloadFrameEncoders(
        eventHashes: PayloadFrameCases.eventHashes,
        clientEventHashes: PayloadFrameCases.clientEventHashes
    )

    /// The merged opcode 107 frame of a fixed state array and every server event's body that
    /// encodes, in case order.
    static func mergedFrame(_ cases: [PayloadFrameCase]) -> String {
        let pipeline = EncodingPipeline(
            stateUpdateEncoder: OpcodeMessagePackStateUpdateEncoder(),
            messageEncoder: encoders.messagePack,
            landID: "payload-frames"
        )
        let bodies = cases.compactMap(\.serverEvent).compactMap { pipeline.encodeServerEventBody($0) }
        guard let frame = pipeline.buildStateUpdateWithEventBodies(
            stateUpdateArray: [.int(0), .string("payload-frames")], eventBodies: bodies
        ) else { return "error" }
        return frame.base64EncodedString()
    }

    static func fixture() throws -> Data {
        let cases = PayloadFrameCases.all
        var records: [AnyCodable] = []
        for c in cases {
            var record = encoders.frames(c.typed).mapValues { AnyCodable($0) }
            record["name"] = AnyCodable(c.name)
            record["kind"] = AnyCodable(c.kind.rawValue)
            if let event = c.serverEvent {
                record["messagePackBody"] = AnyCodable(encoders.body(event))
            }
            records.append(AnyCodable(record))
        }
        let document: [String: AnyCodable] = [
            "eventHashes": AnyCodable(PayloadFrameCases.eventHashes.mapValues { AnyCodable($0) }),
            "clientEventHashes": AnyCodable(PayloadFrameCases.clientEventHashes.mapValues { AnyCodable($0) }),
            "cases": AnyCodable(records),
            "merged107": AnyCodable(mergedFrame(cases)),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    /// The recordings as this build writes them; `fixtureIsCurrent` holds them to the committed file.
    /// Read from the encoders, not the file, so a regenerating run can't race this read.
    static func recorded() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: fixture()) as? [String: Any])
    }

    @Test("The fixture is current")
    func fixtureIsCurrent() throws {
        let data = try Self.fixture()
        if EnvHelpers.getEnvBool(key: PayloadFrameGoldenEnvKeys.regenerate, defaultValue: false) {
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: Self.fixturePath).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(PayloadFrameGoldenEnvKeys.regenerate)=1, and say why in the PR")
    }

    @Test("A payload without its typed value gives the same frames", arguments: PayloadFrameCases.all.map(\.name))
    func untypedFormMatches(name: String) throws {
        let c = try #require(PayloadFrameCases.all.first { $0.name == name })
        #expect(Self.encoders.frames(c.untyped) == Self.encoders.frames(c.typed))
    }

    @Test("Every kind, every leaf type and each fallback kind is in the fixture; JSON refuses only non-finite values")
    func coverage() throws {
        let cases = try #require(try Self.recorded()["cases"] as? [[String: Any]])
        let kinds = Set(cases.compactMap { $0["kind"] as? String })
        #expect(kinds == ["serverEvent", "actionResponse", "action", "clientEvent"])
        for c in cases {
            let name = c["name"] as? String ?? "?"
            // A Decimal NaN isn't refused today: every JSON encoding writes a bare `NaN` (#557).
            let refusesJSON = ["leaves-nan", "leaves-infinity"].contains(name)
            for key in ["messagePack", "messagePackPlain"] {
                #expect(c[key] as? String != "error", "\(name): \(key)")
            }
            for key in ["opcodeJSON", "opcodeJSONPlain", "jsonObject"] {
                #expect((c[key] as? String == "error") == refusesJSON, "\(name): \(key)")
            }
        }
    }
}
