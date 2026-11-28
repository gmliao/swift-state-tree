// Tests/SwiftStateTreeTests/CanonicalAnyCodablePathTests.swift
//
// The canonical codec's depth bound and its direct `AnyCodable` paths (#802).
// - The encoder checks the depth on the way down, so a value nested past `maxDepth` is refused
//   before it recurses further, not after the whole tree is built.
// - `AnyCodable` is encoded and decoded without its own `encode(to:)` / `init(from:)`: the same
//   bytes and values as those (checked here against them, case by case), at a fraction of the
//   stack.
// Everything that recurses deep runs on a Foundation thread with an 8 MiB stack: the generic
// path at the limit doesn't fit Darwin's 524 KiB cooperative-pool thread in a debug build, and a
// regression must fail a test, not crash the test process.
//
// The suite uses the codec's debug-only hooks (`stackProbeForTesting`,
// `anyCodableGenericForTesting`), so it builds in debug only.

#if DEBUG
import Foundation
import Testing
@testable import SwiftStateTree

/// `onLargeThread`'s work and its result. The thread's block is `@Sendable` on Linux; the work
/// runs there alone while the caller waits, so nothing is shared at once.
private final class LargeThreadWork<R>: @unchecked Sendable {
    let body: () -> R
    var value: R?

    init(_ body: @escaping () -> R) { self.body = body }
}

/// Runs `body` on a new thread with an 8 MiB stack and waits for it.
private func onLargeThread<R>(_ body: @escaping () -> R) -> R {
    let work = LargeThreadWork(body)
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        work.value = work.body()
        done.signal()
    }
    thread.stackSize = 8 << 20
    thread.start()
    done.wait()
    return work.value!
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

// Whether the platform's Foundation keeps two spellings of one key as two entries, decided at
// compile time. Only Darwin's `NSDictionary` compares its `NSString` keys literally, so only there
// does the bridging cast have a merge to hide. Elsewhere the probe itself must not run: in
// swift-corelibs-foundation an `NSMutableDictionary` stores its keys in a Swift dictionary whose
// `NSString` keys hash their UTF-16 literally but compare by `String ==`, so inserting the second
// spelling merges it, keeps both, or traps ("Duplicate keys of type 'NSObject'"), depending on the
// process's hash seed (a Linux mutant run trapped in about 1 process in 8). That makes the platform
// check unavoidable here, and a runtime probe can't stand in for it.
#if canImport(Darwin)
/// Darwin's `NSMutableDictionary` holds both spellings as two entries.
private let nsDictionaryKeepsBothSpellings: Bool = twoSpellingDictionary().count == 2
/// Darwin's `JSONSerialization` gives an `NSDictionary` with both spellings as two entries.
private let jsonSerializationKeepsBothSpellings: Bool = ((try? jsonObjectWithTwoSpellings()) as? NSDictionary)?.count == 2
#else
private let nsDictionaryKeepsBothSpellings = false
private let jsonSerializationKeepsBothSpellings = false
#endif

private func twoSpellingDictionary() -> NSMutableDictionary {
    let dictionary = NSMutableDictionary()
    dictionary["e\u{301}"] = 1
    dictionary["\u{E9}"] = 2
    return dictionary
}

private func jsonObjectWithTwoSpellings() throws -> Any {
    try JSONSerialization.jsonObject(with: Data("{\"e\u{301}\": 1, \"\u{E9}\": 2}".utf8))
}

