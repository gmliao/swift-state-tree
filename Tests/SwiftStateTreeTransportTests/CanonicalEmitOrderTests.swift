// Tests/SwiftStateTreeTransportTests/CanonicalEmitOrderTests.swift
//
// Step 0 of the flat-storage plan (Notes/plans/2026-11-10-flat-state-storage.md, section 8):
// every encoder emits a frame's patches in one canonical order, with object keys in UTF-8 byte
// order, so the same frame is the same bytes whatever order the diff and the dictionaries gave.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

@StateNodeBuilder
struct OrderItem: StateNodeProtocol {
    @Sync(.broadcast) var count: Int = 0

    public init() {}
}

/// A plain struct: a value, not a table.
struct OrderStats: Codable, Equatable, Sendable {
    var level: Int = 0
    var name: String = ""
}

@StateNodeBuilder
struct OrderUnit: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var items: [String: OrderItem] = [:]
    @Sync(.broadcast) var stats: OrderStats = OrderStats()
    @Sync(.broadcast) var tags: [String: Int] = [:]

    public init() {}
}

@StateNodeBuilder
struct OrderBase: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0

    public init() {}
}

@StateNodeBuilder
struct OrderState: StateNodeProtocol {
    @Sync(.broadcast) var units: [String: OrderUnit] = [:]
    /// The same node type in a second field: one table, told apart by the chain's field.
    @Sync(.broadcast) var spectators: [String: OrderUnit] = [:]
    /// A node held directly, and an optional one.
    @Sync(.broadcast) var base: OrderBase = OrderBase()
    @Sync(.broadcast) var spare: OrderBase? = nil
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var grid: [[OrderItem]] = []

    public init() {}
}

private func set(_ path: String, _ value: SnapshotValue = .int(1)) -> StatePatch {
    StatePatch(path: path, operation: .set(value))
}

private func order() -> CanonicalPatchOrder {
    CanonicalPatchOrder.forState(OrderState.self)
}

private func pathHashes() -> [String: UInt32] {
    var definitions: [String: JSONSchema] = [:]
    var visited: Set<String> = []
    _ = TypeToSchemaConverter.convert(OrderState.self, definitions: &definitions, visitedTypes: &visited)
    return PathFlattener.flatten(rootTypeName: String(describing: OrderState.self), definitions: definitions)
}

/// The frame's patches in a fixed, deliberately non-canonical order, and their canonical order.
private let canonicalPaths = [
    "/round",
    // Table 1 (OrderBase): `base`, then `spare`; a row's own set before its fields.
    "/base/hp",
    "/spare",
    "/spare/hp",
    // Table 2 (OrderUnit): `spectators` before `units`; keys by UTF-8 bytes ("" < "10" < "9" < "u1").
    "/spectators/u1/hp",
    "/units//hp",
    "/units/10/hp",
    "/units/9/hp",
    "/units/u1",
    "/units/u1/hp",
    "/units/u1/stats/level",
    "/units/u1/tags/k",
    // Table 3 (OrderItem): its rows after every OrderUnit row, the nested collection's included.
    "/grid/0/1/count",
    "/units/u1/items/i1/count",
]

@Suite("Canonical emit order")
struct CanonicalEmitOrderTests {
    @Test("Tables are numbered parents first, ties in depth-first field name order")
    func tables() {
        let order = order()
        // A depth-first walk meets OrderBase (base), OrderItem (grid), OrderUnit (spectators).
        // OrderUnit holds OrderItem, so OrderItem's table comes after it.
        #expect(order.types.count == 4)
        #expect(order.types[0].fields["base"] == .node(1))
        #expect(order.types[0].fields["spare"] == .optional(.node(1)))
        #expect(order.types[0].fields["units"] == .collection(.node(2)))
        #expect(order.types[0].fields["spectators"] == .collection(.node(2)))
        #expect(order.types[0].fields["grid"] == .collection(.collection(.node(3))))
        #expect(order.types[2].fields["items"] == .collection(.node(3)))
        #expect(order.types[2].fields["stats"] == .value)
        #expect(order.types[2].fields["tags"] == .collection(.value))
    }

    @Test("Keys follow (table, chain, field, sub-key path); a row's own patch sorts before its fields")
    func keys() {
        let order = order()
        #expect(order.key(path: "/round").description == "0:[round]")
        #expect(order.key(path: "/base/hp").description == "1:[base][][hp]")
        #expect(order.key(path: "/spare").description == "1:[spare][]")
        #expect(order.key(path: "/units/u1").description == "2:[units][u1]")
        #expect(order.key(path: "/units/u1/stats/level").description == "2:[units][u1][stats][level]")
        #expect(order.key(path: "/units").description == "0:[units]")
        #expect(order.key(path: "/grid/0/1/count").description == "3:[grid][0][][1][count]")
        // Outside the schema: the table and field reached, the rest as the sub-key path.
        #expect(order.key(path: "/units/u1/nope/x").description == "2:[units][u1][nope][x]")
        #expect(order.key(path: "").description == "0:")
        // The row's own patch is a prefix of its field patches' keys.
        #expect(order.key(path: "/units/u1") < order.key(path: "/units/u1/hp"))
        // Raw UTF-8 bytes, no normalization: NFD "e\u{301}" (65 CC 81) before NFC "é" (C3 A9),
        // though `String` calls them equal.
        let frame = CanonicalFrameOrder(order: order)
        // Compared as bytes: `String` equality would call the two orders equal too.
        let sorted = frame.sorted([set("/units/\u{E9}/hp"), set("/units/e\u{301}/hp")]).map { Array($0.path.utf8) }
        #expect(sorted == [Array("/units/e\u{301}/hp".utf8), Array("/units/\u{E9}/hp".utf8)])
    }

