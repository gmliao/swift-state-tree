// Tests/SwiftStateTreeTests/SyncTableDiffTests.swift
//
// The typed broadcast diff (`SyncTableBroadcastDiff`) against today's `SyncEngine` broadcast diff:
// the same patches in canonical order, the same drops, over random mutation sequences, plus the
// kind each field shape resolves to.

import Foundation
import Testing
@testable import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - States

@StateNodeBuilder
struct TableLeaf: StateNodeProtocol {
    @Sync(.broadcast) var v: Int = 0
    @Sync(.broadcast) var name: String = ""
    // The field types of Hero Defense's rows.
    @Sync(.broadcast) var at: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var turn: Angle = Angle(degrees: 0)
    @Sync(.broadcast) var progress: Float = 0
    @Sync(.broadcast) var tick: Int64 = 0
    @Sync(.broadcast) var owner: PlayerID? = nil
}

/// A value whose conversion throws for a negative `n`.
struct TableThrowing: Equatable, Sendable, SnapshotValueConvertible {
    var n: Int = 0
    func toSnapshotValue() throws -> SnapshotValue {
        if n < 0 { throw SyncError.unsupportedValue("negative n \(n)") }
        return .object(["n": .int(n)])
    }
}

/// A value that isn't `Equatable` (converted by reflection).
struct TableNonEquatable: Sendable {
    var n: Int = 0
}

@StateNodeBuilder
struct TableRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var speed: Double = 0
    @Sync(.broadcast) var tags: [String] = []
    @Sync(.broadcast) var inner: [String: TableLeaf] = [:]
    @Sync(.broadcast) var bad: TableThrowing = TableThrowing()
    @Sync(.broadcast) var note: String? = nil
    @Sync(.masked({ (value: Int) in value / 10 })) var bucket: Int = 0
    @Sync(.serverOnly) var secret: Int = 0
}

@StateNodeBuilder
struct TableRoot: StateNodeProtocol {
    @Sync(.broadcast) var score: Int = 0
    @Sync(.broadcast) var ratio: Double = 0
    @Sync(.broadcast) var rows: [Int: TableRow] = [:]
    @Sync(.broadcast) var named: [String: TableRow] = [:]
    @Sync(.broadcast) var byPlayer: [PlayerID: TableLeaf] = [:]
    @Sync(.broadcast) var base: TableLeaf = TableLeaf()
    @Sync(.broadcast) var maybe: TableLeaf? = nil
    @Sync(.broadcast) var values: [String: Int] = [:]
    @Sync(.broadcast) var list: [Int] = []
    @Sync(.broadcast) var throwing: TableThrowing = TableThrowing()
    @Sync(.broadcast) var nonEquatable: TableNonEquatable = TableNonEquatable()
    @Sync(.broadcast) var optionalMap: [Int: TableLeaf]? = nil
    @Sync(.broadcast) var nested: [Int: [TableLeaf]] = [:]
    @Sync(.serverOnly) var hidden: Int = 0
    @Sync(.perPlayerSlice()) var hands: [PlayerID: Int] = [:]
}

/// A key whose path components collide (`description` is constant).
struct TableCollidingKey: Hashable, Sendable, CustomStringConvertible {
    var id: Int
    var description: String { "k" }
}

/// A generic holder: `T` is unconstrained, so its field resolves to the generic value overload.
@StateNodeBuilder
struct TableGenericBox<T: Sendable>: StateNodeProtocol {
    @Sync(.broadcast) var items: [String: T] = [:]
}

@StateNodeBuilder
struct TableShapes: StateNodeProtocol {
    @Sync(.broadcast) var colliding: [TableCollidingKey: TableLeaf] = [:]
    @Sync(.broadcast) var optionalList: [TableLeaf]? = nil
    @Sync(.broadcast) var leaves: [TableLeaf] = []
    @Sync(.broadcast) var box: TableGenericBox<TableLeaf> = TableGenericBox<TableLeaf>()
    @Sync(.broadcast) var plain: Int = 0
}

/// A value whose `==` ignores `b`, which its snapshot holds.
struct TableLax: Sendable, SnapshotValueConvertible, Equatable {
    var a: Int = 0
    var b: Int = 0
    static func == (lhs: TableLax, rhs: TableLax) -> Bool { lhs.a == rhs.a }
    func toSnapshotValue() throws -> SnapshotValue { .object(["a": .int(a), "b": .int(b)]) }
}

