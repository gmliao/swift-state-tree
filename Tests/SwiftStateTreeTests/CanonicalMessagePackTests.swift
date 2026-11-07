// Tests/SwiftStateTreeTests/CanonicalMessagePackTests.swift

import Crypto
import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Helpers

private func hex(_ bytes: [UInt8]) -> String {
    bytes.map { String(format: "%02x", $0) }.joined()
}

private func encodedHex<T: Encodable>(_ value: T) throws -> String {
    hex(try CanonicalMessagePack.encode(value))
}

/// One value in a keyed container, so scalars go through the same path as record fields.
private struct Box<T: Codable>: Codable {
    var v: T
}

private func boxHex<T: Codable>(_ value: T) throws -> String {
    // 0x81 fixmap(1), 0xa1 0x76 "v"
    let full = try encodedHex(Box(v: value))
    #expect(full.hasPrefix("81a176"))
    return String(full.dropFirst(6))
}

// MARK: - Integers

@Test("Integers use the shortest form: unsigned forms for non-negative, signed for negative")
func integersShortestForm() throws {
    let cases: [(Int64, String)] = [
        (0, "00"), (127, "7f"), (128, "cc80"), (255, "ccff"), (256, "cd0100"),
        (65535, "cdffff"), (65536, "ce00010000"), (4_294_967_295, "ceffffffff"),
        (4_294_967_296, "cf0000000100000000"), (Int64.max, "cf7fffffffffffffff"),
        (-1, "ff"), (-32, "e0"), (-33, "d0df"), (-128, "d080"), (-129, "d1ff7f"),
        (-32768, "d18000"), (-32769, "d2ffff7fff"), (Int64(Int32.min), "d280000000"),
        (Int64(Int32.min) - 1, "d3ffffffff7fffffff"), (Int64.min, "d38000000000000000"),
    ]
    for (value, expected) in cases {
        #expect(try boxHex(value) == expected, "\(value)")
    }
    #expect(try boxHex(UInt64.max) == "cfffffffffffffffff")
    // The width of the Swift type doesn't matter, only the value.
    #expect(try boxHex(Int8(5)) == "05")
    #expect(try boxHex(UInt16(300)) == "cd012c")
    #expect(try boxHex(Int32(-1)) == "ff")
}

// MARK: - Floats

@Test("Floats are always float64; Float is widened; one canonical NaN; -0.0 and infinities kept")
func floatsAlwaysFloat64() throws {
    #expect(try boxHex(1.5) == "cb3ff8000000000000")
    #expect(try boxHex(Float(1.5)) == "cb3ff8000000000000")
    // 0.1 as Float widened: not the Double 0.1
    #expect(try boxHex(Float(0.1)) == "cb3fb99999a0000000")
    #expect(try boxHex(0.1) == "cb3fb999999999999a")
    #expect(try boxHex(-0.0) == "cb8000000000000000")
    #expect(try boxHex(Double.infinity) == "cb7ff0000000000000")
    #expect(try boxHex(-Double.infinity) == "cbfff0000000000000")
    #expect(try boxHex(Double.nan) == "cb7ff8000000000000")
    #expect(try boxHex(Double(bitPattern: 0x7ff0_0000_0000_0001)) == "cb7ff8000000000000")
    #expect(try boxHex(-Double.nan) == "cb7ff8000000000000")
    #expect(try boxHex(Float.nan) == "cb7ff8000000000000")
}

@Test("A float64 decodes into Float only when it round-trips exactly")
func floatNarrowing() throws {
    let widened = try CanonicalMessagePack.encode(Box(v: Float(0.1)))
    #expect(try CanonicalMessagePack.decode(Box<Float>.self, from: widened).v == Float(0.1))
    let double = try CanonicalMessagePack.encode(Box(v: 0.1))
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<Float>.self, from: double)
    }
}

// MARK: - Strings, arrays, nil

