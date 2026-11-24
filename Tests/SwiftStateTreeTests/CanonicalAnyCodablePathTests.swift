// Tests/SwiftStateTreeTests/CanonicalAnyCodablePathTests.swift
//
// The canonical codec's depth bound and its direct `AnyCodable` paths (#802).
// - The encoder checks the depth on the way down, so a value nested past `maxDepth` is refused
//   before it recurses further, not after the whole tree is built.
// - `AnyCodable` is encoded and decoded without its own `encode(to:)` / `init(from:)`: the same
//   bytes and values as those (checked here against them, case by case), at a fraction of the
//   stack.
// Everything that recurses deep runs on a Foundation thread with an 8 MiB stack: the generic
// path at the limit doesn't fit Darwin's 544 KiB cooperative-pool thread in a debug build, and a
// regression must fail a test, not crash the test process.

import Foundation
import Testing
@testable import SwiftStateTree

private final class LargeThreadResult<R>: @unchecked Sendable {
    var value: R?
}

/// Runs `body` on a new thread with an 8 MiB stack and waits for it.
private func onLargeThread<R>(_ body: @escaping () -> R) -> R {
    let result = LargeThreadResult<R>()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        result.value = body()
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    done.wait()
    return result.value!
}

/// The address of a local in the caller's frame: the stack's current depth.
@inline(never)
private func stackAddress() -> Int {
    var local = 0
    return withUnsafeMutablePointer(to: &local) { Int(bitPattern: $0) }
}

/// The deepest stack address the `AnyCodable` paths reach while `body` runs, as bytes below the
/// address at the start.
private final class StackReach: @unchecked Sendable {
    private var top = 0
    private var deepest = Int.max

    static func measure(_ body: () throws -> Void) rethrows -> Int {
        let reach = StackReach()
        reach.top = stackAddress()
        try CanonicalMessagePack.$stackProbeForTesting.withValue({ reach.note() }) {
            try body()
        }
        return reach.deepest == Int.max ? 0 : reach.top - reach.deepest
    }

    private func note() {
        deepest = min(deepest, stackAddress())
    }
}

/// Counts the values the `AnyCodable` paths visit.
private final class VisitCount: @unchecked Sendable {
    var count = 0
}

private func generic<R>(_ body: () throws -> R) rethrows -> R {
    try CanonicalMessagePack.$anyCodableGenericForTesting.withValue(true) { try body() }
}

/// What an encode or decode gave: the bytes or value, or the error's type and text.
private enum Outcome<Value>: CustomStringConvertible {
    case value(Value)
    case error(String)

    init(_ body: () throws -> Value) {
        do {
            self = .value(try body())
        } catch {
            self = .error("\(type(of: error)): \(error)")
        }
    }

    var description: String {
        switch self {
        case .value(let value): return "value \(value)"
        case .error(let text): return "error \(text)"
        }
    }
}

/// Two decoded `AnyCodable` bases are the same: the same Swift types and the same values.
private func sameBase(_ a: Any, _ b: Any) -> Bool {
    switch (a, b) {
    case (is Void, is Void): return true
    case let (x as Bool, y as Bool): return x == y
    case let (x as Int, y as Int): return x == y
    case let (x as Double, y as Double): return x.bitPattern == y.bitPattern
    case let (x as String, y as String): return x.utf8.elementsEqual(y.utf8)
    case let (x as [Any], y as [Any]):
        return x.count == y.count && zip(x, y).allSatisfy { sameBase($0, $1) }
    case let (x as [String: Any], y as [String: Any]):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { sameBase(value, $0) } ?? false }
    default: return false
    }
}

private struct Point: Codable, Equatable {
    let x: Int
    let label: String
}

/// Two keys that `String` equates (NFC and NFD "é") but the format keeps apart.
private struct TwoSpellings: Encodable {
    struct Key: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(1, forKey: Key("\u{E9}"))
        try container.encode(2, forKey: Key("e\u{301}"))
    }
}

private struct AnyFieldHolder: Codable {
    let inner: AnyCodable
}

/// A chain of maps `levels` deep, as the record loader decodes one (`[String: Any]` all the way).
private func mapChain(_ levels: Int, leaf: Any = 1) -> Any {
    var value = leaf
    for _ in 0..<levels { value = ["k": value] as [String: Any] }
    return value
}