@StateNodeBuilder
struct TableLaxState: StateNodeProtocol {
    @Sync(.broadcast) var lax: TableLax = TableLax()
}

/// A reference-typed synced value: its native last-sent would be the live object.
final class TableBox: @unchecked Sendable, SnapshotValueConvertible {
    var n: Int = 0
    func toSnapshotValue() throws -> SnapshotValue { .object(["n": .int(n)]) }
}

/// A node holding a reference-typed field.
@StateNodeBuilder
struct TableRefRow: StateNodeProtocol {
    @Sync(.broadcast) var box: TableBox = TableBox()
}

/// A node type that is also atomic: today's diff replaces it whole.
@StateNodeBuilder
struct TableAtomicNode: StateNodeProtocol {
    @Sync(.broadcast) var x: Int = 0
    @Sync(.broadcast) var y: Int = 0
}

extension TableAtomicNode: AtomicSnapshotValue {
    static var atomicLeafPaths: [[String]] { [["x"], ["y"]] }
    func toSnapshotValue() throws -> SnapshotValue { .object(["x": .int(x), "y": .int(y)]) }
}

/// A node one level above the reference: a walked row would hold `TableRefRow` as a node field.
@StateNodeBuilder
struct TableRefParent: StateNodeProtocol {
    @Sync(.broadcast) var child: TableRefRow = TableRefRow()
    @Sync(.broadcast) var hp: Int = 0
}

@StateNodeBuilder
struct TableReferences: StateNodeProtocol {
    @Sync(.broadcast) var parents: [String: TableRefParent] = [:]
    @Sync(.broadcast) var box: TableBox = TableBox()
    @Sync(.broadcast) var refRows: [String: TableRefRow] = [:]
    @Sync(.broadcast) var atomic: TableAtomicNode = TableAtomicNode()
}

/// A class that can sit in a `Set`: equal and hashed by identity, so an in-place change to `n`
/// leaves the set equal to its last-sent copy, which holds the same object.
final class TableSetMember: @unchecked Sendable, Hashable, SnapshotValueConvertible {
    var n: Int = 0
    static func == (lhs: TableSetMember, rhs: TableSetMember) -> Bool { lhs === rhs }
    func hash(into hasher: inout Hasher) { hasher.combine(ObjectIdentifier(self)) }
    func toSnapshotValue() throws -> SnapshotValue { .int(n) }
}

/// A hand-written node type that is a class (`@StateNodeBuilder` refuses one): a last-sent row
/// would be the live instance.
final class TableClassNode: StateNodeProtocol, @unchecked Sendable {
    var n: Int = 0
    init() {}
    func getSyncFields() -> [SyncFieldInfo] { [] }
    static func getFieldMetadata() -> [FieldMetadata] { [] }
    func validateSyncFields() -> Bool { true }
    func snapshot(for playerID: PlayerID?, dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: ["n": .int(n)]) }
    func broadcastSnapshot(dirtyFields: Set<String>?) throws -> StateSnapshot { StateSnapshot(values: ["n": .int(n)]) }
    func fullStateSnapshot() throws -> StateSnapshot { StateSnapshot(values: ["n": .int(n)]) }
    func isDirty() -> Bool { false }
    func getDirtyFields() -> Set<String> { [] }
    func clearDirty() {}
    static var hasPlayerDependentSyncFields: Bool { false }
    static func _syncTableFields() -> [SyncTableField<TableClassNode>]? { [] }
}

// MARK: - Harness

/// The typed side of `DiffPair` converts leaf fields by their typed form (`TYPED_LEAF_VALUES`).
enum SyncTableLeafTesting {
    @TaskLocal static var typedLeafValues = false
}

/// Today's broadcast diff and the typed one, side by side on one state.
private struct DiffPair<State: StateNodeProtocol> {
    var engine = SyncEngine(for: State.self)
    let typed = SyncTableBroadcastDiff<State>(typedLeafValues: SyncTableLeafTesting.typedLeafValues)
    let order = CanonicalPatchOrder.forState(State.self)

