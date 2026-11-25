// Tests/SwiftStateTreeTests/RecordPayloadBytesTests.swift
//
// The codec seam of #700 K1a (plan §3.11): a client payload's source gives the bytes a record
// keeps (`recordBytes()`, in its `recordEncoding`), and `RecordPayloadDecoders` decodes them with
// the decoder that encoding's transport uses live. The bytes must decode to the value the live
// decode gave, and be the same bytes in every process.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeMessagePack

/// A payload with every value the two live decoders read in a way of their own: dates, data,
/// URLs, float widths, wide and narrow integers, a missing optional, a nested value and a
/// dictionary keyed by client strings.
private struct RecordBytesFixture: Codable, Equatable {
    struct Inner: Codable, Equatable {
        let label: String
        let values: [Int]
    }

    let date: Date
    let data: Data
    let url: URL
    let single: Float
    let double: Double
    let wide: UInt64
    let narrow: Int8
    let negative: Int
    let missing: String?
    let flag: Bool
    let inner: Inner
    let scores: [String: Int]

    static func sample(wide: UInt64 = .max) -> RecordBytesFixture { RecordBytesFixture(
        date: Date(timeIntervalSinceReferenceDate: 812_345_678.25),
        data: Data([0, 1, 2, 250]),
        url: URL(string: "https://example.com/a/b?c=1")!,
        single: 1.5,
        double: 0.1,
        wide: wide,
        narrow: -7,
        negative: -40_000,
        missing: nil,
        flag: true,
        inner: Inner(label: "caf\u{E9}", values: [1, 200, 70_000]),
        scores: ["b": 2, "a": 1, "cafe\u{301}": 3]
    ) }
}

/// The 16-key object of the cross-process test, as a client's JSON tree.
private func sixteenKeyTree() -> AnyCodable {
    var object: [String: Any] = [:]
    for index in 0..<16 { object["k\(index)"] = index }
    return AnyCodable(object)
}

/// Its canonical JSON: keys in byte order.
private let sixteenKeyCanonical: String = {
    let keys = (0..<16).map { "k\($0)" }.sorted { Array($0.utf8).lexicographicallyPrecedes(Array($1.utf8)) }
    return "{" + keys.map { "\"\($0)\":\($0.dropFirst())" }.joined(separator: ",") + "}"
}()

@Suite("A recorded client payload's bytes decode as live (#700 K1a, codec seam)")
struct RecordPayloadBytesTests {
    @Test("A JSON tree's record bytes decode, with each decoder set, to the live value")
    func jsonTreeRoundTrips() throws {
        // The tree a JSON client frame decodes to.
        // A JSON client's tree holds an integer past `Int.max` as a `Double`, so live can't
        // decode `UInt64.max` from JSON at all; the widest value it can is `Int.max`.
        let sample = RecordBytesFixture.sample(wide: UInt64(Int.max))
        let tree = try JSONDecoder().decode(AnyCodable.self, from: JSONEncoder().encode(sample))
        let source = AnyCodablePayloadSource(tree)
        let live = try source.decode(RecordBytesFixture.self)
        #expect(live == sample)
        #expect(source.recordEncoding == .json)
        let bytes = try source.recordBytes()
        for decoders in [RecordPayloadDecoders.jsonOnly, .standard] {
            let replayed = try decoders.makeSource(bytes, .json).decode(RecordBytesFixture.self)
            #expect(replayed == live)
        }
    }

    @Test("A MessagePack value's record bytes decode to the live value")
    func messagePackValueRoundTrips() throws {
        // The value a MessagePack client frame unpacks to.
        let value = try unpack(pack(MessagePackValueEncoder().encode(RecordBytesFixture.sample())))
        let source = try MessagePackPayloadSource(validating: value)
        let live = try source.decode(RecordBytesFixture.self)
        #expect(live == RecordBytesFixture.sample())
        #expect(source.recordEncoding == .messagepack)
        let replayed = try RecordPayloadDecoders.standard.makeSource(source.recordBytes(), .messagepack)
            .decode(RecordBytesFixture.self)
        #expect(replayed == live)
    }