@Test("Strings, arrays and maps use their shortest forms")
func shortestContainerForms() throws {
    #expect(try boxHex("") == "a0")
    #expect(try boxHex(String(repeating: "a", count: 31)) == "bf" + String(repeating: "61", count: 31))
    #expect(try boxHex(String(repeating: "a", count: 32)) == "d920" + String(repeating: "61", count: 32))
    #expect(try boxHex(String(repeating: "a", count: 256)).hasPrefix("da0100"))
    #expect(try boxHex([Int]()) == "90")
    #expect(try boxHex(Array(repeating: 1, count: 15)) == "9f" + String(repeating: "01", count: 15))
    #expect(try boxHex(Array(repeating: 1, count: 16)) == "dc0010" + String(repeating: "01", count: 16))
    #expect(try boxHex([String: Int]()) == "80")
    #expect(try boxHex(true) == "c3")
    #expect(try boxHex(false) == "c2")
}

private struct Optionals: Codable, Equatable {
    var omitted: Int?
    var explicit: Int?

    enum CodingKeys: String, CodingKey { case omitted, explicit }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(omitted, forKey: .omitted)
        try container.encode(explicit, forKey: .explicit)
    }
}

@Test("An omitted optional leaves its key out; an explicit nil is 0xc0")
func omittedAndExplicitNil() throws {
    // fixmap(1) "explicit" nil
    #expect(try encodedHex(Optionals(omitted: nil, explicit: nil)) == "81a8" + hex(Array("explicit".utf8)) + "c0")
    let decoded = try CanonicalMessagePack.decode(Optionals.self, from: try CanonicalMessagePack.encode(Optionals(omitted: nil, explicit: nil)))
    #expect(decoded == Optionals(omitted: nil, explicit: nil))
}

// MARK: - Map keys

private struct Keys: Codable, Equatable {
    var b = 1
    var a = 2
    var B = 3
    var aa = 4
    var é = 5
}

@Test("Map keys are sorted by their UTF-8 bytes")
func mapKeysSortedByUTF8() throws {
    // "B" (42) < "a" (61) < "aa" < "b" (62) < "é" (c3 a9)
    let expected = "85" + "a142" + "03" + "a161" + "02" + "a26161" + "04" + "a162" + "01" + "a2c3a9" + "05"
    #expect(try encodedHex(Keys()) == expected)
}

@Test("Keys are written as their own UTF-8, with no normalization (NFC and NFD differ)")
func keysNotNormalized() throws {
    let nfc = ["\u{e9}": 1]
    let nfd = ["e\u{301}": 1]
    #expect(try encodedHex(nfc) == "81a2c3a901")
    #expect(try encodedHex(nfd) == "81a365cc8101")
}

@Test("Int-keyed dictionaries are written under the keys' string form, sorted as strings")
func intKeyedDictionary() throws {
    let value: [Int: Int] = [10: 1, 2: 2, 1: 3]
    #expect(try encodedHex(value) == "83" + "a131" + "03" + "a23130" + "01" + "a132" + "02")
    #expect(try CanonicalMessagePack.decode([Int: Int].self, from: try CanonicalMessagePack.encode(value)) == value)
}

private struct DuplicateKey: Encodable {
    enum CodingKeys: String, CodingKey { case a }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .a)
        try container.encode(2, forKey: .a)
    }
}

@Test("A key encoded twice in one container is rejected")
func duplicateKeyRejected() {
    #expect(throws: CanonicalMessagePackError.duplicateKey("a")) {
        _ = try CanonicalMessagePack.encode(DuplicateKey())
    }
}

private struct PointKey: Codable, Hashable {
    var x: Int
}

@Test("Dictionaries with other key types and sets are rejected (their order isn't deterministic)")
func unorderedCollectionsRejected() {
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.encode([PointKey(x: 1): 1, PointKey(x: 2): 2])
    }
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.encode(Box(v: Set([1, 2, 3])))
    }
}

// MARK: - Dates