    /// Seeds both: today's engine seeds its cache on its first diff, which returns nothing.
    mutating func seed(_ state: State) -> (today: ExtractionDrops, typed: ExtractionDrops) {
        var todayDrops = ExtractionDrops()
        let snapshot = engine.extractBroadcastSnapshot(from: state, mode: .all, drops: &todayDrops)
        var staged = SyncEngine.StagedCaches()
        let seeded = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, mode: .all, staged: &staged)
        precondition(seeded.isEmpty)
        engine.applyStaged(staged)
        var typedDrops = ExtractionDrops()
        typed.seed(state, drops: &typedDrops)
        return (todayDrops, typedDrops)
    }

    struct Step {
        var today: [StatePatch]
        var typed: [StatePatch]
        var todayDrops: ExtractionDrops
        var typedDrops: ExtractionDrops
    }

    /// One diff on both sides; `commit` false discards both plans, as a failed sync does.
    mutating func step(_ state: State, fields: Set<String>?, commit: Bool) -> Step {
        let mode: SnapshotMode = fields.map { .dirtyTracking($0) } ?? .all
        var todayDrops = ExtractionDrops()
        let snapshot = engine.extractBroadcastSnapshot(from: state, mode: mode, drops: &todayDrops)
        var staged = SyncEngine.StagedCaches()
        let today = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: snapshot, mode: mode, staged: &staged)
        var typedDrops = ExtractionDrops()
        let (typed, typedStaged) = self.typed.diff(state, fields: fields, drops: &typedDrops)
        if commit {
            engine.applyStaged(staged)
            self.typed.apply(typedStaged)
        }
        return Step(today: order.sorted(today), typed: typed, todayDrops: todayDrops, typedDrops: typedDrops)
    }
}

/// Patch lists equal, values compared as the diff compares them (NaN equals NaN).
private func samePatches(_ lhs: [StatePatch], _ rhs: [StatePatch]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (a, b) in zip(lhs, rhs) {
        // Bytes, not `String ==`: an NFC and an NFD path are equal strings but differ on the wire.
        guard a.path.utf8.elementsEqual(b.path.utf8) else { return false }
        switch (a.operation, b.operation) {
        case (.set(let x), .set(let y)):
            guard SnapshotValue.sameValue(x, y) else { return false }
        default:
            guard a.operation == b.operation else { return false }
        }
    }
    return true
}

private func describe(_ patches: [StatePatch]) -> String {
    patches.map { "\($0.path) \($0.operation)" }.joined(separator: "\n")
}

/// SplitMix64, so a failure reproduces from its printed seed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

// MARK: - Mutations

private let doubles: [Double] = [0, -0.0, .nan, 1.5, -2.25, .infinity]
/// Includes NFC and NFD forms of one key, and keys that need JSON Pointer escaping.
private let stringKeys = ["a", "b", "\u{E9}", "e\u{301}", "x/y", "t~1"]
/// Player IDs, with one id given in both NFC and NFD form: one ID, held in NFC (#446).
private let playerKeys = ["p0", "p1", "\u{E9}", "e\u{301}"]
/// Value maps, with one key in two spellings: both diffs write it in NFC (#446).
private let valueKeys = ["a", "b", "\u{E9}", "e\u{301}", "x/y", "t~1"]

private func randomLeaf(_ g: inout SeededGenerator) -> TableLeaf {
    var leaf = TableLeaf()
    leaf.v = Int.random(in: 0...3, using: &g)
    leaf.name = ["", "n", "m"].randomElement(using: &g)!
    mutateLeaf(&leaf, &g)
    return leaf
}

private func mutateLeaf(_ leaf: inout TableLeaf, _ g: inout SeededGenerator) {
    switch Int.random(in: 0...5, using: &g) {
    case 0: leaf.at = Position2(x: Float(Int.random(in: -2...2, using: &g)) / 4, y: 1)
    case 1: leaf.turn = Angle(degrees: Float(Int.random(in: 0...3, using: &g) * 30))
    case 2: leaf.progress = [0, -0.0, .nan, 0.5].randomElement(using: &g)!
    case 3: leaf.tick = Int64.random(in: 0...2, using: &g)
    case 4: leaf.owner = Bool.random(using: &g) ? nil : PlayerID("p\(Int.random(in: 0...1, using: &g))")
    default: leaf.v += 1
    }
}

private func randomRow(_ g: inout SeededGenerator) -> TableRow {
    var row = TableRow()
    row.hp = Int.random(in: 0...3, using: &g)
    row.speed = doubles.randomElement(using: &g)!
    if Bool.random(using: &g) { row.inner["i\(Int.random(in: 0...2, using: &g))"] = randomLeaf(&g) }
    return row
}

