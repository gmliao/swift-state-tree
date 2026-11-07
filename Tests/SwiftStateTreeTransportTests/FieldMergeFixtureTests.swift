// Tests/SwiftStateTreeTransportTests/FieldMergeFixtureTests.swift
//
// The cross-language order check for field merge: frames whose patches touch one entity between
// two of its field sets (a delete, a respawn, a replaced map), encoded by Swift with the merge
// on and off, in `Fixtures/FieldMerge/field-merge-frames.json`. The SDK's
// `protocol-field-merge-fixture.test.ts` decodes each frame and applies it to the case's
// initial state: the merged frame must give the same state as the plain one.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeMessagePack

enum FieldMergeFixtureEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_FIELD_MERGE_FRAMES"
}

@Suite("Field merge: the cross-language order fixture")
struct FieldMergeFixtureTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .appendingPathComponent("Fixtures/FieldMerge/field-merge-frames.json").path

    struct Case {
        let name: String
        /// The state the frame applies to, as a client holds it.
        let initial: AnyCodable
        let patches: [StatePatch]
    }

    static func set(_ path: String, _ value: SnapshotValue) -> StatePatch { StatePatch(path: path, operation: .set(value)) }
    static func delete(_ path: String) -> StatePatch { StatePatch(path: path, operation: .delete) }

    /// `monsters.*` has four leaves (`hp`, `level`, `mana`, `name`) and a map (`tags`).
    static let patterns = [
        "round", "monsters", "monsters.*", "monsters.*.hp", "monsters.*.level", "monsters.*.mana",
        "monsters.*.name", "monsters.*.tags", "monsters.*.tags.*",
    ]
    static let pathHashes = Dictionary(uniqueKeysWithValues: patterns.map { ($0, DeterministicHash.fnv1a32($0)) })
    static let hasher = PathHasher(pathHashes: pathHashes)
    static let table = FieldMergeTable(pathHashes: pathHashes)

    static let initial = AnyCodable([
        "round": AnyCodable(0),
        "monsters": AnyCodable([
            "a": AnyCodable(["hp": AnyCodable(1), "name": AnyCodable("old"), "tags": AnyCodable(["t": AnyCodable(true)])]),
            "b": AnyCodable(["hp": AnyCodable(2), "name": AnyCodable("b")]),
        ]),
    ])

    /// Each case sets `hp` and `name`, then the patch in between, then `level` and `mana`: fields
    /// not yet in the group, so only the order rule keeps them after that patch. Without it, they
    /// would join the first group and be applied before it.
    static func around(_ between: StatePatch...) -> [StatePatch] {
        [set("/monsters/a/hp", .int(5)), set("/monsters/a/name", .string("x"))]
            + between
            + [set("/monsters/a/level", .int(3)), set("/monsters/a/mana", .int(4))]
    }

    static let cases: [Case] = [
        Case(name: "fields of two entities, a root field between", initial: initial, patches: [
            set("/monsters/a/hp", .int(5)), set("/round", .int(1)), set("/monsters/b/hp", .int(6)),
            set("/monsters/a/name", .string("x")), set("/monsters/b/name", .string("y")),
        ]),
        Case(name: "removed between two of its fields", initial: initial, patches: around(delete("/monsters/a"))),
        // One key per object value: an object's key order in a frame follows Dictionary order.
        Case(name: "removed and respawned between two of its fields", initial: initial,
             patches: around(delete("/monsters/a"), set("/monsters/a", .object(["hp": .int(9)])))),
        Case(name: "respawned (set whole) between two of its fields", initial: initial,
             patches: around(set("/monsters/a", .object(["hp": .int(9)])))),
        Case(name: "its map replaced between two of its fields", initial: initial,
             patches: around(set("/monsters", .object(["a": .object(["hp": .int(0)])])))),
        Case(name: "a sibling field deleted between two fields", initial: initial, patches: around(delete("/monsters/a/tags"))),
        Case(name: "another entity removed between two fields", initial: initial, patches: around(delete("/monsters/b"))),
    ]

    static func fixture() throws -> Data {
        let hasher = Self.hasher
        func encode(_ patches: [StatePatch], merge: Bool) throws -> (json: String, messagePack: String) {
            let table = merge ? Self.table : nil
            // Fresh encoders per frame: each frame defines its dynamic key slots.
            let json = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, fieldMerge: table)
            let pack = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, fieldMerge: table)
            let update = StateUpdate.diff(patches)
            return (
                String(decoding: try json.encode(update: update, landID: "field-merge", playerID: PlayerID("p1")), as: UTF8.self),
                try pack.encode(update: update, landID: "field-merge", playerID: PlayerID("p1")).base64EncodedString()
            )
        }
        var cases: [[String: AnyCodable]] = []
        for c in Self.cases {
            let merged = try encode(c.patches, merge: true)
            let plain = try encode(c.patches, merge: false)
            cases.append([
                "name": AnyCodable(c.name),
                "initial": c.initial,
                "jsonFrame": AnyCodable(merged.json),
                "messagePackFrame": AnyCodable(merged.messagePack),
                "plainJsonFrame": AnyCodable(plain.json),
                "plainMessagePackFrame": AnyCodable(plain.messagePack),
            ])
        }
        let document: [String: AnyCodable] = [
            "pathHashes": AnyCodable(Self.pathHashes.mapValues { AnyCodable(Int($0)) }),
            "cases": AnyCodable(cases.map { AnyCodable($0) }),
        ]
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document) + Data("\n".utf8)
    }

    @Test("The fixture is current, and each case merges at least one entry")
    func fixtureIsCurrent() throws {
        let data = try Self.fixture()
        if EnvHelpers.getEnvBool(key: FieldMergeFixtureEnvKeys.regenerate, defaultValue: false) {
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let committed = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == committed, "regenerate with \(FieldMergeFixtureEnvKeys.regenerate)=1")
        // A merged entry is op 4 or 5; each case has one (else it tests nothing).
        let document = try #require(try JSONSerialization.jsonObject(with: committed) as? [String: Any])
        let cases = try #require(document["cases"] as? [[String: Any]])
        for c in cases {
            let frame = try #require(try JSONSerialization.jsonObject(with: Data((c["jsonFrame"] as? String ?? "").utf8)) as? [Any])
            let ops = frame.dropFirst().compactMap { ($0 as? [Any]).flatMap { $0.count > 2 ? $0[2] as? Int : nil } }
            #expect(ops.contains { $0 == 4 || $0 == 5 }, "\(c["name"] ?? ""): no merged entry")
        }
    }
}