    @Test("Any input order sorts to the canonical order")
    func permutations() {
        let order = CanonicalFrameOrder(order: order())
        let patches = canonicalPaths.map { set($0) }
        var generator = SplitMix64(seed: 7)
        for _ in 0 ..< 50 {
            let shuffled = patches.shuffled(using: &generator)
            #expect(order.sorted(shuffled).map(\.path) == canonicalPaths)
        }
    }

    @Test("A pattern's template gives the key the path walk gives, for every schema pattern")
    func templatesMatchTheWalk() {
        let order = order()
        let hashes = pathHashes()
        let hasher = PathHasher(pathHashes: hashes)
        let frameOrder = CanonicalFrameOrder(order: order, pathHashes: hashes)
        #expect(hashes.count > 10)
        for pattern in hashes.keys {
            var next = 0
            let path = "/" + pattern.split(separator: ".", omittingEmptySubsequences: false).map { component -> String in
                guard component == "*" else { return String(component) }
                next += 1
                return "k\(next)"
            }.joined(separator: "/")
            let patch = set(path)
            let split = hasher.splitReportingMatch(path)
            #expect(split.inSchema, "\(path)")
            #expect(frameOrder.key(patch, split: split) == order.key(path: path), "\(pattern)")
        }
    }

    @Test("Every encoder writes the same bytes for a frame given in any patch order")
    func byteIdentity() throws {
        let order = order()
        let hashes = pathHashes()
        let value: SnapshotValue = .object(["b": .int(1), "a": .int(2), "10": .int(3), "9": .int(4), "B": .int(5)])
        let patches = canonicalPaths.map { set($0, value) }
        var generator = SplitMix64(seed: 11)
        let encoders: [(String, () -> any StateUpdateEncoder)] = [
            ("json", { applyingCanonicalOrder(order, to: JSONStateUpdateEncoder()) }),
            ("opcode json", { applyingCanonicalOrder(order, to: OpcodeJSONStateUpdateEncoder(pathHasher: PathHasher(pathHashes: hashes))) }),
            ("opcode json legacy", { applyingCanonicalOrder(order, to: OpcodeJSONStateUpdateEncoder()) }),
            ("messagepack", { applyingCanonicalOrder(order, to: OpcodeMessagePackStateUpdateEncoder(pathHasher: PathHasher(pathHashes: hashes))) }),
            ("messagepack legacy", { applyingCanonicalOrder(order, to: OpcodeMessagePackStateUpdateEncoder()) }),
        ]
        for (name, make) in encoders {
            // A fresh encoder per frame, so dynamic-key tables start alike.
            let reference = try make().encode(update: .diff(patches), landID: "l", playerID: PlayerID("p"))
            for _ in 0 ..< 10 {
                let shuffled = patches.shuffled(using: &generator).map { patch -> StatePatch in
                    // Object values rebuilt with another capacity, so their iteration order differs.
                    guard case .set(.object(let fields)) = patch.operation else { return patch }
                    var rebuilt = [String: SnapshotValue](minimumCapacity: 64)
                    for (key, field) in fields.reversed() { rebuilt[key] = field }
                    return StatePatch(path: patch.path, operation: .set(.object(rebuilt)))
                }
                let data = try make().encode(update: .diff(shuffled), landID: "l", playerID: PlayerID("p"))
                #expect(data == reference, "\(name)")
            }
        }
    }

    @Test("MessagePack maps pack their string keys in UTF-8 byte order")
    func messagePackKeyOrder() throws {
        let keys = ["b", "10", "B", "9", "a", "\u{FF61}", "\u{1F600}", "f", "e\u{301}"]
        var map: [MessagePackValue: MessagePackValue] = [:]
        for (index, key) in keys.enumerated() { map[.string(key)] = .int(Int64(index)) }
        let packed = try pack(.map(map))
        var expected = Data([0x80 | UInt8(keys.count)])
        for key in keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }) {
            let bytes = Array(key.utf8)
            expected.append(0xa0 | UInt8(bytes.count))
            expected.append(contentsOf: bytes)
            expected.append(UInt8(keys.firstIndex(of: key)!))
        }
        #expect(packed == expected)
    }

    /// Pins Foundation's `.sortedKeys` to UTF-8 byte order on every CI platform; the JSON
    /// encoders rely on it. If it fails, the platform sorts differently: decide between
    /// documenting the exception and normalizing keys, never let the bytes change silently.
    @Test("JSON sorted keys are in UTF-8 byte order: digits, case, UTF-16 order and NFD keys")
    func jsonKeyOrder() throws {
        let pairs: [(String, String)] = [
            ("10", "9"),
            ("B", "a"),
            // UTF-8 bytes: EF BD A1 < F0 9F 98 80; UTF-16 code units would put the emoji first.
            ("\u{FF61}", "\u{1F600}"),
            // Raw UTF-8: 65 CC 81 < 66; NFC (C3 A9) would put "f" first.
            ("e\u{301}", "f"),
        ]
        let encoder = JSONStateUpdateEncoder()
        for (first, second) in pairs {
            let value: SnapshotValue = .object([second: .int(2), first: .int(1)])
            let data = try encoder.encode(update: .diff([set("/round", value)]), landID: "l", playerID: PlayerID("p"))
            let text = try #require(String(data: data, encoding: .utf8))
            let firstAt = try #require(text.range(of: "\"\(first)\""))
            let secondAt = try #require(text.range(of: "\"\(second)\""))
            #expect(firstAt.lowerBound < secondAt.lowerBound, "\(first) before \(second) in \(text)")
        }
    }
}

/// A seeded generator, so shuffles repeat.
private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