private func mutateRow(_ row: inout TableRow, _ g: inout SeededGenerator) {
    switch Int.random(in: 0...8, using: &g) {
    case 0: row.hp = Int.random(in: 0...3, using: &g)
    case 1: row.speed = doubles.randomElement(using: &g)!
    case 2: row.tags = Bool.random(using: &g) ? [] : ["t", "u"].shuffled(using: &g)
    case 3: row.inner["i\(Int.random(in: 0...2, using: &g))"] = randomLeaf(&g)
    case 4: row.inner.removeValue(forKey: "i\(Int.random(in: 0...2, using: &g))")
    case 5: row.bad.n = Int.random(in: -1...2, using: &g)
    case 6: row.note = Bool.random(using: &g) ? nil : ["x", "y"].randomElement(using: &g)!
    case 7: row.bucket = Int.random(in: 0...30, using: &g)
    default: row.secret = Int.random(in: 0...3, using: &g)
    }
}

private func mutate(_ state: inout TableRoot, _ g: inout SeededGenerator) {
    switch Int.random(in: 0...17, using: &g) {
    case 0: state.score = Int.random(in: 0...3, using: &g)
    case 1: state.ratio = doubles.randomElement(using: &g)!
    case 2: state.rows[Int.random(in: -3...5, using: &g)] = randomRow(&g)
    case 3: state.rows.removeValue(forKey: Int.random(in: -3...5, using: &g))
    case 4, 5:
        // Sorted keys: dictionary order depends on the per-process hash seed, so the seed replays.
        if let key = state.rows.keys.sorted().randomElement(using: &g) { mutateRow(&state.rows[key]!, &g) }
    case 6: state.named[stringKeys.randomElement(using: &g)!] = randomRow(&g)
    case 7:
        if let key = state.named.keys.sorted(by: { $0.utf8.lexicographicallyPrecedes($1.utf8) }).randomElement(using: &g) {
            if Bool.random(using: &g) { state.named.removeValue(forKey: key) } else { mutateRow(&state.named[key]!, &g) }
        }
    case 8:
        let player = PlayerID(playerKeys.randomElement(using: &g)!)
        if state.byPlayer[player] != nil, Bool.random(using: &g) {
            mutateLeaf(&state.byPlayer[player]!, &g)
        } else {
            state.byPlayer[player] = Bool.random(using: &g) ? randomLeaf(&g) : nil
        }
    case 9: state.base = randomLeaf(&g)
    case 10:
        switch Int.random(in: 0...2, using: &g) {
        case 0: state.maybe = nil
        case 1: state.maybe = randomLeaf(&g)
        default: state.maybe?.v += 1
        }
    case 11: state.values[valueKeys.randomElement(using: &g)!] = Bool.random(using: &g) ? Int.random(in: 0...2, using: &g) : nil
    case 12: state.list = (0..<Int.random(in: 0...3, using: &g)).map { _ in Int.random(in: 0...2, using: &g) }
    case 13: state.throwing.n = Int.random(in: -1...2, using: &g)
    case 14: state.nonEquatable.n = Int.random(in: 0...2, using: &g)
    case 15: state.optionalMap = Bool.random(using: &g) ? nil : [Int.random(in: 0...2, using: &g): randomLeaf(&g)]
    case 16: state.nested[Int.random(in: 0...2, using: &g)] = Bool.random(using: &g) ? nil : [randomLeaf(&g)]
    default:
        state.hidden += 1
        state.hands[PlayerID("p0")] = Int.random(in: 0...2, using: &g)
    }
}

// MARK: - Shape matrix mutations

private func randomPosition(_ g: inout SeededGenerator) -> Position2 {
    Position2(x: Float(Int.random(in: -2...2, using: &g)), y: Float(Int.random(in: 0...2, using: &g)))
}

/// The shape matrix's odd keys, the accented one in both spellings.
private let shapeKeys = ["a[0]", "a/b", "t~x", "e\u{301}", "\u{E9}", "plain", ""]