@Test("Dates are ISO-8601 at whole seconds with Z, truncated toward negative infinity")
func datesTruncatedWithZ() throws {
    let cases: [(TimeInterval, String)] = [
        (0, "1970-01-01T00:00:00Z"),
        (1_700_000_000.9, "2023-11-14T22:13:20Z"),
        (-1.5, "1969-12-31T23:59:58Z"),
        (-86_400 * 36_525, "1869-12-31T00:00:00Z"),
        (951_782_400, "2000-02-29T00:00:00Z"),
    ]
    for (seconds, expected) in cases {
        let date = Date(timeIntervalSince1970: seconds)
        #expect(try boxHex(date) == "b4" + hex(Array(expected.utf8)), "\(seconds)")
        let decoded = try CanonicalMessagePack.decode(Box<Date>.self, from: try CanonicalMessagePack.encode(Box(v: date)))
        #expect(decoded.v.timeIntervalSince1970 == seconds.rounded(.down), "\(seconds)")
    }
}

// MARK: - Round trip and strictness

private struct Composite: Codable {
    var name: String
    var count: Int
    var ratio: Double
    var small: Float
    var flags: [Bool]
    var nested: [String: [Int]]
    var byID: [Int: String]
    var maybe: String?
    var payload: AnyCodable
}

@Test("A composite value round-trips")
func compositeRoundTrip() throws {
    let value = Composite(
        name: "hero", count: -3, ratio: 0.25, small: 1.5, flags: [true, false],
        nested: ["b": [1, 2], "a": []], byID: [3: "c", 1: "a"], maybe: nil,
        payload: AnyCodable(["x": 1, "y": 2.5, "s": "t"] as [String: Any])
    )
    let bytes = try CanonicalMessagePack.encode(value)
    let decoded = try CanonicalMessagePack.decode(Composite.self, from: bytes)
    #expect(decoded.name == value.name && decoded.count == value.count && decoded.ratio == value.ratio)
    #expect(decoded.small == value.small && decoded.flags == value.flags && decoded.nested == value.nested)
    #expect(decoded.byID == value.byID && decoded.maybe == nil)
    // Re-encoding the decoded value gives the same bytes.
    #expect(try CanonicalMessagePack.encode(decoded) == bytes)
}

@Test("An integral Double stays a Double through AnyCodable")
func integralDoubleThroughAnyCodable() throws {
    let bytes = try CanonicalMessagePack.encode(Box(v: AnyCodable(3.0)))
    let decoded = try CanonicalMessagePack.decode(Box<AnyCodable>.self, from: bytes)
    #expect(decoded.v.base is Double)
    let intBytes = try CanonicalMessagePack.encode(Box(v: AnyCodable(3)))
    #expect(try CanonicalMessagePack.decode(Box<AnyCodable>.self, from: intBytes).v.base is Int)
}

@Test("The decoder is strict about types and rejects truncated input")
func decoderStrict() throws {
    let intBytes = try CanonicalMessagePack.encode(Box(v: 3))
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<Double>.self, from: intBytes)
    }
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<String>.self, from: intBytes)
    }
    let big = try CanonicalMessagePack.encode(Box(v: 300))
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<UInt8>.self, from: big)
    }
    let text = try CanonicalMessagePack.encode(Box(v: "hello"))
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<String>.self, from: Array(text.dropLast()))
    }
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.decode(Box<String>.self, from: text + [0x00])
    }
}

// MARK: - Cross-architecture identity

