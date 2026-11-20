// Tests/SwiftStateTreeTransportTests/PayloadDecodeDifferentialTests.swift
//
// The typed MessagePack decode against today's path, on the same payloads (#521 PR 2, plan §7,
// N1, D7 (a)). Today a MessagePack payload became an `AnyCodable` tree (`decodeAnyCodable`, which
// refuses a map key that isn't a string) and then went through the JSON round trip
// (`InboundPayloadDecoding`, which refuses a non-finite number anywhere in the tree). PR 2 decodes
// the `MessagePackValue` straight into the type, after one walk that keeps both refusals.
//
// The corpus mutates a valid value of each fixture type, field by field, at the top level and one
// level into a nested value. Each case's outcome on both paths is compared, on accept/reject and
// on the decoded value (canonical JSON). The non-finite and non-string-key cases must agree
// (refused). Every other disagreement must be a planned one (`expectedDifference`): a refusal of
// what today accepts, never an acceptance of what today refuses. Their count per class is pinned.
//
// Each case the typed decode accepts is also replayed: its recorded tree (`makeRecordPayload()`)
// decoded with today's round trip, as replay decodes it, must give the same value. A live input
// that replay refuses would stop a record replaying.
//
// Duplicate map keys can't differ: the unpacker builds one map before either path reads it, so
// both see the same value. The JSON encodings decode with today's round trip itself (their
// source is an `AnyCodable` tree), so they agree by construction; that is pinned by the source
// each JSON frame carries.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeDeterministicMath
@testable import SwiftStateTreeMessagePack
@testable import SwiftStateTreeTransport

@Suite("The typed MessagePack decode against today's path (#521 PR 2, N1, D7)")
struct PayloadDecodeDifferentialTests {
    /// How a decode ended: refused, or the decoded value as canonical JSON.
    enum Outcome: Equatable, CustomStringConvertible {
        case refused
        case accepted(String)

        var description: String {
            switch self {
            case .refused: return "refused"
            case .accepted(let json): return json
            }
        }
    }