private func mutateShapes(_ state: inout ShapeMatrixState, _ g: inout SeededGenerator) {
    let key = shapeKeys.randomElement(using: &g)!
    switch Int.random(in: 0...13, using: &g) {
    case 0: state.pos = randomPosition(&g)
    case 1: state.angle = Angle(degrees: Float(Int.random(in: 0...3, using: &g) * 45))
    case 2: state.maybePos = Bool.random(using: &g) ? nil : randomPosition(&g)
    case 3:
        switch Int.random(in: 0...3, using: &g) {
        case 0: state.holder = nil
        case 1: state.holder = ShapeHolder(inner: nil, tag: Int.random(in: 0...2, using: &g))
        case 2: state.holder = ShapeHolder(inner: ShapeInner(at: Bool.random(using: &g) ? nil : randomPosition(&g), heading: Angle(degrees: 45)), tag: 1)
        default: state.holder?.inner?.at = randomPosition(&g)
        }
    case 4: state.wrapper = ShapeWrapper(at: randomPosition(&g))
    case 5: state.mark = ShapeMark(x: Int32.random(in: 0...2, using: &g), y: 1)
    case 6: state.fixed = ShapeFixed(at: randomPosition(&g), label: ["", "f"].randomElement(using: &g)!)
    case 7: state.points = (0..<Int.random(in: 0...2, using: &g)).map { _ in randomPosition(&g) }
    case 8: state.maybePoints = Bool.random(using: &g) ? nil : [randomPosition(&g)]
    case 9: state.angles = Bool.random(using: &g) ? [] : [Angle(degrees: 10)]
    case 10: state.byKey[key] = Bool.random(using: &g) ? nil : randomPosition(&g)
    case 11:
        if Int.random(in: 0...2, using: &g) == 0 { state.maybeByKey = nil } else { state.maybeByKey = (state.maybeByKey ?? [:]).merging([key: randomPosition(&g)]) { $1 } }
    case 12: state.marks[key] = Bool.random(using: &g) ? nil : ShapeMark(x: 1, y: Int32.random(in: 0...2, using: &g))
    default: state.wrappers[key] = Bool.random(using: &g) ? nil : ShapeWrapper(at: randomPosition(&g))
    }
}

/// The steps per differential run: 2 000 by default, so the suite stays cheap next to the timing
/// tests it runs beside; `SYNC_TABLE_STEPS` sets a long run (for example 100 000), and
/// `SYNC_TABLE_SEED` replays a printed seed.
private let differentialSteps: Int = {
    guard let text = ProcessInfo.processInfo.environment["SYNC_TABLE_STEPS"] else { return 2_000 }
    guard let steps = Int(text), steps > 0 else { preconditionFailure("SYNC_TABLE_STEPS must be a positive integer, got \(text)") }
    return steps
}()

/// Runs `differentialSteps` random steps of `mutate` on both diffs: one plan in ten fails
/// (neither side commits, the dirty fields are carried), and every step's patches and drops must
/// be equal.
///
/// It yields every 64 steps: a run is seconds of synchronous work, and its parameterized cases
/// would otherwise hold every cooperative pool thread on a small CI runner, starving the timing
/// tests beside it (`Notes/solutions/2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md`).
private func runDifferential<State: StateNodeProtocol>(
    _ initial: State,
    allFields: Bool,
    mutate: (inout State, inout SeededGenerator) -> Void,
    sourceLocation: SourceLocation = #_sourceLocation
) async {
    let seed = ProcessInfo.processInfo.environment["SYNC_TABLE_SEED"].flatMap { UInt64($0) } ?? UInt64.random(in: 0...UInt64.max)
    var g = SeededGenerator(state: seed)
    var state = initial
    var pair = DiffPair<State>()
    let seeded = pair.seed(state)
    #expect(seeded.today.broadcastFields == seeded.typed.broadcastFields, sourceLocation: sourceLocation)
    state.clearDirty()
    var carried: Set<String> = []
    for index in 0..<differentialSteps {
        if index % 64 == 0 { await Task.yield() }
        for _ in 0..<Int.random(in: 1...4, using: &g) { mutate(&state, &g) }
        let dirty = state.getDirtyFields().union(carried)
        state.clearDirty()
        let commit = Int.random(in: 0..<10, using: &g) != 0
        // As the adapter plans it: no dirty field diffs every field (`.all`).
        let result = pair.step(state, fields: allFields || dirty.isEmpty ? nil : dirty, commit: commit)
        carried = commit ? [] : dirty
        guard samePatches(result.today, result.typed),
              result.todayDrops.broadcastFields == result.typedDrops.broadcastFields,
              result.todayDrops.count == result.typedDrops.count
        else {
            Issue.record("""
            seed \(seed), step \(index): the typed diff differs from today's
            today (drops \(result.todayDrops.broadcastFields.sorted())):
            \(describe(result.today))
            typed (drops \(result.typedDrops.broadcastFields.sorted())):
            \(describe(result.typed))
            """, sourceLocation: sourceLocation)
            return
        }
    }
}