/// The UTF-8 of the key a `duplicateKey` refusal names, or nil for no refusal or another error.
/// The error's `==` and its message compare the key as a `String`, which equates the two
/// spellings, so the reported spelling is pinned by its bytes.
private func refusedKeyBytes(_ body: () throws -> Void) -> [UInt8]? {
    do {
        try body()
        return nil
    } catch CanonicalMessagePackError.duplicateKey(let key) {
        return Array(key.utf8)
    } catch {
        return nil
    }
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

/// Two keys that `String` equates (NFC and NFD "é"), distinct in bytes: the format refuses the map (#805).
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

/// Fills each unkeyed container until its `count` reaches one, with a nested container `depth`
/// levels down. It stops after `maxLoops` turns of its loops in all, so a `count` that never
/// advances fails the test instead of hanging it.
private struct FillsByCount: Encodable {
    struct TooManyLoops: Error {}

    let depth: Int
    let loops: VisitCount
    static let maxLoops = 4 * CanonicalMessagePack.maxDepth

    func encode(to encoder: Encoder) throws {
        var container = encoder.unkeyedContainer()
        try fill(&container, depth: depth)
    }

    private func fill(_ container: inout UnkeyedEncodingContainer, depth: Int) throws {
        guard depth > 0 else { return }
        while container.count < 1 {
            loops.count += 1
            if loops.count > Self.maxLoops { throw TooManyLoops() }
            var nested = container.nestedUnkeyedContainer()
            try fill(&nested, depth: depth - 1)
        }
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
            ("error: two spellings of one key", TwoSpellings()),
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

    @Test("A value that fails under dictionary keys and array positions reports the same error, with the same coding path and key types")
    func errorUnderDictionaryKey() throws {
        let base: Any = ["outer": [1, ["inner": NSNull()] as [String: Any]] as [Any]] as [String: Any]
        /// The error's coding path, each key as its type, string and integer.
        func path(_ body: () throws -> [UInt8]) -> [String]? {
            do {
                _ = try body()
                return nil
            } catch EncodingError.invalidValue(_, let context) {
                return context.codingPath.map { "\(type(of: $0)) \($0.stringValue) \($0.intValue.map(String.init) ?? "-")" }
            } catch {
                return ["\(error)"]
            }
        }
        let (direct, reference) = onLargeThread {
            (path { try CanonicalMessagePack.encode(AnyCodable(base)) },
             generic { path { try CanonicalMessagePack.encode(AnyCodable(base)) } })
        }
        let directPath = try #require(direct)
        #expect(directPath == reference)
        #expect(directPath.map { $0.split(separator: " ")[1] } == ["outer", "1", "inner"])
    }

    /// Canonical bytes to decode as `AnyCodable`, including values its `init(from:)` refuses.
    static func decodeFixtures() throws -> [(String, [UInt8])] {
        // The two spellings of one key are refused when written, so there are no bytes to decode:
        // `twoSpellingsOfOneKey` reads such a map from bytes written by hand.
        var fixtures = try encodeFixtures().filter { $0.0 != "error: two spellings of one key" }.compactMap { name, base -> (String, [UInt8])? in
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
        // The decoded trees are compared and released on the large thread: the deepest are 128
        // levels, and releasing them recurses through their deinits.
        let results = onLargeThread {
            fixtures.map { name, bytes -> (name: String, mismatch: String?, refused: Bool) in
                let direct = Outcome { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes, integralFloats: integralFloats).base }
                let reference = generic { Outcome { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes, integralFloats: integralFloats).base } }
                switch (direct, reference) {
                case let (.value(a), .value(b)):
                    return (name, sameBase(a, b) ? nil : "\(a) vs \(b)", false)
                case let (.error(a), .error(b)):
                    return (name, a == b ? nil : "\(a) vs \(b)", true)
                default:
                    return (name, "\(direct) vs \(reference)", false)
                }
            }
        }
        for result in results {
            #expect(result.mismatch == nil, "\(result.name): \(result.mismatch ?? "")")
        }
        #expect(results.contains { $0.refused })
    }

    @Test("Two spellings of one key are refused on both paths, written and read (#805)")
    func twoSpellingsOfOneKey() throws {
        let later = Array("\u{E9}".utf8)
        // Written: both paths end in the writer, which refuses the pair as a duplicate key.
        #expect(refusedKeyBytes { _ = try CanonicalMessagePack.encode(AnyCodable(TwoSpellings())) } == later)
        #expect(refusedKeyBytes { _ = try generic { try CanonicalMessagePack.encode(AnyCodable(TwoSpellings())) } } == later)
        // Read: a map holding both, by hand ("e"+U+0301 then U+00E9, in byte order).
        let bytes: [UInt8] = [0x82, 0xa3, 0x65, 0xcc, 0x81, 0x02, 0xa2, 0xc3, 0xa9, 0x01]
        #expect(refusedKeyBytes { _ = try CanonicalMessagePack.decode(AnyCodable.self, from: bytes) } == later)
        #expect(refusedKeyBytes { _ = try generic { try CanonicalMessagePack.decode(AnyCodable.self, from: bytes) } } == later)
    }

    /// Checks that every value is refused on both paths, the spelling later in byte order
    /// reported, and that `JSONEncoder` still writes the cast's one-entry map: only the canonical
    /// encoder refuses.
    private func expectRefusedOnBothPaths(_ values: [(String, AnyCodable)], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let later = Array("\u{E9}".utf8)
        for (name, value) in values {
            #expect(refusedKeyBytes { _ = try CanonicalMessagePack.encode(value) } == later, "direct: \(name)", sourceLocation: sourceLocation)
            #expect(refusedKeyBytes { _ = try generic { try CanonicalMessagePack.encode(value) } } == later, "generic: \(name)", sourceLocation: sourceLocation)
        }
        let json = try JSONEncoder().encode(values[0].1)
        let decoded = try #require(try JSONSerialization.jsonObject(with: json) as? NSDictionary, sourceLocation: sourceLocation)
        #expect(decoded.count == 1, "JSONEncoder: \(String(decoding: json, as: UTF8.self))", sourceLocation: sourceLocation)
    }

    @Test("A bridged NSDictionary holding two spellings of one key is refused on both paths, not merged by the cast (#805)",
          .enabled(if: nsDictionaryKeepsBothSpellings, "only Darwin's NSDictionary keeps both spellings; elsewhere building one can trap"))
    func bridgedDictionaryWithTwoSpellings() throws {
        // `NSDictionary` compares its keys literally, so it holds both spellings; the bridging
        // cast to `[String: Any]` would keep one value.
        let bridged = twoSpellingDictionary()
        // An `Optional` around it: the cast unwraps it, so the check must too.
        let optional: NSDictionary? = bridged
        let inDictionary = NSMutableDictionary()
        inDictionary["outer"] = bridged
        try expectRefusedOnBothPaths([
            ("NSDictionary", AnyCodable(bridged)),
            ("in a Swift map", AnyCodable(["outer": bridged])),
            ("Optional", AnyCodable(optional as Any)),
            ("Optional in a Swift map", AnyCodable(["x": optional as Any])),
            ("in an NSDictionary", AnyCodable(inDictionary)),
            ("in an NSArray", AnyCodable(NSArray(array: [bridged]))),
        ])
    }

    @Test("A JSONSerialization object holding two spellings of one key is refused on both paths (#805)",
          .enabled(if: jsonSerializationKeepsBothSpellings, "only Darwin's JSONSerialization keeps both spellings"))
    func jsonSerializationObjectWithTwoSpellings() throws {
        let object = try jsonObjectWithTwoSpellings()
        try expectRefusedOnBothPaths([("JSONSerialization", AnyCodable(object)), ("in a Swift map", AnyCodable(["outer": object]))])
    }

    @Test("A bridged NSDictionary with distinct keys encodes as its Swift copy does (#805)")
    func bridgedDictionaryWithDistinctKeys() throws {
        let distinct = NSMutableDictionary()
        distinct["\u{E9}"] = 1
        distinct["\u{E8}"] = 2
        let expected = try CanonicalMessagePack.encode(["\u{E9}": 1, "\u{E8}": 2])
        #expect(try CanonicalMessagePack.encode(AnyCodable(distinct)) == expected)
        #expect(try generic { try CanonicalMessagePack.encode(AnyCodable(distinct)) } == expected)
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
        // Built and released on the large thread: releasing 1000 nested dictionaries recurses
        // through their deinits.
        let outcome = onLargeThread {
            let tree = AnyCodable(mapChain(1000))
            return CanonicalMessagePack.$stackProbeForTesting.withValue({ visits.count += 1 }) {
                Outcome { try CanonicalMessagePack.encode(tree) }
            }
        }
        #expect("\(outcome)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        // The encoder's entry for the root, then one visit per value from the root to `maxDepth`
        // keys down; the next is refused before it is visited.
        #expect(visits.count == CanonicalMessagePack.maxDepth + 2)
    }

    @Test("A value that descends through nested containers is refused past the limit, and the tree it builds stays within it")
    func nestedContainersAreBounded() throws {
        // `SIDeep` descends by `nestedUnkeyedContainer()` alone, never through `encode(_:)`.
        // Past the bound the containers write into detached slots and the encode throws before
        // the tree is finished: the only visit is the encoder's entry for the root. Checked first at a depth an unbounded encoder
        // still finishes on 8 MiB, so a regression fails here instead of crashing below.
        let visits = VisitCount()
        let shallow = onLargeThread {
            CanonicalMessagePack.$stackProbeForTesting.withValue({ visits.count += 1 }) {
                Outcome { try CanonicalMessagePack.encode(SIDeep(depth: CanonicalMessagePack.maxDepth + 2)) }
            }
        }
        #expect("\(shallow)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        try #require(visits.count == 1, "the tree past the bound was finished: \(visits.count) visits")
        let deep = onLargeThread { Outcome { try CanonicalMessagePack.encode(SIDeep(depth: 10_000)) } }
        #expect("\(deep)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        // At the limit the writer decides, as before: a container at `maxDepth` keys is the 129th.
        let atLimit = onLargeThread { Outcome { try CanonicalMessagePack.encode(SIDeep(depth: CanonicalMessagePack.maxDepth + 1)) } }
        #expect("\(atLimit)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        let within = onLargeThread { Outcome { try CanonicalMessagePack.encode(SIDeep(depth: CanonicalMessagePack.maxDepth)) } }
        guard case .value = within else {
            Issue.record("\(within)")
            return
        }
    }

    @Test("A refused nested container still advances count: a value that fills its container by count is refused, not stuck (#809)")
    func refusedNestedContainerAdvancesCount() {
        let loops = VisitCount()
        let outcome = onLargeThread {
            Outcome { try CanonicalMessagePack.encode(FillsByCount(depth: CanonicalMessagePack.maxDepth + 2, loops: loops)) }
        }
        #expect("\(outcome)" == "error CanonicalMessagePackError: \(CanonicalMessagePackError.nestingTooDeep)")
        // One turn per level: the refused levels count as filled, as accepted ones do.
        #expect(loops.count == CanonicalMessagePack.maxDepth + 2)
        let within = onLargeThread {
            Outcome { try CanonicalMessagePack.encode(FillsByCount(depth: 8, loops: VisitCount())) }
        }
        guard case .value = within else {
            Issue.record("\(within)")
            return
        }
    }

    @Test("A chain of AnyCodable values inside one another encodes their innermost base, at one path")
    func nestedAnyCodableChain() throws {
        let invalid = AnyCodable(AnyCodable(AnyCodable(NSNull())))
        // Built and released on the large thread, as the 1000 levels release recursively.
        let (good, goodGeneric, bad, badGeneric) = onLargeThread {
            var chain = AnyCodable(1)
            for _ in 0..<1000 { chain = AnyCodable(chain) }
            return (Outcome { try CanonicalMessagePack.encode(chain) },
             generic { Outcome { try CanonicalMessagePack.encode(AnyCodable(AnyCodable(1))) } },
             Outcome { try CanonicalMessagePack.encode(invalid) },
             generic { Outcome { try CanonicalMessagePack.encode(invalid) } })
        }
        #expect("\(good)" == "\(goodGeneric)")
        #expect("\(bad)" == "\(badGeneric)")
        #expect("\(bad)".contains("NSNull"))
    }

    /// The stack a whole encode and a whole decode of an `AnyCodable` tree at the limit take
    /// (the encoder, the tree's finish and the writer; the reader and the decoder), against fixed
    /// budgets, so a regression fails here instead of overflowing a pool thread.
    ///
    /// Measured on macOS, Swift 6.4, debug, `maxDepth` (128) nested maps (2026-11-26):
    /// - the generic `AnyCodable` paths: encode 652 KB, decode 584 KB, each more than a whole
    ///   524 KiB Darwin pool thread;
    /// - the direct paths: encode 194 KB (about 1.5 KB per level), decode 322 KB, most of it the
    ///   reader (about 2.5 KB per level), which both paths share. The equivalent-key check
    ///   (#805) added 6 KB to the decode (316 KB before it); it runs out of line so that the
    ///   recursive frames don't hold its locals.
    /// On Linux (x86_64, Swift 6.4.3, debug) the decode takes 295 KB (287 KB before #805): the
    /// decode budget's margin is 32.5 KB there and 5.8 KB on macOS debug, so macOS debug is the
    /// binding platform.
    /// The chain is measured twice: with one ASCII key per map, and with two distinct non-ASCII
    /// keys in the deepest map, so the equivalent-key check's own frame (its `Set` and sort)
    /// lands once at the bottom, where the reach peaks.
    ///
    /// When a change crosses a budget, a red here is a decision, not a number to bump:
    /// 1. measure the release build too;
    /// 2. move the new work out of the recursive frame first (an `@inline(never)` helper the
    ///    frame only calls);
    /// 3. raise a budget only when it is re-derived from the smallest stack the codec runs on.
    ///
    /// Budgets: encode 256 KiB, decode 320 KiB, leaving at least 204 KiB of a 524 KiB thread to the
    /// frames above. Release builds take far less.
    /// The same chain with an `AnyCodable` at every level, as a tree built from `AnyCodable`
    /// values holds them.
    static func wrappedChain(_ levels: Int) -> AnyCodable {
        var value = AnyCodable(1)
        for _ in 0..<levels { value = AnyCodable(["k": value]) }
        return value
    }

    @Test("At the depth limit, a whole encode and decode stay within fixed stack budgets")
    func stackBudgetAtTheLimit() throws {
        struct Reach { var encode = 0, decode = 0, genericEncode = 0, genericDecode = 0, wrappedEncode = 0, nonASCIIEncode = 0, nonASCIIDecode = 0 }
        let reach = try onLargeThread { () -> Result<Reach, Error> in
            Result {
                let tree = AnyCodable(mapChain(CanonicalMessagePack.maxDepth))
                let wrapped = Self.wrappedChain(CanonicalMessagePack.maxDepth)
                var reach = Reach()
                var bytes: [UInt8] = []
                reach.encode = try StackReach.measure { bytes = try CanonicalMessagePack.encode(tree) }
                reach.decode = try StackReach.measure { _ = try CanonicalMessagePack.decode(AnyCodable.self, from: bytes) }
                reach.genericEncode = try StackReach.measure { try generic { _ = try CanonicalMessagePack.encode(tree) } }
                reach.genericDecode = try StackReach.measure {
                    try generic { _ = try CanonicalMessagePack.decode(AnyCodable.self, from: bytes) }
                }
                reach.wrappedEncode = try StackReach.measure { _ = try CanonicalMessagePack.encode(wrapped) }
                // The deepest map holds two distinct non-ASCII keys: the check runs its full path there.
                let nonASCII = AnyCodable(mapChain(CanonicalMessagePack.maxDepth - 1, leaf: ["\u{E9}": 1, "\u{E8}": 2] as [String: Any]))
                var nonASCIIBytes: [UInt8] = []
                reach.nonASCIIEncode = try StackReach.measure { nonASCIIBytes = try CanonicalMessagePack.encode(nonASCII) }
                reach.nonASCIIDecode = try StackReach.measure { _ = try CanonicalMessagePack.decode(AnyCodable.self, from: nonASCIIBytes) }
                return reach
            }
        }.get()
        print("CanonicalAnyCodablePathTests: \(CanonicalMessagePack.maxDepth) levels: encode \(reach.encode) B (generic \(reach.genericEncode) B, AnyCodable at every level \(reach.wrappedEncode) B), decode \(reach.decode) B (generic \(reach.genericDecode) B); two non-ASCII keys at the bottom: encode \(reach.nonASCIIEncode) B, decode \(reach.nonASCIIDecode) B")
        #expect(reach.encode > 0 && reach.encode < 256 << 10, "encode reached \(reach.encode) bytes")
        #expect(reach.wrappedEncode > 0 && reach.wrappedEncode < 256 << 10, "AnyCodable-wrapped encode reached \(reach.wrappedEncode) bytes")
        #expect(reach.decode > 0 && reach.decode < 320 << 10, "decode reached \(reach.decode) bytes")
        #expect(reach.nonASCIIEncode > 0 && reach.nonASCIIEncode < 256 << 10, "non-ASCII encode reached \(reach.nonASCIIEncode) bytes")
        #expect(reach.nonASCIIDecode > 0 && reach.nonASCIIDecode < 320 << 10, "non-ASCII decode reached \(reach.nonASCIIDecode) bytes")
        // The direct paths take well under the generic ones, on any platform and build. A decode
        // reads the tree first, which both paths share.
        #expect(reach.encode * 2 < reach.genericEncode, "encode \(reach.encode) vs generic \(reach.genericEncode)")
        #expect(reach.decode < reach.genericDecode, "decode \(reach.decode) vs generic \(reach.genericDecode)")
    }
}
#endif