    static func canonical<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .sortedKeys
        encoder.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "+inf", negativeInfinity: "-inf", nan: "nan")
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "<unencodable>"
    }

    /// Today's path: the `AnyCodable` tree, then the round trip.
    static func today<T: Codable>(_ type: T.Type, _ value: MessagePackValue) -> Outcome {
        guard let tree = try? MessagePackPayloadSource.anyCodable(from: value),
              let decoded = try? AnyCodablePayloadSource(tree).decode(type) else { return .refused }
        return .accepted(canonical(decoded))
    }

    /// PR 2's path, with the keeper's intake steps: the walk, the whole-tree check, the decode.
    /// `recording` takes `makeRecordPayload()` instead of `validateRecordable()`, as a keeper with
    /// a recorder does.
    static func typed<T: Codable>(_ type: T.Type, _ value: MessagePackValue, recording: Bool) -> Outcome {
        guard let source = try? MessagePackPayloadSource(validating: value) else { return .refused }
        do {
            if recording { _ = try source.makeRecordPayload() } else { try source.validateRecordable() }
            return .accepted(canonical(try source.decode(type)))
        } catch {
            return .refused
        }
    }

    /// A fixture type's seed as a client sends it on MessagePack: written by the server's encoder
    /// and decoded by the client-frame decoder, so the value is what intake sees.
    static func seedValue(_ message: TransportMessage) throws -> MessagePackValue {
        let encoder = MessagePackTransportMessageEncoder(eventHashes: [:], clientEventHashes: [:], enablePayloadCompression: false)
        let decoded = try MessagePackTransportCodec().decode(TransportMessage.self, from: encoder.encode(message))
        let source: (any PayloadDecodingSource)? = switch decoded.payload {
        case .action(let action): action.action.source
        case .event(.fromClient(let event)): event.source
        default: nil
        }
        return try #require(source as? MessagePackPayloadSource).value
    }

    static let nonFinite: [(String, MessagePackValue)] = [
        ("nan", .double(.nan)), ("+inf", .double(.infinity)), ("-inf", .double(-.infinity)),
        ("float nan", .float(.nan)), ("float +inf", .float(.infinity)), ("float -inf", .float(-.infinity)),
    ]

    /// Values a field is replaced with.
    static let replacements: [(String, MessagePackValue)] = nonFinite + [
        ("int 1", .int(1)), ("int -1", .int(-1)), ("int64 min", .int(.min)), ("uint64 max", .uint(.max)),
        ("uint 7", .uint(7)), ("int 300", .int(300)), ("int 70000", .int(70_000)), ("int 2^40", .int(1 << 40)),
        ("double 3.0", .double(3)), ("double 3.5", .double(3.5)), ("float 2.0", .float(2)), ("float 2.5", .float(2.5)),
        ("double 0.1", .double(0.1)), ("double -0.0", .double(-0.0)), ("double max", .double(.greatestFiniteMagnitude)),
        ("double 1e39", .double(1e39)),
        ("float max", .float(.greatestFiniteMagnitude)), ("double subnormal", .double(.leastNonzeroMagnitude)),
        ("string \"1\"", .string("1")), ("string x", .string("x")), ("binary", .binary(Data("x".utf8))),
        ("nil", .nil), ("bool", .bool(true)), ("empty array", .array([])), ("empty map", .map([:])),
        ("map int key", .map([.int(1): .nil])),
        ("map int key depth 3", .map([.string("a"): .map([.string("b"): .map([.int(1): .nil])])])),
        ("extended", .extended(type: 5, data: Data("x".utf8))),
        // `URL`'s keyed `Codable` form.
        ("keyed url", .map([.string("relative"): .string("https://example.com/")])),
        ("url string", .string("https://example.com/x")),
    ]

    /// Values added under a key no type declares, at the top level and nested two deep.
    static let extras: [(String, MessagePackValue)] = nonFinite.flatMap { name, value in
        [(name, value), ("\(name) two deep", .map([.string("x"): .array([value])]))]
    } + [
        ("map int key", .map([.int(1): .nil])),
        ("map int key depth 3", .map([.string("a"): .map([.string("b"): .map([.int(1): .nil])])])),
        ("string", .string("x")),
    ]

    struct Fixture {
        let name: String
        let message: TransportMessage
        let outcome: (MessagePackValue, _ typed: Bool, _ recording: Bool) -> Outcome
        let replay: (MessagePackValue) -> Outcome
    }

    static func fixture<T: Codable>(_ name: String, _ type: T.Type, _ message: TransportMessage) -> Fixture {
        Fixture(name: name, message: message, outcome: { value, isTyped, recording in
            isTyped ? typed(type, value, recording: recording) : today(type, value)
        }, replay: { value in replayed(type, value) })
    }

    /// Replay's decode of what the live intake recorded: the source's record tree, through
    /// today's round trip. Refused when the live intake refused.
    static func replayed<T: Codable>(_ type: T.Type, _ value: MessagePackValue) -> Outcome {
        guard let source = try? MessagePackPayloadSource(validating: value),
              let record = try? source.makeRecordPayload(),
              let decoded = try? AnyCodablePayloadSource(record).decode(type) else { return .refused }
        return .accepted(canonical(decoded))
    }

    /// A fixture with the types `JSONDecoder` reads in its own way (`URL`, `Data`) and
    /// a nested value, for the mutations one level down.
    struct DiffSpecials: Codable, Sendable {
        struct Inner: Codable, Sendable {
            let int: Int
            let name: String
            let ints: [Int]
            let optional: Int?
        }
        let url: URL
        let data: Data
        let float: Float
        let date: Date
        let inner: Inner
    }

    static let specials = DiffSpecials(
        url: URL(string: "https://example.com/a?b=1")!, data: Data([1, 2, 3]),
        float: 1.5, date: Date(timeIntervalSinceReferenceDate: 12.5), inner: .init(int: 7, name: "n", ints: [1, 2], optional: nil)
    )

    /// A value as a client sends it: its JSON form, then MessagePack.
    static func clientShaped<T: Encodable>(_ value: T) -> AnyCodable {
        (try? JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(value))) ?? AnyCodable(value)
    }

    static var fixtures: [Fixture] {
        let messages = Dictionary(uniqueKeysWithValues: T5Seeds.messages.map { ($0.name, $0.message) })
        return [
            fixture("FuzzLeavesAction", FuzzLeavesAction.self, messages["t5/leaves"]!),
            fixture("FuzzMathAction", FuzzMathAction.self, messages["t5/math"]!),
            fixture("FuzzContainersEvent", FuzzContainersEvent.self, messages["t5/containers"]!),
            fixture("PFClientEvent", PFClientEvent.self, messages["t5/pf-client-event"]!),
            fixture("DiffSpecials", DiffSpecials.self, .event(event: .fromClient(event: AnyClientEvent(
                type: "DiffSpecials", payload: clientShaped(specials)
            )))),
        ]
    }

    /// Each case: a name and the payload value.
    static func corpus(_ seed: MessagePackValue) -> [(String, MessagePackValue)] {
        guard case .map(let fields) = seed else { return [("seed", seed)] }
        var cases: [(String, MessagePackValue)] = [("seed", seed)]
        let keys = fields.keys.compactMap { key -> String? in if case .string(let s) = key { return s } else { return nil } }.sorted()
        for key in keys {
            var missing = fields
            missing[.string(key)] = nil
            cases.append(("\(key): missing", .map(missing)))
            for (name, value) in replacements {
                var replaced = fields
                replaced[.string(key)] = value
                cases.append(("\(key): \(name)", .map(replaced)))
            }
            // One level down, inside a nested value.
            guard case .map(let inner)? = fields[.string(key)] else { continue }
            let innerKeys = inner.keys.compactMap { key -> String? in if case .string(let s) = key { return s } else { return nil } }.sorted()
            for innerKey in innerKeys {
                for (name, value) in replacements {
                    var replacedInner = inner
                    replacedInner[.string(innerKey)] = value
                    var replaced = fields
                    replaced[.string(key)] = .map(replacedInner)
                    cases.append(("\(key).\(innerKey): \(name)", .map(replaced)))
                }
            }
        }
        for (name, value) in extras {
            var extra = fields
            extra[.string("undeclared")] = value
            cases.append(("extra key: \(name)", .map(extra)))
        }
        cases.append(("not a map: nil", .nil))
        cases.append(("not a map: array", .array([])))
        return cases
    }

    /// The planned differences (N1), each a refusal of what today accepts. The SDK sends none of
    /// them: it writes integers as MessagePack integers and strings as strings. Each class is
    /// named in the PR, with its count pinned in `expectedCounts`.
    /// - `integral float`: an integer field sent as an integral float (`3.0`, `-0.0`, a float
    ///   `2.0`). The typed decode takes only MessagePack integers.
    /// - `binary into string`: a string field (`String` or an ID type) sent as binary. Today's
    ///   tree turned binary into base64 text.
    /// - `extended into string`: a string field, `Data` included (a client sends it as base64
    ///   text), sent as a MessagePack extension value. Today's tree turned its bytes into base64
    ///   text too.
    /// A field's kind is its seed value's: an integer, or a string. So the string classes also
    /// count the fields a client sends as strings: `URL` (binary into it is refused; today's
    /// base64 text could parse as a relative URL) and `Data` (base64 text).
    /// These are refusals only because a field's error reaches the top. A hand-written
    /// `init(from:)` that falls back with `try?` sees a different value instead (its fallback's).
    static func expectedDifference(seedField: MessagePackValue?, mutation: String) -> String? {
        switch seedField {
        case .int?, .uint?:
            return ["double -0.0", "double 3.0", "float 2.0"].contains(mutation) ? "integral float" : nil
        case .string?:
            if mutation == "binary" { return "binary into string" }
            if mutation == "extended" { return "extended into string" }
            return nil
        default:
            return nil
        }
    }

    static let expectedCounts: [String: Int] = ["integral float": 66, "binary into string": 9, "extended into string": 11]

    /// The seed's value at a case's field path (`key` or `key.inner`).
    static func seedField(_ seed: MessagePackValue, _ path: String) -> MessagePackValue? {
        var value: MessagePackValue? = seed
        for part in path.split(separator: ".") {
            guard case .map(let map)? = value else { return nil }
            value = map[.string(String(part))]
        }
        return value
    }

    @Test("On MessagePack the typed decode agrees with today's path except where listed; recording doesn't change what is accepted")
    func differential() throws {
        var counts: [String: Int] = [:]
        var unplanned: [String] = []
        var replayViolations: [String] = []
        var recordingViolations: [String] = []
        var caseCount = 0
        for fixture in Self.fixtures {
            let seed = try Self.seedValue(fixture.message)
            #expect(fixture.outcome(seed, true, false) != .refused, "\(fixture.name)'s seed must decode")
            for (name, value) in Self.corpus(seed) {
                caseCount += 1
                let label = "\(fixture.name) \(name)"
                let old = fixture.outcome(value, false, false)
                let new = fixture.outcome(value, true, false)
                if fixture.outcome(value, true, true) != new { recordingViolations.append(label) }
                // What live accepts, replay must accept, with the same value.
                if new != .refused, fixture.replay(value) != new {
                    replayViolations.append("\(label): live \(new), replay \(fixture.replay(value))")
                }
                guard old != new else { continue }
                let parts = name.components(separatedBy: ": ")
                let planned = parts.count == 2 && old != .refused && new == .refused
                    ? Self.expectedDifference(seedField: Self.seedField(seed, parts[0]), mutation: parts[1])
                    : nil
                if let planned {
                    counts[planned, default: 0] += 1
                } else {
                    let direction: String = switch (old, new) {
                    case (.accepted, .refused): "today accepts, typed refuses"
                    case (.refused, .accepted): "today refuses, typed accepts"
                    default: "both accept, values differ"
                    }
                    unplanned.append("\(label): \(direction) (today \(old), typed \(new))")
                }
            }
        }
        #expect(caseCount > 2000)
        #expect(unplanned.isEmpty, "unplanned:\n\(unplanned.sorted().joined(separator: "\n"))")
        #expect(replayViolations.isEmpty, "live accepts, replay doesn't:\n\(replayViolations.sorted().joined(separator: "\n"))")
        #expect(recordingViolations.isEmpty, "\(recordingViolations.sorted())")
        #expect(counts == Self.expectedCounts, "planned counts: \(counts.sorted { $0.key < $1.key })")
    }

    @Test("A hand-written decoder sees JSONDecoder's container behaviour in a client payload")
    func handWrittenDecoders() throws {
        // `decodeNil(forKey:)` on a missing key throws, as `JSONDecoder` does.
        struct NilProbe: Codable {
            enum CodingKeys: String, CodingKey { case x }
            let isNil: Bool
            init(from decoder: Decoder) throws {
                isNil = try decoder.container(keyedBy: CodingKeys.self).decodeNil(forKey: .x)
            }
            func encode(to encoder: Encoder) throws {}
        }
        #expect(Self.today(NilProbe.self, .map([:])) == .refused)
        #expect(Self.typed(NilProbe.self, .map([:]), recording: false) == .refused)
        // An unkeyed decode that throws doesn't move past the element: a fallback reads it.
        struct Fallback: Codable, Equatable {
            var values: [String] = []
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                while !container.isAtEnd {
                    if let int = try? container.decode(Int.self) {
                        values.append("int \(int)")
                    } else {
                        values.append("string \(try container.decode(String.self))")
                    }
                }
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(values)
            }
        }
        let list: MessagePackValue = .array([.string("a"), .int(1), .string("b")])
        #expect(Self.today(Fallback.self, list) == .accepted(#"["string a","int 1","string b"]"#))
        #expect(Self.typed(Fallback.self, list, recording: false) == Self.today(Fallback.self, list))
        // Unkeyed `decodeNil()` past the end throws, as `JSONDecoder` does.
        struct NilAtEnd: Codable {
            init(from decoder: Decoder) throws {
                var container = try decoder.unkeyedContainer()
                _ = try container.decodeNil()
            }
            func encode(to encoder: Encoder) throws {}
        }
        #expect(Self.today(NilAtEnd.self, .array([])) == .refused)
        #expect(Self.typed(NilAtEnd.self, .array([]), recording: false) == .refused)
        // Keyed `superDecoder()` reads `"super"`, though `CodingKeys` has no such case.
        struct SuperProbe: Codable {
            enum CodingKeys: String, CodingKey { case x }
            let value: Int
            init(from decoder: Decoder) throws {
                value = try Int(from: decoder.container(keyedBy: CodingKeys.self).superDecoder())
            }
            func encode(to encoder: Encoder) throws {
                var container = encoder.singleValueContainer()
                try container.encode(value)
            }
        }
        let withSuper: MessagePackValue = .map([.string("super"): .int(5)])
        #expect(Self.today(SuperProbe.self, withSuper) == .accepted("5"))
        #expect(Self.typed(SuperProbe.self, withSuper, recording: false) == Self.today(SuperProbe.self, withSuper))
        #expect(Self.typed(SuperProbe.self, .map([:]), recording: false) == Self.today(SuperProbe.self, .map([:])))
    }

    @Test("A Decimal has no wire form (#597): the MessagePack encoders refuse it, and the decoder reads no number as one")
    func decimalIsRefused() throws {
        struct Box: Codable, Equatable { let d: Decimal }
        let codec = MessagePackTransportCodec()
        // A NaN too: it was written as a bare `NaN` on the JSON encodings (#557), and as a
        // string here.
        for decimal in [Decimal(2.5), Decimal.nan] {
            #expect(throws: MessagePackDirectEncodingError.self, "\(decimal)") { _ = try codec.encode(Box(d: decimal)) }
            #expect(throws: MessagePackDirectEncodingError.self, "\(decimal)") {
                _ = try MessagePackDirectEncoder().encodeAnyCodable(AnyCodable(decimal))
            }
            #expect(throws: MessagePackDirectEncodingError.self, "\(decimal)") {
                _ = try MessagePackValueEncoder().encode(Box(d: decimal))
            }
        }
        // An NSDecimalNumber in an AnyCodable, on every platform, boxed once or twice.
        #expect(throws: MessagePackDirectEncodingError.self) {
            _ = try MessagePackDirectEncoder().encodeAnyCodable(AnyCodable(NSDecimalNumber(string: "2.5")))
        }
        #expect(throws: MessagePackDirectEncodingError.self) {
            _ = try MessagePackDirectEncoder().encodeAnyCodable(AnyCodable(AnyCodable(NSDecimalNumber(string: "2.5"))))
        }
        for value: MessagePackValue in [.int(2), .double(2.5), .string("2.5")] {
            #expect(throws: DecodingError.self, "\(value)") {
                _ = try MessagePackValueDecoder().decode(Box.self, from: .map([.string("d"): value]))
            }
        }
    }

    @Test("An AnyCodable field holds what the round trip built: an integral float as an Int, binary as base64")
    func anyCodableField() throws {
        struct Box: Codable { let a: AnyCodable }
        func decoded(_ value: MessagePackValue) throws -> Any {
            try MessagePackPayloadSource(validating: .map([.string("a"): value])).decode(Box.self).a.base
        }
        #expect(try decoded(.double(3)) as? Int == 3)
        #expect(try decoded(.binary(Data([1, 2, 3]))) as? String == "AQID")
        #expect(try decoded(.double(2.5)) as? Double == 2.5)
        // A frame the server builds decodes it from the value, as before.
        let plain = try MessagePackValueDecoder().decode(Box.self, from: .map([.string("a"): .double(3)])).a.base
        #expect(plain as? Double == 3)
    }

    @Test("A double for a Float field rounds once from its shortest text, as JSONDecoder parsed it")
    func floatFromDoubleMidpoint() {
        struct Box: Codable { let f: Float }
        // Float midpoints: ties-to-even on the exact double, the other way from the shortest text.
        let midpoints = [1 + 0x1p-24, 3 + 0x1p-22, -(1 + 0x1p-24), 0x1p-126 * (1 + 0x1p-24), 1 + 3 * 0x1p-24]
        for double in midpoints {
            let box: MessagePackValue = .map([.string("f"): .double(double)])
            #expect(Self.today(Box.self, box) != .refused, "\(double)")
            #expect(Self.typed(Box.self, box, recording: false) == Self.today(Box.self, box), "\(double)")
        }
    }

    @Test("An integer for a Float field rounds once, as the round trip parsed its text")
    func floatFromInteger() {
        struct Box: Codable { let f: Float }
        // 2^62 + 2^38 + 1: rounded through Double it lands on a midpoint and goes to 2^62.
        let magnitude: Int64 = (1 << 62) + (1 << 38) + 1
        let values: [MessagePackValue] = [.int(magnitude), .uint(UInt64(magnitude)), .int(-magnitude)]
        for value in values {
            let box: MessagePackValue = .map([.string("f"): value])
            #expect(Self.typed(Box.self, box, recording: false) == Self.today(Box.self, box), "\(value)")
        }
    }

    @Test("A Float field refuses a double it can't hold, as the round trip did",
          arguments: [Double.greatestFiniteMagnitude, 1e39, -1e39, .leastNonzeroMagnitude, 1e-50])
    func floatRange(double: Double) {
        struct Box: Codable { let f: Float }
        #expect(throws: DecodingError.self) {
            _ = try MessagePackValueDecoder().decode(Box.self, from: .map([.string("f"): .double(double)]))
        }
        #expect(Self.today(Box.self, .map([.string("f"): .double(double)])) == .refused)
    }

    @Test("A JSON frame's payload carries an AnyCodable source: today's round trip, unchanged",
          arguments: [TransportEncoding.json, .opcodeJsonArray])
    func jsonEncodingsUseTodaysPath(encoding: TransportEncoding) throws {
        let pipeline = MessageDecodingPipeline(codec: encoding.makeCodec(), opcodeDecoder: OpcodeTransportMessageDecoder(), enableLegacyJoin: false)
        for frame in T5Seeds.frames where frame.encoding.rawValue == encoding.rawValue {
            let message = try pipeline.decode(Data(frame.bytes))
            let source: (any PayloadDecodingSource)? = switch message.payload {
            case .action(let action): action.action.source
            case .event(.fromClient(let event)): event.source
            default: nil
            }
            #expect(source is AnyCodablePayloadSource, "\(frame.name)")
        }
    }
}