// MARK: - Tests

@Suite("Typed sync diff (step 2, broadcast)")
struct SyncTableDiffTests {
    @Test("Each field shape resolves to its kind")
    func kinds() {
        let root = SyncTableBroadcastDiff<TableRoot>()
        #expect(root.kinds == [
            "score": .value, "ratio": .value, "rows": .nodeMap, "named": .nodeMap, "byPlayer": .nodeMap,
            "base": .node, "maybe": .optionalNode, "values": .value, "list": .value, "throwing": .value,
            "nonEquatable": .fallback, "optionalMap": .fallback, "nested": .fallback,
        ])
        let shapes = SyncTableBroadcastDiff<TableShapes>()
        #expect(shapes.kinds == [
            "colliding": .fallback, "optionalList": .fallback, "leaves": .fallback, "box": .node, "plain": .value,
        ])
        #expect(shapes.fallbackReasons["colliding"]?.contains("key type") == true)
        // The generic holder's field resolves at its declaration, to the value overload.
        let box = TableGenericBox<TableLeaf>._syncTableFields()!
        #expect(box.map(\.kind) == [.fallback])
        #expect(box[0].fallbackReason?.contains("holds a state node") == true)
        let references = SyncTableBroadcastDiff<TableReferences>()
        #expect(references.kinds == ["box": .fallback, "refRows": .fallback, "atomic": .fallback, "parents": .fallback])
        #expect(references.fallbackReasons["parents"]?.contains("reference type") == true)
        #expect(references.fallbackReasons["box"]?.contains("reference type") == true)
        #expect(references.fallbackReasons["refRows"]?.contains("reference type") == true)
        #expect(references.fallbackReasons["atomic"]?.contains("atomic") == true)
    }

    @Test("A Set of a class and a node type that is a class take the fallback")
    func referencesInASetAndAClassNode() {
        // The field descriptions as the macro would make them, by overload resolution.
        let members = SyncTableField<TableReferences>.make(
            name: "members", policy: .broadcast,
            read: { (_: TableReferences) -> Set<TableSetMember>? in [] },
            convert: { _ in .array([]) }
        )
        #expect(members.kind == .fallback)
        #expect(members.fallbackReason?.contains("reference type") == true, "\(members.fallbackReason ?? "nil")")
        let optionalMembers = SyncTableField<TableReferences>.make(
            name: "maybeMembers", policy: .broadcast,
            read: { (_: TableReferences) -> Set<TableSetMember>?? in nil },
            convert: { _ in .null }
        )
        #expect(optionalMembers.kind == .fallback)
        // A set of values stays typed.
        let numbers = SyncTableField<TableReferences>.make(
            name: "numbers", policy: .broadcast,
            read: { (_: TableReferences) -> Set<Int>? in [] },
            convert: { _ in .array([]) }
        )
        #expect(numbers.kind == .value)

        let node = SyncTableField<TableReferences>.make(
            name: "node", policy: .broadcast,
            read: { (_: TableReferences) -> TableClassNode? in TableClassNode() },
            convert: { _ in .object([:]) }
        )
        #expect(node.kind == .fallback)
        #expect(node.fallbackReason?.contains("is a class") == true, "\(node.fallbackReason ?? "nil")")
        let rows = SyncTableField<TableReferences>.make(
            name: "rows", policy: .broadcast,
            read: { (_: TableReferences) -> [String: TableClassNode]? in [:] },
            convert: { _ in .object([:]) }
        )
        #expect(rows.kind == .fallback)
        #expect(rows.fallbackReason?.contains("is a class") == true)
    }

    @Test("A reference-typed field is refused the same way by both diffs (#464)")
    func referenceField() throws {
        // Synced state must be value types (#464): registration refuses this state, and a class
        // that still reaches a snapshot is refused there. Both diffs drop the field the same way,
        // so an in-place change to the object sends nothing on either side.
        let error = try #require(throws: SyncValueSemanticsError.self) { try SyncValueSemantics.validate(TableReferences.self) }
        let paths = Set(error.violations.map(\.path))
        #expect(paths == ["TableReferences.parents[*].child.box", "TableReferences.box", "TableReferences.refRows[*].box"], "\(paths)")
        var pair = DiffPair<TableReferences>()
        var state = TableReferences()
        _ = pair.seed(state)
        func expectRefused(_ step: DiffPair<TableReferences>.Step, field: String) {
            #expect(step.today.isEmpty && step.typed.isEmpty, "\(field): \(describe(step.today)) / \(describe(step.typed))")
            #expect(step.todayDrops.broadcastFields.contains(field), "\(field): today's drops \(step.todayDrops.broadcastFields)")
            #expect(step.typedDrops.broadcastFields.contains(field), "\(field): the typed drops \(step.typedDrops.broadcastFields)")
            #expect(step.todayDrops.firstError?.contains("is a class") == true, "\(field): \(step.todayDrops.firstError ?? "nil")")
            #expect(step.typedDrops.firstError?.contains("is a class") == true, "\(field): \(step.typedDrops.firstError ?? "nil")")
        }
        state.box.n = 1
        expectRefused(pair.step(state, fields: ["box"], commit: true), field: "box")
        state.refRows["a"] = TableRefRow()
        // The insert is refused too: a row holding a class never reaches the wire.
        expectRefused(pair.step(state, fields: ["refRows"], commit: true), field: "refRows")
        state.refRows["a"]!.box.n = 2
        expectRefused(pair.step(state, fields: ["refRows"], commit: true), field: "refRows")
        // One node level further down.
        state.parents["a"] = TableRefParent()
        expectRefused(pair.step(state, fields: ["parents"], commit: true), field: "parents")
        state.parents["a"]!.child.box.n = 3
        expectRefused(pair.step(state, fields: ["parents"], commit: true), field: "parents")
    }

    // `.serialized`: its four cases take one pool thread, not four (see `runDifferential`).
    @Test("Random mutations: the typed diff equals today's, dirty tracking on and off, typed leaves on and off", .serialized, arguments: [false, true], [false, true])
    func differential(allFields: Bool, typedLeafValues: Bool) async {
        var g = SeededGenerator(state: 0)
        var state = TableRoot()
        state.rows[1] = randomRow(&g)
        state.named["a"] = randomRow(&g)
        await SyncTableLeafTesting.$typedLeafValues.withValue(typedLeafValues) {
            await runDifferential(state, allFields: allFields, mutate: mutate)
        }
    }

    @Test("Random mutations of the shape matrix: the typed diff equals today's, typed leaves on and off", .serialized, arguments: [false, true], [false, true])
    func shapeMatrixDifferential(allFields: Bool, typedLeafValues: Bool) async {
        await SyncTableLeafTesting.$typedLeafValues.withValue(typedLeafValues) {
            await runDifferential(ShapeMatrixState(), allFields: allFields, mutate: mutateShapes)
        }
    }

    /// #446: Swift holds the two spellings as one key; the wire used to carry whichever bytes
    /// the diff's cache held, so a client comparing bytes could see a second key.
    @Test("A key removed and inserted in another spelling is one NFC path in both diffs")
    func respelledKey() {
        let nfc = "\u{E9}", nfd = "e\u{301}"
        var state = TableRoot()
        state.named[nfc] = TableRow()
        state.values[nfc] = 1
        var pair = DiffPair<TableRoot>()
        _ = pair.seed(state)

        state.named.removeValue(forKey: nfc)
        state.named[nfd] = TableRow()
        state.named[nfd]?.hp = 7
        state.values.removeValue(forKey: nfc)
        state.values[nfd] = 2
        #expect(state.named.keys.contains { $0.utf8.elementsEqual(nfd.utf8) }, "the stored key is the NFD spelling")
        let step = pair.step(state, fields: ["named", "values"], commit: true)
        #expect(samePatches(step.today, step.typed), "\(describe(step.today))\n--\n\(describe(step.typed))")
        // One patch for each value change and none for a key: by bytes, in any order.
        let paths = Set(step.typed.map { Array($0.path.utf8) })
        #expect(step.typed.count == 2)
        #expect(paths == [Array("/named/\(nfc)/hp".utf8), Array("/values/\(nfc)".utf8)], "\(describe(step.typed))")

        // A key stored NFD from the start is created under its NFC path.
        var fresh = TableRoot()
        var freshPair = DiffPair<TableRoot>()
        _ = freshPair.seed(fresh)
        fresh.named[nfd] = TableRow()
        fresh.byPlayer[PlayerID(nfd)] = TableLeaf()
        let created = freshPair.step(fresh, fields: ["named", "byPlayer"], commit: true)
        #expect(samePatches(created.today, created.typed))
        #expect(Set(created.typed.map { Array($0.path.utf8) }) == [Array("/byPlayer/\(nfc)".utf8), Array("/named/\(nfc)".utf8)])
    }

    @Test("A failed plan that removes one row and creates another leaves the next diff equal to today's")
    func failedRemoveAndCreate() {
        var state = TableRoot()
        state.rows[1] = TableRow()
        var pair = DiffPair<TableRoot>()
        _ = pair.seed(state)
        state.rows.removeValue(forKey: 1)
        state.rows[2] = TableRow()
        let failed = pair.step(state, fields: ["rows"], commit: false)
        #expect(samePatches(failed.today, failed.typed))
        state.rows[2]?.hp = 5
        let next = pair.step(state, fields: ["rows"], commit: true)
        #expect(samePatches(next.today, next.typed))
        #expect(next.typed.map(\.path) == ["/rows/1", "/rows/2"])
    }

    @Test("A throwing conversion drops its whole root field, again until it converts, as today")
    func dropsRepeat() {
        var state = TableRoot()
        state.rows[1] = TableRow()
        var pair = DiffPair<TableRoot>()
        _ = pair.seed(state)
        state.rows[1]?.bad.n = -1
        state.rows[1]?.hp = 2
        for _ in 0..<2 {
            let result = pair.step(state, fields: ["rows"], commit: true)
            #expect(result.typed.isEmpty && result.today.isEmpty)
            #expect(result.typedDrops.broadcastFields == ["rows"])
            #expect(result.todayDrops.broadcastFields == ["rows"])
        }
        state.rows[1]?.bad.n = 1
        let recovered = pair.step(state, fields: ["rows"], commit: true)
        #expect(samePatches(recovered.today, recovered.typed))
        #expect(recovered.typed.map(\.path) == ["/rows/1/bad/n", "/rows/1/hp"])
    }

    @Test("A field that fails at seed is set whole once it converts, as today")
    func unseededField() {
        var state = TableRoot()
        state.throwing.n = -1
        var pair = DiffPair<TableRoot>()
        let seeded = pair.seed(state)
        #expect(seeded.typed.broadcastFields == ["throwing"])
        #expect(seeded.today.broadcastFields == ["throwing"])
        state.throwing.n = 2
        let result = pair.step(state, fields: ["throwing"], commit: true)
        #expect(samePatches(result.today, result.typed))
        #expect(result.typed.map(\.path) == ["/throwing"])
    }

    @Test("A lax == is reported in debug builds, and its change is skipped")
    func laxEquality() {
        #if DEBUG
        final class Reports: @unchecked Sendable {
            var messages: [String] = []
        }
        let reports = Reports()
        var state = TableLaxState()
        let typed = SyncTableBroadcastDiff<TableLaxState>()
        var drops = ExtractionDrops()
        typed.seed(state, drops: &drops)
        state.lax.b = 7
        let patches = SyncTableContract.$violationHandler.withValue({ reports.messages.append($0) }) {
            typed.diff(state, fields: nil, drops: &drops).patches
        }
        #expect(patches.isEmpty)
        #expect(reports.messages.count == 1)
        #expect(reports.messages.first?.contains("TableLax") == true)
        #endif
    }

    @Test("Last-sent doesn't share the live state's buffers after a commit")
    func noSharedBuffers() {
        var state = TableRoot()
        state.list = [1, 2, 3]
        let typed = SyncTableBroadcastDiff<TableRoot>()
        var drops = ExtractionDrops()
        typed.seed(state, drops: &drops)
        state.list.append(4)
        // The staged writes hold the diffed value until the commit; a plan drops them after it.
        do {
            let (_, staged) = typed.diff(state, fields: ["list"], drops: &drops)
            typed.apply(staged)
        }
        let live = state.list.withUnsafeBufferPointer { $0.baseAddress }
        let last = (typed.lastSentForTesting("list") as? [Int])
        #expect(last == [1, 2, 3, 4])
        #expect(last?.withUnsafeBufferPointer { $0.baseAddress } != live)
        // The seed's copy is its own too.
        state.rows[1] = TableRow()
        let seededTyped = SyncTableBroadcastDiff<TableRoot>()
        seededTyped.seed(state, drops: &drops)
        let seededRows = seededTyped.lastSentForTesting("rows") as? [Int: TableRow]
        #expect(seededRows?.keys.sorted() == [1])
    }
}