private final class ChainLink: Encodable {
    let next: ChainLink?
    init(next: ChainLink?) { self.next = next }
}

/// Notes when it is encoded: it sits at the bottom of a chain the bound must stop above.
private struct BottomMarker: Encodable {
    let reached: VisitCount
    func encode(to encoder: Encoder) throws {
        reached.count += 1
        var container = encoder.singleValueContainer()
        try container.encode(0)
    }
}

private struct MarkedChain: Encodable {
    let levels: Int
    let marker: BottomMarker

    func encode(to encoder: Encoder) throws {
        try encodeLevel(levels, to: encoder)
    }

    private func encodeLevel(_ level: Int, to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        if level == 0 {
            try container.encode(marker)
        } else {
            try container.encode(Level(chain: self, level: level - 1))
        }
    }

    private struct Level: Encodable {
        let chain: MarkedChain
        let level: Int
        func encode(to encoder: Encoder) throws { try chain.encodeLevel(level, to: encoder) }
    }
}

@Suite("Canonical codec: the depth bound and the direct AnyCodable paths (#802)")
struct CanonicalAnyCodablePathTests {
    /// `AnyCodable` bases with every case of its `encode(to:)`, in the order it tries them.
    static func encodeFixtures() throws -> [(String, Any)] {
        let parsed = try JSONSerialization.jsonObject(
            with: Data(#"{"b":true,"i":5,"d":1.5,"u":18446744073709551615,"s":"x","a":[false,0,1]}"#.utf8)
        )
        let nsNull: Any = NSNull()
        let set: Any = Set([1, 2])
        return [
            ("NSNumber bool", NSNumber(value: true)),
            ("NSNumber int 1 (not a bool)", NSNumber(value: 1)),
            ("NSNumber unsigned above Int.max", NSNumber(value: UInt64.max)),
            ("NSNumber double", NSNumber(value: 2.5)),
            ("JSONSerialization tree", parsed),
            ("Void", ()),
            ("nil", AnyCodable(nil as Int?).base),
            ("Bool", true),
            ("Int", -7),
            ("Double", 0.1),
            ("Double NaN", Double.nan),
            ("String", "naïve"),
            ("Int8, through Encodable", Int8(3)),
            ("Float, through Encodable", Float(1.5)),
            ("Date, through Encodable", Date(timeIntervalSince1970: 86_400)),
            ("struct, through Encodable", Point(x: 1, label: "p")),
            ("AnyCodable inside AnyCodable", AnyCodable([AnyCodable(1), AnyCodable("two")])),
            ("[Int] as [Any]", [1, 2, 3]),
            ("[Point] as [Any]", [Point(x: 1, label: "a"), Point(x: 2, label: "b")]),
            ("[String: Int]", ["a": 1, "b": 2]),
            ("nested", ["list": [1, "two", ["three": 3.0]] as [Any], "empty": [Any](), "none": [String: Any]()] as [String: Any]),
            ("an optional inside an array", [Optional<Int>.none as Any, 1]),
            ("Int-keyed dictionary, through Encodable", [1: "one", 2: "two"]),
            ("two spellings of one key", TwoSpellings()),
            ("error: NSNull", nsNull),
            ("error: NSNull in an array", [1, nsNull]),
            ("error: Set", set),
            ("error: Set in an array", [set]),
            ("error: date out of range", Date(timeIntervalSince1970: 1e15)),
            ("depth: maxDepth maps", mapChain(CanonicalMessagePack.maxDepth)),
            ("depth: maxDepth + 1 maps", mapChain(CanonicalMessagePack.maxDepth + 1)),
            ("depth: maxDepth + 1 arrays", { var v: Any = 1; for _ in 0...CanonicalMessagePack.maxDepth { v = [v] as [Any] }; return v }()),
        ]
    }

    @Test("Encoding an AnyCodable directly gives the bytes and errors its own encode(to:) gives")
    func encodeMatchesGeneric() throws {
        let fixtures = try Self.encodeFixtures()
        let results = onLargeThread {
            fixtures.map { name, base in
                (name, Outcome { try CanonicalMessagePack.encode(AnyCodable(base)) },
                 generic { Outcome { try CanonicalMessagePack.encode(AnyCodable(base)) } })
            }
        }
        for (name, direct, reference) in results {
            #expect("\(direct)" == "\(reference)", "\(name)")
        }
        // The fixtures reach each kind of outcome.
        #expect(results.contains { if case .error(let text) = $0.1 { return text.contains("nested deeper") } else { return false } })
        #expect(results.contains { if case .error(let text) = $0.1 { return text.contains("invalidValue") } else { return false } })
        #expect(results.contains { if case .error(let text) = $0.1 { return text.contains("no deterministic order") } else { return false } })
    }

    @Test("A value that fails under a dictionary key reports the same error, with the key's path")
    func errorUnderDictionaryKey() throws {
        let base: Any = ["outer": ["inner": NSNull()] as [String: Any]] as [String: Any]
        let (direct, reference) = onLargeThread {
            (Outcome { try CanonicalMessagePack.encode(AnyCodable(base)) },
             generic { Outcome { try CanonicalMessagePack.encode(AnyCodable(base)) } })
        }
        // The path names the keys by their strings, so the text is the same although the key
        // types differ (`CanonicalCodingKey` here, the standard library's dictionary key there).
        #expect("\(direct)" == "\(reference)")
        guard case .error(let text) = direct else {
            Issue.record("NSNull encoded")
            return
        }
        #expect(text.contains("Path: outer.inner"))
    }

    /// Canonical bytes to decode as `AnyCodable`, including values its `init(from:)` refuses.
    static func decodeFixtures() throws -> [(String, [UInt8])] {
        var fixtures = try encodeFixtures().compactMap { name, base -> (String, [UInt8])? in
            guard let bytes = onLargeThread({ try? CanonicalMessagePack.encode(AnyCodable(base)) }) else { return nil }
            return (name, bytes)
        }
        fixtures += [
            ("UInt64.max (refused)", try CanonicalMessagePack.encode(UInt64.max)),
            ("2^63, exact as Double", try CanonicalMessagePack.encode(UInt64(1) << 63)),
            ("Int64.min", try CanonicalMessagePack.encode(Int64.min)),
            ("refused deep inside an array", try CanonicalMessagePack.encode([[UInt64.max]])),
            ("refused deep inside a map", try CanonicalMessagePack.encode(["a": ["b": UInt64.max]])),
        ]
        return fixtures
    }

    @Test("Decoding an AnyCodable directly gives the value and errors its own init(from:) gives", arguments: [false, true])
    func decodeMatchesGeneric(integralFloats: Bool) throws {
        let fixtures = try Self.decodeFixtures()
        let results = onLargeThread {
            fixtures.map { name, bytes in
                (name,
                 Outcome { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes, integralFloats: integralFloats).base },
                 generic { Outcome { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes, integralFloats: integralFloats).base } })
            }
        }
        for (name, direct, reference) in results {
            switch (direct, reference) {
            case let (.value(a), .value(b)):
                #expect(sameBase(a, b), "\(name): \(a) vs \(b)")
            case let (.error(a), .error(b)):
                #expect(a == b, "\(name)")
            default:
                Issue.record("\(name): \(direct) vs \(reference)")
            }
        }
        #expect(results.contains { if case .error = $0.1 { return true } else { return false } })
    }

    @Test("A map with two spellings of one key decodes to one entry holding one of the two values, on both paths")
    func twoSpellingsOfOneKey() throws {
        // `Dictionary.init(from:)` keeps whichever spelling the map yields last, and a map's
        // iteration order differs between dictionaries: neither path determines which.
        let bytes = try CanonicalMessagePack.encode(TwoSpellings())
        for base in [
            try CanonicalMessagePack.decode(AnyCodable.self, from: bytes).base,
            try generic { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes).base },
        ] {
            let map = try #require(base as? [String: Any])
            #expect(map.count == 1)
            #expect([1, 2].contains(map["\u{E9}"] as? Int ?? 0))
        }
    }

    @Test("An AnyCodable field inside a typed value decodes the same, and its error keeps the field's path")
    func nestedFieldMatchesGeneric() throws {
        let good = try CanonicalMessagePack.encode(["inner": ["a": [1, 2]]])
        let bad = try CanonicalMessagePack.encode(["inner": [UInt64.max]])
        for bytes in [good, bad] {
            let direct = Outcome { try CanonicalMessagePack.decode(AnyFieldHolder.self, from: bytes).inner.base }
            let reference = generic { Outcome { try CanonicalMessagePack.decode(AnyFieldHolder.self, from: bytes).inner.base } }
            switch (direct, reference) {
            case let (.value(a), .value(b)): #expect(sameBase(a, b))
            case let (.error(a), .error(b)): #expect(a == b)
            default: Issue.record("\(direct) vs \(reference)")
            }
        }
    }

    @Test("A typed value nested past the limit is refused on the way down: the encoder never reaches its bottom")
    func typedValueRefusedOnTheWayDown() {
        let reached = VisitCount()
        // Deep enough to show the bound, shallow enough that an encoder without it fits 8 MiB
        // and fails this test instead of crashing.
        let chain = MarkedChain(levels: 1000, marker: BottomMarker(reached: reached))
        let outcome = onLargeThread { Outcome { try CanonicalMessagePack.encode(chain) } }
        #expect("\(outcome)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        #expect(reached.count == 0)
    }

    @Test("An AnyCodable tree nested past the limit is refused on the way down")
    func anyCodableRefusedOnTheWayDown() {
        let visits = VisitCount()
        let tree = AnyCodable(mapChain(1000))
        let outcome = onLargeThread {
            CanonicalMessagePack.$stackProbeForTesting.withValue({ visits.count += 1 }) {
                Outcome { try CanonicalMessagePack.encode(tree) }
            }
        }
        #expect("\(outcome)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        // The encoder's entry for the root, then one visit per value from the root to `maxDepth`
        // keys down; the next is refused before it is visited.
        #expect(visits.count == CanonicalMessagePack.maxDepth + 2)
    }

    /// The stack a whole encode and a whole decode of an `AnyCodable` tree at the limit take
    /// (the encoder, the tree's finish and the writer; the reader and the decoder), against fixed
    /// budgets, so a regression fails here instead of overflowing a pool thread.
    ///
    /// Measured on macOS, Swift 6.4, debug, `maxDepth` (128) nested maps:
    /// - the generic `AnyCodable` paths: encode 601 KB, decode 551 KB, each more than a whole
    ///   544 KiB Darwin pool thread;
    /// - the direct paths: encode 194 KB (about 1.5 KB per level), decode 285 KB, most of it the
    ///   reader (about 2.2 KB per level), which both paths share.
    /// Budgets: encode 256 KiB, decode 320 KiB, leaving at least 224 KiB of a 544 KiB thread to the
    /// frames above. Release builds take far less.
    @Test("At the depth limit, a whole encode and decode stay within fixed stack budgets")
    func stackBudgetAtTheLimit() throws {
        let tree = AnyCodable(mapChain(CanonicalMessagePack.maxDepth))
        let (encoded, encodeReach, decodeReach, genericEncodeReach, genericDecodeReach) = onLargeThread { () -> ([UInt8]?, Int, Int, Int, Int) in
            var bytes: [UInt8]?
            let encodeReach = StackReach.measure { bytes = try? CanonicalMessagePack.encode(tree) }
            let decodeReach = StackReach.measure {
                _ = try? CanonicalMessagePack.decode(AnyCodable.self, from: bytes ?? [])
            }
            let genericEncodeReach = StackReach.measure { generic { _ = try? CanonicalMessagePack.encode(tree) } }
            let genericDecodeReach = StackReach.measure {
                generic { _ = try? CanonicalMessagePack.decode(AnyCodable.self, from: bytes ?? []) }
            }
            return (bytes, encodeReach, decodeReach, genericEncodeReach, genericDecodeReach)
        }
        try #require(encoded != nil, "the tree at the limit encodes")
        print("CanonicalAnyCodablePathTests: \(CanonicalMessagePack.maxDepth) levels: encode \(encodeReach) B (generic \(genericEncodeReach) B), decode \(decodeReach) B (generic \(genericDecodeReach) B)")
        #expect(encodeReach > 0 && encodeReach < 256 << 10, "encode reached \(encodeReach) bytes")
        #expect(decodeReach > 0 && decodeReach < 320 << 10, "decode reached \(decodeReach) bytes")
        // The direct paths take well under the generic ones, on any platform and build. A decode
        // reads the tree first, which both paths share.
        #expect(encodeReach * 2 < genericEncodeReach, "encode \(encodeReach) vs generic \(genericEncodeReach)")
        #expect(decodeReach < genericDecodeReach, "decode \(decodeReach) vs generic \(genericDecodeReach)")
    }
}
