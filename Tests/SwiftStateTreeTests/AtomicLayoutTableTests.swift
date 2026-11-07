// Tests/SwiftStateTreeTests/AtomicLayoutTableTests.swift

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Fixtures

/// An `{x, y}` struct that is not declared atomic: diffed per leaf.
struct UndeclaredXY: Codable, Equatable, Sendable {
    var x: Int
    var y: Int
}

/// A user type whose name contains "Angle" but which is not atomic.
struct Triangle: Codable, Equatable, Sendable {
    var a: Int
    var b: Int
    var c: Int
}

/// A user type declared atomic with the macro; `origin` contributes its leaves, prefixed.
@SnapshotConvertible(atomic: true)
struct Marker: Codable, Equatable, Sendable {
    var origin: IVec2
    var radius: Int32
    var label: String

    init() {
        origin = .zero
        radius = 0
        label = ""
    }

    init(origin: IVec2, radius: Int32, label: String) {
        self.origin = origin
        self.radius = radius
        self.label = label
    }
}

@StateNodeBuilder
struct AtomicLayoutUnit: StateNodeProtocol {
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0, y: 0)

    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0)

    @Sync(.broadcast)
    var hp: Int = 0
}

@StateNodeBuilder
struct AtomicLayoutState: StateNodeProtocol {
    @Sync(.broadcast)
    var units: [Int: AtomicLayoutUnit] = [:]

    @Sync(.broadcast)
    var target: Position2? = nil

    @Sync(.broadcast)
    var plain: [String: UndeclaredXY] = [:]

    @Sync(.broadcast)
    var shape: Triangle = Triangle(a: 0, b: 0, c: 0)

    @Sync(.broadcast)
    var marker: Marker = Marker()

    @Sync(.broadcast)
    var velocity: Velocity2 = Velocity2(v: .zero)
}

/// Atomic with a hand-written leaf list that misses `y`.
struct MissingLeaf: Codable, Equatable, Sendable, SnapshotValueConvertible, AtomicSnapshotValue {
    var x: Int32 = 0
    var y: Int32 = 0
    static var atomicLeafPaths: [[String]] { [["x"]] }
    func toSnapshotValue() throws -> SnapshotValue { .object(["x": .int(Int(x)), "y": .int(Int(y))]) }
}

/// Atomic with a hand-written leaf list that misspells `y`.
struct MisspelledLeaf: Codable, Equatable, Sendable, SnapshotValueConvertible, AtomicSnapshotValue {
    var x: Int32 = 0
    var y: Int32 = 0
    static var atomicLeafPaths: [[String]] { [["x"], ["yy"]] }
    func toSnapshotValue() throws -> SnapshotValue { .object(["x": .int(Int(x)), "y": .int(Int(y))]) }
}

/// The schema of the fixtures: two `Int32` leaves, as IVec2 describes itself.
private let xyFieldMetadata: [FieldMetadata] = [
    FieldMetadata(name: "x", type: Int32.self, policy: nil, nodeKind: .leaf, defaultValue: nil),
    FieldMetadata(name: "y", type: Int32.self, policy: nil, nodeKind: .leaf, defaultValue: nil),
]

extension MissingLeaf: SchemaMetadataProvider {
    static func getFieldMetadata() -> [FieldMetadata] { xyFieldMetadata }
}

extension MisspelledLeaf: SchemaMetadataProvider {
    static func getFieldMetadata() -> [FieldMetadata] { xyFieldMetadata }
}

@StateNodeBuilder
struct MissingLeafState: StateNodeProtocol {
    @Sync(.broadcast)
    var value: MissingLeaf = MissingLeaf()
}

@StateNodeBuilder
struct MisspelledLeafState: StateNodeProtocol {
    @Sync(.broadcast)
    var values: [String: MisspelledLeaf] = [:]
}

private func diffPatches<S: StateNodeProtocol>(
    _ engine: inout SyncEngine, _ state: S, player: PlayerID
) throws -> [StatePatch] {
    let update = try engine.generateDiff(for: player, from: state)
    guard case .diff(let patches) = update else {
        Issue.record("expected .diff, got \(update)")
        return []
    }
    return patches
}

// MARK: - Declarations

@Test("Math types declare their leaf paths in wire order")
func mathTypesDeclareLeafPaths() {
    #expect(IVec2.atomicLeafPaths == [["x"], ["y"]])
    #expect(IVec3.atomicLeafPaths == [["x"], ["y"], ["z"]])
    #expect(Position2.atomicLeafPaths == [["v", "x"], ["v", "y"]])
    #expect(Velocity2.atomicLeafPaths == [["v", "x"], ["v", "y"]])
    #expect(Acceleration2.atomicLeafPaths == [["v", "x"], ["v", "y"]])
    #expect(Angle.atomicLeafPaths == [["degrees"]])
}

