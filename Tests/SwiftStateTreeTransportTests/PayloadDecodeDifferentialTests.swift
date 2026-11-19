// Tests/SwiftStateTreeTransportTests/PayloadDecodeDifferentialTests.swift
//
// The typed MessagePack decode against today's path, on the same payloads (#521 PR 2, plan §7,
// N1, D7 (a)). Today a MessagePack payload became an `AnyCodable` tree (`decodeAnyCodable`, which
// refuses a map key that isn't a string) and then went through the JSON round trip
// (`InboundPayloadDecoding`, which refuses a non-finite number anywhere in the tree). PR 2 decodes
// the `MessagePackValue` straight into the type, after one walk that keeps both refusals.
//
// The corpus mutates a valid value of each fixture type, field by field. Each case's outcome on
// both paths is compared, on accept/reject and on the decoded value (canonical JSON). The
// non-finite and non-string-key cases must agree (refused). Every other disagreement is listed in
// `expectedDifferences`, with its direction; the test fails on any case not listed and on any
// listed case that no longer differs.
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
    }

    static func fixture<T: Codable>(_ name: String, _ type: T.Type, _ message: TransportMessage) -> Fixture {
        Fixture(name: name, message: message) { value, isTyped, recording in
            isTyped ? typed(type, value, recording: recording) : today(type, value)
        }
    }

    static var fixtures: [Fixture] {
        let messages = Dictionary(uniqueKeysWithValues: T5Seeds.messages.map { ($0.name, $0.message) })
        return [
            fixture("FuzzLeavesAction", FuzzLeavesAction.self, messages["t5/leaves"]!),
            fixture("FuzzMathAction", FuzzMathAction.self, messages["t5/math"]!),
            fixture("FuzzContainersEvent", FuzzContainersEvent.self, messages["t5/containers"]!),
            fixture("PFClientEvent", PFClientEvent.self, messages["t5/pf-client-event"]!),
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

    /// The cases where the typed decode and today's path disagree on MessagePack, by direction
    /// (N1). Each is named in the PR.
    static let expectedDifferences: Set<String> = []

    @Test("On MessagePack the typed decode agrees with today's path except where listed; recording doesn't change what is accepted")
    func differential() throws {
        var differences: Set<String> = []
        var mustAgreeViolations: [String] = []
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
                guard old != new else { continue }
                let mustAgree = Self.nonFinite.contains { name.hasSuffix(": \($0.0)") || name.hasSuffix(": \($0.0) two deep") }
                    || name.contains("map int key")
                if mustAgree { mustAgreeViolations.append("\(label): today \(old), typed \(new)") }
                let direction: String = switch (old, new) {
                case (.accepted, .refused): "today accepts, typed refuses"
                case (.refused, .accepted): "today refuses, typed accepts"
                default: "both accept, values differ"
                }
                differences.insert("\(label): \(direction)")
            }
        }
        #expect(caseCount > 500)
        #expect(mustAgreeViolations.isEmpty, "\(mustAgreeViolations.sorted().joined(separator: "\n"))")
        #expect(recordingViolations.isEmpty, "\(recordingViolations.sorted())")
        let unlisted = differences.subtracting(Self.expectedDifferences).sorted()
        let gone = Self.expectedDifferences.subtracting(differences).sorted()
        #expect(unlisted.isEmpty, "not listed:\n\(unlisted.joined(separator: "\n"))")
        #expect(gone.isEmpty, "listed but no longer differ:\n\(gone.joined(separator: "\n"))")
    }

    @Test("Decimal decodes from each numeric kind as the round trip read it, and its keyed form still decodes")
    func decimal() throws {
        struct Box: Codable, Equatable { let d: Decimal }
        let cases: [(MessagePackValue, String)] = [
            (.int(-2), "-2"), (.uint(7), "7"), (.float(2.5), "2.5"), (.double(2.5), "2.5"), (.double(0.1), "0.1"),
        ]
        for (value, expected) in cases {
            let decoded = try MessagePackValueDecoder().decode(Box.self, from: .map([.string("d"): value]))
            #expect(decoded.d == Decimal(string: expected), "\(value)")
            #expect(Self.today(Box.self, .map([.string("d"): value])) == .accepted(Self.canonical(decoded)), "\(value)")
        }
        // A frame the server builds writes `Decimal`'s keyed `Codable` form: it round-trips.
        let codec = MessagePackTransportCodec()
        for decimal in [Decimal(string: "2.5")!, Decimal(string: "-0.001")!, Decimal(12345678901234567890 as UInt64)] {
            #expect(try codec.decode(Box.self, from: codec.encode(Box(d: decimal))) == Box(d: decimal))
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