    @Test("A key in another normalization decodes from the record bytes as live, on both encodings")
    func otherNormalizationKeyDecodes() throws {
        struct Keyed: Codable, Equatable {
            let label: String
            enum CodingKeys: String, CodingKey { case label = "caf\u{E9}" }
        }
        let tree = AnyCodable(["cafe\u{301}": "x"] as [String: Any])
        let jsonSource = AnyCodablePayloadSource(tree)
        #expect(try RecordPayloadDecoders.standard.makeSource(jsonSource.recordBytes(), .json).decode(Keyed.self)
            == jsonSource.decode(Keyed.self))
        let mpSource = try MessagePackPayloadSource(validating: .map([.string("cafe\u{301}"): .string("x")]))
        #expect(try RecordPayloadDecoders.standard.makeSource(mpSource.recordBytes(), .messagepack).decode(Keyed.self)
            == mpSource.decode(Keyed.self))
    }

    @Test("MessagePack record bytes sort map keys by their bytes and pack each integer in its smallest form")
    func messagePackBytesAreCanonical() throws {
        let source = try MessagePackPayloadSource(validating: .map([
            .string("b"): .int(-1),
            .string("a"): .uint(200),
            .string("c"): .int(1),
        ]))
        // fixmap(3), "a" -> uint8 200, "b" -> negative fixint -1, "c" -> positive fixint 1.
        #expect(Array(try source.recordBytes()) == [0x83, 0xa1, 0x61, 0xcc, 200, 0xa1, 0x62, 0xff, 0xa1, 0x63, 0x01])
    }

    @Test("A JSON tree's record bytes are its canonical JSON, keys in byte order")
    func jsonBytesAreCanonical() throws {
        let bytes = try AnyCodablePayloadSource(sixteenKeyTree()).recordBytes()
        #expect(String(decoding: bytes, as: UTF8.self) == sixteenKeyCanonical)
    }

    @Test("Canonical JSON is the same bytes in two processes, each with its own hash seed (exit test)")
    func canonicalJSONIsStableAcrossProcesses() async throws {
        for _ in 0..<2 {
            let result = await #expect(processExitsWith: .success, observing: [\.standardOutputContent]) {
                let bytes = try AnyCodablePayloadSource(sixteenKeyTree()).recordBytes()
                print(String(decoding: bytes, as: UTF8.self), terminator: "")
            }
            let printed = result.map { String(decoding: $0.standardOutputContent, as: UTF8.self) }
            #expect(printed == sixteenKeyCanonical)
        }
    }

    @Test("A record's bytes refuse what the live intake refuses: a non-finite number")
    func nonFiniteIsRefused() throws {
        #expect(throws: (any Error).self) { try AnyCodablePayloadSource(AnyCodable(["x": Double.nan] as [String: Any])).recordBytes() }
        let source = try MessagePackPayloadSource(validating: .map([.string("x"): .double(.infinity)]))
        #expect(throws: (any Error).self) { try source.recordBytes() }
    }

    @Test("JSON-only decoders refuse a MessagePack record before any decode, with the named error")
    func jsonOnlyRefusesMessagePack() throws {
        #expect(throws: ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)) {
            try RecordPayloadDecoders.jsonOnly.check(.messagepack)
        }
        #expect(throws: ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack)) {
            _ = try RecordPayloadDecoders.jsonOnly.makeSource(Data([0xc0]), .messagepack)
        }
        try RecordPayloadDecoders.jsonOnly.check(.json)
        try RecordPayloadDecoders.standard.check(.messagepack)
        #expect(ReevaluationRecordPayloadError.noDecoder(encoding: .messagepack).description.contains("RecordPayloadDecoders.standard"))
    }

    @Test("A recorded tree has no bytes to record again")
    func recordedTreeHasNoBytes() {
        let source = RecordPayloadSource(AnyCodable(1))
        #expect(source.recordEncoding == nil)
        #expect(throws: RecordPayloadSourceHasNoBytes.self) { try source.recordBytes() }
    }

    @Test("JSON record bytes deeper than the client limit are refused before they decode")
    func deepJSONBytesAreRefused() {
        let deep = Data((String(repeating: "[", count: PayloadNesting.clientFrameMaxDepth + 2)
            + String(repeating: "]", count: PayloadNesting.clientFrameMaxDepth + 2)).utf8)
        #expect(throws: (any Error).self) { _ = try RecordPayloadDecoders.jsonOnly.makeSource(deep, .json) }
    }
}