@Test("@SnapshotConvertible(atomic: true) generates leaf paths in declaration order, nested values prefixed")
func macroGeneratesLeafPaths() {
    #expect(Marker.atomicLeafPaths == [["origin", "x"], ["origin", "y"], ["radius"], ["label"]])
}

// MARK: - Table

@Test("The table lists atomic paths from conformance, not from names or shapes")
func tableListsDeclaredAtomicPaths() throws {
    let table = try AtomicLayoutTable.build(for: AtomicLayoutState.self)
    #expect(table.patterns == [
        "marker": [["origin", "x"], ["origin", "y"], ["radius"], ["label"]],
        "target": [["v", "x"], ["v", "y"]],
        "units.*.position": [["v", "x"], ["v", "y"]],
        "units.*.rotation": [["degrees"]],
        "velocity": [["v", "x"], ["v", "y"]],
    ])
}

@Test("A hand-written leaf list that misses a key fails the table build, naming the type")
func tableBuildRejectsMissingLeaf() {
    do {
        _ = try AtomicLayoutTable.build(for: MissingLeafState.self)
        Issue.record("expected the build to fail")
    } catch let error as AtomicLayoutTable.BuildError {
        #expect(error.typeName == "MissingLeaf")
        #expect(error.missing == [["y"]])
        #expect(error.extra == [])
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test("A hand-written leaf list that misspells a key fails the table build, naming the type")
func tableBuildRejectsMisspelledLeaf() {
    do {
        _ = try AtomicLayoutTable.build(for: MisspelledLeafState.self)
        Issue.record("expected the build to fail")
    } catch let error as AtomicLayoutTable.BuildError {
        #expect(error.typeName == "MisspelledLeaf")
        #expect(error.missing == [["y"]])
        #expect(error.extra == [["yy"]])
    } catch {
        Issue.record("unexpected error \(error)")
    }
}

@Test("The cached table equals a fresh build and needs no registration")
func cachedTableNeedsNoRegistration() throws {
    let cached = AtomicLayoutTable.forState(AtomicLayoutState.self)
    let fresh = try AtomicLayoutTable.build(for: AtomicLayoutState.self)
    #expect(cached.patterns == fresh.patterns)
}

// MARK: - Schema

@Test("Schema atomic and leafOrder come from conformance")
func schemaAtomicFromConformance() {
    var definitions: [String: JSONSchema] = [:]
    var visited: Set<String> = []
    _ = TypeToSchemaConverter.convert(AtomicLayoutState.self, definitions: &definitions, visitedTypes: &visited)

    #expect(definitions["Position2"]?.xStateTree?.atomic == true)
    #expect(definitions["Position2"]?.xStateTree?.leafOrder == [["v", "x"], ["v", "y"]])
    #expect(definitions["Angle"]?.xStateTree?.leafOrder == [["degrees"]])
    #expect(definitions["Marker"]?.xStateTree?.atomic == true)
    #expect(definitions["Optional<Position2>"]?.xStateTree?.atomic == true)
    #expect(definitions["Optional<Position2>"]?.xStateTree?.leafOrder == [["v", "x"], ["v", "y"]])
    #expect(definitions["Triangle"]?.xStateTree?.atomic == nil)
    #expect(definitions["UndeclaredXY"]?.xStateTree?.atomic == nil)
    #expect(definitions["AtomicLayoutUnit"]?.xStateTree?.atomic == nil)
}

@Test("The schema root declares the positional wire form, and the hash covers it")
func schemaDeclaresWireForm() throws {
    let schema = ProtocolSchema(version: "0.1.0", lands: [:], defs: [:]).withComputedHash()
    #expect(schema.xStateTree == ProtocolSchemaWireForm(atomicEncoding: "positional"))

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let json = String(decoding: try encoder.encode(schema), as: UTF8.self)
    #expect(json.contains(#""x-stateTree":{"atomicEncoding":"positional"}"#), "\(json)")

    // A client built for another wire form (or for none, before positional values) has another hash.
    let other = ProtocolSchema(version: "0.1.0", lands: [:], defs: [:], xStateTree: ProtocolSchemaWireForm(atomicEncoding: "keyed"))
    let none = ProtocolSchema(version: "0.1.0", lands: [:], defs: [:], xStateTree: nil)
    #expect(Set([schema.schemaHash, other.computeHash(), none.computeHash()]).count == 3)

    // A schema file without the marker still decodes.
    let old = try JSONDecoder().decode(ProtocolSchema.self, from: Data(#"{"version":"0.1.0","schemaHash":"x","lands":{},"defs":{}}"#.utf8))
    #expect(old.xStateTree == nil)
}

// MARK: - Diff

@Test("SyncEngine(for:) diffs a declared atomic value as one patch")
func engineDiffsDeclaredAtomicAsOnePatch() throws {
    var engine = SyncEngine(for: AtomicLayoutState.self)
    var state = AtomicLayoutState()
    state.units[1] = AtomicLayoutUnit()
    let player = PlayerID("p")
    _ = try engine.generateDiff(for: player, from: state)

    state.units[1]?.position = Position2(x: 3, y: 0)
    state.units[1]?.rotation = Angle(degrees: 45)
    state.marker = Marker(origin: IVec2(x: 1, y: 0), radius: 0, label: "")
    state.target = Position2(x: 1, y: 1)

    let paths = try diffPatches(&engine, state, player: player).map(\.path).sorted()
    #expect(paths == ["/marker", "/target", "/units/1/position", "/units/1/rotation"])
}

@Test("SyncEngine(for:) diffs an undeclared {x, y} struct per leaf")
func engineDiffsUndeclaredStructPerLeaf() throws {
    var engine = SyncEngine(for: AtomicLayoutState.self)
    var state = AtomicLayoutState()
    state.plain["a"] = UndeclaredXY(x: 1, y: 1)
    let player = PlayerID("p")
    _ = try engine.generateDiff(for: player, from: state)

    state.plain["a"]?.x = 2

    let paths = try diffPatches(&engine, state, player: player).map(\.path)
    #expect(paths == ["/plain/a/x"])
}

@Test("An optional atomic value going from nil to a value and back is one patch each")
func optionalAtomicValue() throws {
    var engine = SyncEngine(for: AtomicLayoutState.self)
    var state = AtomicLayoutState()
    let player = PlayerID("p")
    _ = try engine.generateDiff(for: player, from: state)

    state.target = Position2(x: 5, y: 5)
    #expect(try diffPatches(&engine, state, player: player).map(\.path) == ["/target"])
    state.target = Position2(x: 6, y: 5)
    #expect(try diffPatches(&engine, state, player: player).map(\.path) == ["/target"])
}

// MARK: - Shapes from review: not Codable, optional non-atomic, recursive

/// Atomic, not Codable, and no `init()` (its properties are `let`): the macro's field metadata
/// describes it, so no sample instance is needed.
@SnapshotConvertible(atomic: true)
struct FixedMark: Equatable, Sendable {
    let x: Int32
    let y: Int32
}

/// Not atomic, holding an atomic value; used behind an optional.
@SnapshotConvertible
struct Holder: Codable, Equatable, Sendable {
    var position: Position2
    var tag: Int

    init() {
        position = Position2(x: 0, y: 0)
        tag = 0
    }
}

@StateNodeBuilder
struct TreeNodeState: StateNodeProtocol {
    @Sync(.broadcast)
    var pos: Position2 = Position2(x: 0, y: 0)

    @Sync(.broadcast)
    var children: [String: TreeNodeState] = [:]
}

@StateNodeBuilder
struct ReviewShapesState: StateNodeProtocol {
    @Sync(.broadcast)
    var mark: FixedMark = FixedMark(x: 0, y: 0)

    @Sync(.broadcast)
    var holder: Holder? = nil

    @Sync(.broadcast)
    var tree: TreeNodeState = TreeNodeState()
}

@Test("A non-Codable atomic type without init() is in the table (described by the macro's metadata)")
func nonCodableAtomicType() throws {
    #expect(FixedMark.atomicLeafPaths == [["x"], ["y"]])
    let table = try AtomicLayoutTable.build(for: ReviewShapesState.self)
    #expect(table.patterns["mark"] == [["x"], ["y"]])
}

@Test("An atomic value inside an optional non-atomic type is in the table and diffed as one patch")
func atomicInsideOptionalNonAtomic() throws {
    let table = try AtomicLayoutTable.build(for: ReviewShapesState.self)
    #expect(table.patterns["holder.position"] == [["v", "x"], ["v", "y"]])

    var engine = SyncEngine(for: ReviewShapesState.self)
    var state = ReviewShapesState()
    state.holder = Holder()
    let player = PlayerID("p")
    _ = try engine.generateDiff(for: player, from: state)
    state.holder?.position = Position2(x: 2, y: 0)
    #expect(try diffPatches(&engine, state, player: player).map(\.path) == ["/holder/position"])
}

@Test("A recursive type keeps its atomic values at every depth")
func recursiveTypeAtEveryDepth() throws {
    let table = try AtomicLayoutTable.build(for: ReviewShapesState.self)
    #expect(table.patterns["tree.pos"] == [["v", "x"], ["v", "y"]])
    #expect(table.patterns["tree.children.*.pos"] == [["v", "x"], ["v", "y"]])

    var engine = SyncEngine(for: ReviewShapesState.self)
    var state = ReviewShapesState()
    var leaf = TreeNodeState()
    leaf.pos = Position2(x: 1, y: 1)
    var middle = TreeNodeState()
    middle.children["b"] = leaf
    state.tree.children["a"] = middle
    let player = PlayerID("p")
    _ = try engine.generateDiff(for: player, from: state)
    state.tree.children["a"]?.children["b"]?.pos = Position2(x: 3, y: 1)
    #expect(try diffPatches(&engine, state, player: player).map(\.path) == ["/tree/children/a/children/b/pos"])
}