/// The edge set encoded once, compared byte for byte on every platform (macOS arm64 locally,
/// Linux x86_64 in CI). A change of this value is a format change.
@Test("The edge set encodes to the committed bytes")
func edgeSetCommittedBytes() throws {
    struct EdgeSet: Encodable {
        var ints: [Int64] = [0, 127, 128, -1, -32, -33, Int64.min, Int64.max]
        var uint: UInt64 = .max
        var doubles: [Double] = [0.1, -0.0, .infinity, -.infinity, .nan, 1e300, 5e-324]
        var floats: [Float] = [0.1, 1.5, .nan]
        var keys: [String: Int] = ["B": 1, "a": 2, "\u{e9}": 3, "\u{1F600}": 4, "": 5]
        var nfd: [String: Int] = ["e\u{301}": 1]
        var dates: [Date] = [Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -1.5), Date(timeIntervalSince1970: 1_700_000_000.9)]
        var omitted: Int? = nil
        var nested: [String: [String: [Int]]] = ["z": ["y": [1]], "a": [:]]
        var empty: [Int] = []
        var emptyMap: [String: Int] = [:]
    }
    let bytes = try CanonicalMessagePack.encode(EdgeSet())
    #expect(hex(bytes) == CanonicalMessagePackFixtures.edgeSetHex, "got \(hex(bytes))")
}

/// A tracked hero-defense record (JSON 2.5) read as `AnyCodable` and encoded canonically. The
/// record holds integers, strings, booleans and nulls only, so the value tree is the same as the
/// JSON's, and the expected digest comes from a separate reference encoder.
@Test("A hero-defense record encodes to the committed digest")
func heroDefenseRecordDigest() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Examples/GameDemo/reevaluation-records/3-hero-defense.json")
    let record = try JSONDecoder().decode(AnyCodable.self, from: Data(contentsOf: url))
    let bytes = try CanonicalMessagePack.encode(record)
    #expect(bytes.count == CanonicalMessagePackFixtures.heroDefenseRecordByteCount)
    let digest = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    #expect(digest == CanonicalMessagePackFixtures.heroDefenseRecordSHA256)
    // It decodes back to a value that encodes to the same bytes.
    let decoded = try CanonicalMessagePack.decode(AnyCodable.self, from: bytes)
    #expect(try CanonicalMessagePack.encode(decoded) == bytes)
}

private struct DuplicateNestedKey: Encodable {
    enum CodingKeys: String, CodingKey { case a }
    enum Inner: String, CodingKey { case b }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(1, forKey: .a)
        var nested = container.nestedContainer(keyedBy: Inner.self, forKey: .a)
        try nested.encode(2, forKey: .b)
    }
}

@Test("A key repeated through a nested container (a non-throwing call) is rejected when the encode ends")
func duplicateNestedKeyRejected() {
    #expect(throws: CanonicalMessagePackError.duplicateKey("a")) {
        _ = try CanonicalMessagePack.encode(DuplicateNestedKey())
    }
}

@Test("Invalid UTF-8 and a duplicate map key in the input are rejected")
func decoderRejectsInvalidInput() {
    // fixmap(1) "v" → str(1) 0xff
    #expect(throws: CanonicalMessagePackError.invalidUTF8) {
        _ = try CanonicalMessagePack.decode(Box<String>.self, from: [0x81, 0xa1, 0x76, 0xa1, 0xff])
    }
    // fixmap(2) "v" 1, "v" 2
    #expect(throws: CanonicalMessagePackError.duplicateKey("v")) {
        _ = try CanonicalMessagePack.decode(Box<Int>.self, from: [0x82, 0xa1, 0x76, 0x01, 0xa1, 0x76, 0x02])
    }
}

@Test("A date outside 0001-9999 is rejected")
func dateOutOfRangeRejected() throws {
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.encode(Box(v: Date(timeIntervalSince1970: 253_402_300_800)))
    }
    #expect(throws: CanonicalMessagePackError.self) {
        _ = try CanonicalMessagePack.encode(Box(v: Date(timeIntervalSince1970: -62_135_596_801)))
    }
    #expect(try boxHex(Date(timeIntervalSince1970: 253_402_300_799)) == "b4" + hex(Array("9999-12-31T23:59:59Z".utf8)))
    #expect(try boxHex(Date(timeIntervalSince1970: -62_135_596_800)) == "b4" + hex(Array("0001-01-01T00:00:00Z".utf8)))
}
