// Tests/SwiftStateTreeTests/AtomicArrayShapesTests.swift
//
// Atomic values in every collection shape are positional (#272): `[T]`, `[T]?` (nil and set),
// `[String: [T]]`, `[String: [T]]?` and `[T]` inside an optional struct. The fixture
// `Tests/SwiftStateTreeTransportTests/Fixtures/AtomicArrayShapes/atomic-array-shapes.json` (the schema and, per shape, the wire
// value and its logical value) is read back by `sdk/ts` (the view) and `Tools/CLI` (schema
// conformance), so the Swift encoder, the SDK and the CLI agree on the same values.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@SnapshotConvertible
struct AtomicShapesRoute: Codable, Equatable, Sendable {
    var points: [Position2]
    var name: String

    init() {
        points = []
        name = ""
    }

    init(points: [Position2], name: String) {
        self.points = points
        self.name = name
    }
}

@StateNodeBuilder
struct AtomicArrayShapesState: StateNodeProtocol {
    @Sync(.broadcast)
    var path: [Position2] = []

    @Sync(.broadcast)
    var maybePath: [Position2]? = nil

    @Sync(.broadcast)
    var paths: [String: [Position2]] = [:]

    @Sync(.broadcast)
    var maybePaths: [String: [Position2]]? = nil

    @Sync(.broadcast)
    var route: AtomicShapesRoute? = nil
}

func makeAtomicArrayShapesLand() -> LandDefinition<AtomicArrayShapesState> {
    Land("atomic-array-shapes", using: AtomicArrayShapesState.self) {}
}

enum AtomicArrayShapesEnvKeys {
    /// Set to `1` to rewrite the fixture instead of checking it.
    static let regenerate = "SST_REGENERATE_ATOMIC_ARRAY_SHAPES"
}

@Suite("Atomic values in every collection shape")
struct AtomicArrayShapesTests {
    static let fixturePath = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appendingPathComponent("SwiftStateTreeTransportTests/Fixtures/AtomicArrayShapes/atomic-array-shapes.json").path

    static let table = AtomicLayoutTable.forState(AtomicArrayShapesState.self)

    static func p(_ x: Int32, _ y: Int32) -> Position2 { Position2(x: Float(x), y: Float(y)) }

    /// One patch per shape and position: a whole value, a key or an element.
    static func cases() throws -> [(name: String, path: String, value: SnapshotValue)] {
        func v(_ value: Any) throws -> SnapshotValue { try SnapshotValue.make(from: value) }
        return [
            ("[T] whole", "/path", try v([p(1, 2), p(3, 4)])),
            ("[T] element", "/path/1", try v(p(5, 6))),
            ("[T]? nil", "/maybePath", .null),
            ("[T]? set", "/maybePath", try v([p(7, 8)])),
            ("[T]? element", "/maybePath/0", try v(p(9, 10))),
            ("[String: [T]] whole", "/paths", try v(["a": [p(11, 12)], "b": [Position2]()])),
            ("[String: [T]] key", "/paths/a", try v([p(13, 14)])),
            ("[String: [T]] element", "/paths/a/0", try v(p(15, 16))),
            ("[String: [T]]? nil", "/maybePaths", .null),
            ("[String: [T]]? set", "/maybePaths", try v(["c": [p(17, 18)]])),
            ("[String: [T]]? element", "/maybePaths/c/0", try v(p(19, 20))),
            ("optional struct", "/route", try v(AtomicShapesRoute(points: [p(21, 22)], name: "r"))),
            ("optional struct element", "/route/points/0", try v(p(23, 24))),
        ]
    }

    @Test("SchemaGen defines an optional collection's inner type, so its items are in the schema")
    func schemaDefinesOptionalCollections() throws {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(makeAtomicArrayShapesLand())])
        #expect(schema.defs["Optional<Array<Position2>>"]?.xStateTree?.innerType == "Array<Position2>")
        #expect(schema.defs["Array<Position2>"]?.items?.value.ref == "#/defs/Position2")
        let dictionary = try #require(schema.defs["Dictionary<String, Array<Position2>>"])
        #expect(dictionary.additionalProperties?.value.items?.value.ref == "#/defs/Position2")
        // An optional is described by its innerType only, never by a `some` property.
        #expect(schema.defs["Optional<Dictionary<String, Array<Position2>>>"]?.properties == nil)
    }

    @Test("The layout table covers every shape")
    func tableCoversEveryShape() {
        let leaves = [["v", "x"], ["v", "y"]]
        #expect(Self.table.patterns == [
            "path.*": leaves, "maybePath.*": leaves, "paths.*.*": leaves, "maybePaths.*.*": leaves,
            "route.points.*": leaves,
        ])
    }

    @Test("No atomic value in a populated state stays keyed")
    func noAtomicValueStaysKeyed() throws {
        var state = AtomicArrayShapesState()
        state.path = [Self.p(1, 2)]
        state.maybePath = [Self.p(3, 4)]
        state.paths = ["a": [Self.p(5, 6)]]
        state.maybePaths = ["b": [Self.p(7, 8)]]
        state.route = AtomicShapesRoute(points: [Self.p(9, 10)], name: "r")
        let wire = try Self.table.positional(.object(try state.fullStateSnapshot().values), atPath: "")
        var keyed: [String] = []
        func walk(_ value: SnapshotValue, _ path: String) {
            switch value {
            case .object(let fields):
                if fields["v"] != nil { keyed.append(path) }
                for (key, child) in fields { walk(child, path + "/" + key) }
            case .array(let elements):
                for (index, child) in elements.enumerated() { walk(child, path + "/\(index)") }
            default:
                break
            }
        }
        walk(wire, "")
        #expect(keyed.isEmpty, "keyed atomic values at \(keyed)")
    }

    @Test("Both opcode encoders send every shape positionally and the Swift decoder reads it back")
    func encodersRoundTrip() throws {
        let patches = try Self.cases().map { StatePatch(path: $0.path, operation: .set($0.value)) }
        let decoder = OpcodeJSONStateUpdateDecoder(atomicLayout: Self.table)
        let json = OpcodeJSONStateUpdateEncoder(pathHasher: nil, atomicLayout: Self.table)
        let data = try json.encode(update: .diff(patches), landID: "atomic-array-shapes", playerID: PlayerID("p1"))
        guard case .diff(let decoded) = try decoder.decode(data: data).update else {
            Issue.record("not a diff")
            return
        }
        #expect(decoded == patches)
        let messagePack = OpcodeMessagePackStateUpdateEncoder(pathHasher: nil, atomicLayout: Self.table)
        let packed = try messagePack.encodeToMessagePackArray(
            update: .diff(patches), landID: "atomic-array-shapes", playerID: PlayerID("p1"), playerSlot: nil, scope: .perPlayer
        )
        let jsonPayload = try JSONSerialization.jsonObject(with: data) as? [Any]
        #expect(packed.count == jsonPayload?.count, "the same frame layout")
    }

    struct FixtureCase: Codable, Equatable {
        let name: String
        let path: String
        /// What the opcode encoders send.
        let wire: SnapshotValue
        /// The value as `StatePatch` holds it (keyed).
        let logical: SnapshotValue
    }

    struct Fixture: Codable {
        let schema: ProtocolSchema
        let landType: String
        let cases: [FixtureCase]
    }

    static func encodeFixture() throws -> Data {
        let schema = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(makeAtomicArrayShapesLand())])
        let cases = try Self.cases().map {
            FixtureCase(name: $0.name, path: $0.path, wire: try table.positional($0.value, atPath: $0.path), logical: $0.value)
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(Fixture(schema: schema, landType: "atomic-array-shapes", cases: cases))
    }

    @Test("The checked-in fixture for sdk/ts and Tools/CLI is current")
    func fixtureIsCurrent() throws {
        let data = try Self.encodeFixture()
        if EnvHelpers.getEnvBool(key: AtomicArrayShapesEnvKeys.regenerate, defaultValue: false) {
            try data.write(to: URL(fileURLWithPath: Self.fixturePath))
            return
        }
        let checkedIn = try Data(contentsOf: URL(fileURLWithPath: Self.fixturePath))
        #expect(data == checkedIn, "if intended, rerun with \(AtomicArrayShapesEnvKeys.regenerate)=1 swift test --filter AtomicArrayShapesTests")
    }
}
