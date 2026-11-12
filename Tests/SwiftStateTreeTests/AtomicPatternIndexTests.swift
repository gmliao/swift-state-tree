// Tests/SwiftStateTreeTests/AtomicPatternIndexTests.swift
//
// The opcode encoders find an atomic value's table position from its split's pattern hash
// (`AtomicPatternIndex`) instead of walking its path. The index must give the walk's answer for
// every path (a dynamic key equal to a property name included), and the frames must be the same
// bytes with it and without it. Plan: Notes/plans/2026-11-12-atomic-node-once-per-pattern.md.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport
import SwiftStateTreeDeterministicMath

@StateNodeBuilder
struct PatternIndexUnit: StateNodeProtocol {
    @Sync(.broadcast) var position: Position2 = Position2(x: 0, y: 0)
    @Sync(.broadcast) var rotation: Angle = Angle(degrees: 0)
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var trail: [Position2] = []
    @Sync(.broadcast) var marks: [String: Position2] = [:]

    public init() {}
}

@StateNodeBuilder
struct PatternIndexState: StateNodeProtocol {
    @Sync(.broadcast) var round: Int = 0
    @Sync(.broadcast) var target: Position2? = nil
    @Sync(.broadcast) var units: [String: PatternIndexUnit] = [:]

    public init() {}
}

func makePatternIndexLand() -> LandDefinition<PatternIndexState> {
    Land("pattern-index", using: PatternIndexState.self) {}
}

/// The schema's path hashes of `State`, as a land of it registers them.
private func schemaPathHashes<State: StateNodeProtocol>(_ type: State.Type) throws -> [String: UInt32] {
    let schema = try SchemaGenCLI.generateSchema(
        landDefinitions: [AnyLandDefinition(Land("pattern-index-probe", using: State.self) {})]
    )
    return try #require(schema.lands["pattern-index-probe"]?.pathHashes)
}

/// The states whose patterns the differential walks: every atomic shape there is.
enum PatternIndexProbe: String, CaseIterable, Sendable {
    case patternIndex, atomicLayout, arrayShapes, reviewShapes, shapeMatrix

    func tableAndHashes() throws -> (table: AtomicLayoutTable, hashes: [String: UInt32]) {
        switch self {
        case .patternIndex:
            return (AtomicLayoutTable.forState(PatternIndexState.self), try schemaPathHashes(PatternIndexState.self))
        case .atomicLayout:
            return (AtomicLayoutTable.forState(AtomicLayoutState.self), try schemaPathHashes(AtomicLayoutState.self))
        case .arrayShapes:
            return (AtomicLayoutTable.forState(AtomicArrayShapesState.self), try schemaPathHashes(AtomicArrayShapesState.self))
        case .reviewShapes:
            // A recursive state has no schema (#286): the table's patterns, recursion included,
            // and every prefix of them stand in for its path hashes.
            let table = AtomicLayoutTable.forState(ReviewShapesState.self)
            var hashes: [String: UInt32] = [:]
            for pattern in table.patterns.keys {
                let labels = pattern.split(separator: ".")
                for end in 1...labels.count {
                    let prefix = labels[..<end].joined(separator: ".")
                    hashes[prefix] = DeterministicHash.fnv1a32(prefix)
                }
            }
            return (table, hashes)
        case .shapeMatrix:
            return (AtomicLayoutTable.forState(ShapeMatrixState.self), try schemaPathHashes(ShapeMatrixState.self))
        }
    }
}

/// Keys that are property names somewhere (same level, other levels), the wildcard's own
/// spelling, the empty key and indices.
private let probeKeys = ["position", "pos", "units", "children", "points", "path", "v", "x", "hp", "*", "", "0", "7", "k"]
private let fewProbeKeys = ["position", "children", "*", ""]

/// Concrete paths that split to `pattern`, one per combination of probe keys at its `*`s.
private func concretePaths(for pattern: String) -> [String] {
    let labels = pattern.split(separator: ".", omittingEmptySubsequences: true)
    let keys = labels.filter { $0 == "*" }.count >= 3 ? fewProbeKeys : probeKeys
    var paths = [""]
    for label in labels {
        if label == "*" {
            paths = paths.flatMap { base in keys.map { base + "/" + $0 } }
        } else {
            paths = paths.map { $0 + "/" + label }
        }
    }
    return paths
}

private func p(_ x: Int, _ y: Int) -> Position2 { Position2(x: Float(x), y: Float(y)) }

@Suite("Atomic pattern index: the walk's answer once per pattern")
struct AtomicPatternIndexTests {
    @Test("For every schema pattern and probe key, the index gives the walk's node", arguments: PatternIndexProbe.allCases)
    func differentialAgainstTheWalk(probe: PatternIndexProbe) throws {
        let (table, hashes) = try probe.tableAndHashes()
        let hasher = PathHasher(pathHashes: hashes)
        let index = AtomicPatternIndex(table: table, hasher: hasher)
        var decided = 0, decidedAtomic = 0, outside = 0
        var mismatches: [String] = []
        for pattern in hashes.keys.sorted() {
            for base in concretePaths(for: pattern) {
                // The path itself, one below it, and a deeper recursion (or a path outside).
                for path in [base, base + "/zz", base + "/children/q/pos", "/nope" + base] {
                    let split = hasher.splitReportingMatch(path)
                    let walk = table.node(atPath: path)
                    if split.inSchema, case .node? = index.resolution(ofPathHash: split.pathHash) {
                        decided += 1
                        if walk?.isAtomic == true { decidedAtomic += 1 }
                    }
                    if !split.inSchema { outside += 1 }
                    if index.node(pathHash: split.pathHash, inSchema: split.inSchema, path: path) !== walk {
                        mismatches.append(path)
                    }
                }
            }
        }
        #expect(mismatches.isEmpty, "\(probe): the index and the walk differ at \(mismatches.prefix(10))")
        // Not vacuous: the index decided paths, atomic ones among them, and paths outside the
        // schema were tried.
        #expect(decided > 0 && outside > 0, "\(probe): decided \(decided), outside \(outside)")
        if !table.patterns.isEmpty {
            #expect(decidedAtomic > 0, "\(probe): no atomic position was decided by the index")
        }
    }

    @Test("A `*` step that leaves a node with named children keeps the walk: the key decides")
    func starStepLeavingNamedChildrenKeepsTheWalk() throws {
        let leaves = [["v", "x"], ["v", "y"]]
        let atomic = AtomicLayoutTable.Node(leafPaths: leaves)
        let wildcard = AtomicLayoutTable.Node(leafPaths: nil)
        let root = AtomicLayoutTable.Node(children: ["position": atomic], wildcard: wildcard, leafPaths: nil)
        let table = AtomicLayoutTable(root: root, patterns: ["position": leaves])
        // No literal `position` in the hasher: "/position" splits as `*` with the key "position".
        let hasher = PathHasher(pathHashes: ["*": 1, "q": 2])
        let index = AtomicPatternIndex(table: table, hasher: hasher)
        guard case .walkPath? = index.resolution(ofPathHash: 1) else {
            Issue.record("`*` leaves the root, which has a named child: \(String(describing: index.resolution(ofPathHash: 1)))")
            return
        }
        for (path, expected) in [("/position", atomic), ("/k", wildcard)] {
            let split = hasher.splitReportingMatch(path)
            #expect(split.pathHash == 1 && split.inSchema && split.dynamicKeys == [String(path.dropFirst())], "\(path)")
            #expect(table.node(atPath: path) === expected, "\(path): the walk")
            #expect(index.node(pathHash: split.pathHash, inSchema: split.inSchema, path: path) === expected, "\(path): the index")
        }
        // A literal label the node has no child for falls to the wildcard, as the walk does.
        let literal = hasher.splitReportingMatch("/q")
        #expect(literal.pathHash == 2 && literal.inSchema && literal.dynamicKeys.isEmpty)
        #expect(table.node(atPath: "/q") === wildcard)
        guard case .node(let resolved)? = index.resolution(ofPathHash: 2) else {
            Issue.record("a literal step is decided per pattern")
            return
        }
        #expect(resolved === wildcard)
        #expect(index.node(pathHash: 2, inSchema: true, path: "/q") === wildcard)
    }

    @Test("A `*` step that leaves a wildcard-only node is decided per pattern, a key equal to a property name too")
    func starStepLeavingWildcardOnlyIsDecided() throws {
        let leaves = [["v", "x"], ["v", "y"]]
        let atomic = AtomicLayoutTable.Node(leafPaths: leaves)
        let entity = AtomicLayoutTable.Node(children: ["position": atomic], leafPaths: nil)
        let root = AtomicLayoutTable.Node(wildcard: entity, leafPaths: nil)
        let table = AtomicLayoutTable(root: root, patterns: ["*.position": leaves])
        let hasher = PathHasher(pathHashes: ["*": 1, "*.position": 3])
        let index = AtomicPatternIndex(table: table, hasher: hasher)
        guard case .node(let row)? = index.resolution(ofPathHash: 1), case .node(let field)? = index.resolution(ofPathHash: 3) else {
            Issue.record("both patterns are decided")
            return
        }
        #expect(row === entity)
        #expect(field === atomic)
        let split = hasher.splitReportingMatch("/position/position")
        #expect(split.pathHash == 3 && split.dynamicKeys == ["position"])
        #expect(table.node(atPath: "/position/position") === atomic)
        #expect(index.node(pathHash: split.pathHash, inSchema: split.inSchema, path: "/position/position") === atomic)
    }

    @Test("A split outside the schema takes the walk, even with an atomic pattern's hash")
    func outsideSchemaTakesTheWalk() throws {
        let (table, hashes) = try PatternIndexProbe.patternIndex.tableAndHashes()
        let index = AtomicPatternIndex(table: table, hasher: PathHasher(pathHashes: hashes))
        let target = try #require(hashes["target"])
        #expect(index.node(pathHash: target, inSchema: true, path: "/target")?.isAtomic == true)
        #expect(table.node(atPath: "/round") == nil)
        #expect(index.node(pathHash: target, inSchema: false, path: "/round") == nil)
    }
}

// MARK: - Frames with and without the index

/// The script: each step's change, sent as one frame.
private let patternIndexSteps: [(name: String, change: @Sendable (inout PatternIndexState) -> Void)] = [
    ("rows created, keys equal to property names", { state in
        state.round = 1
        state.target = p(1, 2)
        for (offset, key) in ["a", "position", "units", "hp", ""].enumerated() {
            var unit = PatternIndexUnit()
            unit.position = p(offset, -offset)
            unit.hp = offset
            state.units[key] = unit
        }
    }),
    ("an atomic field and a scalar of one row, positions of others", { state in
        state.units["a"]?.hp = 9
        state.units["a"]?.position = p(5, 6)
        state.units["position"]?.position = p(7, 8)
        state.units["units"]?.rotation = Angle(degrees: 45)
    }),
    ("null at an atomic path, an array and a map of atomic values", { state in
        state.target = nil
        state.units["hp"]?.trail = [p(1, 1), p(2, 2)]
        state.units["hp"]?.marks["position"] = p(3, 3)
        state.units[""]?.marks["x"] = p(4, 4)
    }),
    ("a delete and a create", { state in
        state.units["a"] = nil
        var unit = PatternIndexUnit()
        unit.position = p(9, 9)
        state.units["new"] = unit
        state.round = 2
    }),
    ("the same paths as before, new values", { state in
        state.units["position"]?.position = p(10, 10)
        state.units["units"]?.rotation = Angle(degrees: 46)
        state.units["hp"]?.hp = 3
        state.target = p(2, 1)
    }),
]

/// The script's frames: a firstSync of the state after the first step, then each step's patches
/// from the typed diff, which carry their splits (and rows).
private struct PatternIndexScript {
    let hashes: [String: UInt32]
    let hasher: PathHasher
    let table = AtomicLayoutTable.forState(PatternIndexState.self)
    let frames: [(name: String, update: StateUpdate)]

    init() throws {
        hashes = try schemaPathHashes(PatternIndexState.self)
        hasher = PathHasher(pathHashes: hashes)
        let tables = SyncTableBroadcastDiff<PatternIndexState>(pathCursor: hasher.rootCursor)
        var drops = ExtractionDrops()
        var state = PatternIndexState()
        tables.seed(state, drops: &drops)
        var frames: [(String, StateUpdate)] = []
        for (offset, step) in patternIndexSteps.enumerated() {
            step.change(&state)
            let result = tables.diff(state, fields: nil, drops: &drops)
            tables.apply(result.staged)
            frames.append((step.name, .diff(result.patches)))
            if offset == 0 {
                let snapshot = try state.broadcastSnapshot(dirtyFields: nil).values
                let patches = snapshot.keys.sorted().map { StatePatch(path: "/" + $0, operation: .set(snapshot[$0]!)) }
                frames.append(("firstSync", .firstSync(patches)))
            }
        }
        precondition(drops.count == 0)
        self.frames = frames
    }

    /// One encoder, initialized on its own (its key tables and frame cache are its own).
    func encoder(json: Bool, positional: Bool, rows: Bool, index: Bool) -> any StateUpdateEncoder {
        let layout = positional ? table : nil
        let merge = FieldMergeTable(pathHashes: hashes, atomicPatterns: Set(table.patterns.keys))
        let order = CanonicalPatchOrder.forState(PatternIndexState.self)
        if json {
            return OpcodeJSONStateUpdateEncoder(
                pathHasher: hasher, dynamicKeyCompression: true, atomicLayout: layout, pathIndex: true,
                unmappedPaths: nil, fieldMerge: merge, atomicPatternIndex: index
            ).withRowAddressing(rows).withCanonicalOrder(order)
        }
        return OpcodeMessagePackStateUpdateEncoder(
            pathHasher: hasher, dynamicKeyCompression: true, atomicLayout: layout, pathIndex: true,
            unmappedPaths: nil, fieldMerge: merge, atomicPatternIndex: index
        ).withRowAddressing(rows).withCanonicalOrder(order)
    }
}

/// `update` without the splits its patches carry, in reverse order: the encoder splits each path
/// itself and sorts the frame.
private func withoutSplits(_ update: StateUpdate) -> StateUpdate {
    func strip(_ patches: [StatePatch]) -> [StatePatch] {
        patches.reversed().map { StatePatch(path: $0.path, operation: $0.operation) }
    }
    switch update {
    case .diff(let patches): return .diff(strip(patches))
    case .firstSync(let patches): return .firstSync(strip(patches))
    case .noChange: return .noChange
    }
}

/// The ops of a JSON frame's entries.
private func jsonOps(_ frame: Data) throws -> [Int] {
    let array = try #require(try JSONSerialization.jsonObject(with: frame) as? [Any])
    return array.dropFirst().compactMap { ($0 as? [Any]).flatMap { $0.count > 2 ? ($0[2] as? Int) : nil } }
}

struct PatternIndexFrameCase: CustomTestStringConvertible, Sendable {
    let json: Bool
    let rows: Bool
    let carried: Bool

    var testDescription: String {
        "\(json ? "opcode JSON" : "MessagePack"), rows \(rows ? "on" : "off"), splits \(carried ? "carried" : "computed")"
    }

    static let all: [PatternIndexFrameCase] = [true, false].flatMap { json in
        [true, false].flatMap { rows in [true, false].map { PatternIndexFrameCase(json: json, rows: rows, carried: $0) } }
    }
}

@Suite("Atomic pattern index: frames are the same bytes")
struct AtomicPatternIndexFrameTests {
    @Test("Two encoders with the same history, one with the index: every frame is the same bytes", arguments: PatternIndexFrameCase.all)
    func sameBytes(_ frameCase: PatternIndexFrameCase) throws {
        let script = try PatternIndexScript()
        let players = [PlayerID("p1"), PlayerID("p2")]
        for positional in [true, false] {
            let with = script.encoder(json: frameCase.json, positional: positional, rows: frameCase.rows, index: true)
            let without = script.encoder(json: frameCase.json, positional: positional, rows: frameCase.rows, index: false)
            var mergedEntries = 0
            for frame in script.frames {
                let update = frameCase.carried ? frame.update : withoutSplits(frame.update)
                // Two recipients in a row: the second takes the first's splits (the frame cache).
                for player in players {
                    let expected = try without.encode(update: update, landID: "pattern-index", playerID: player)
                    let actual = Result { try with.encode(update: update, landID: "pattern-index", playerID: player) }
                    #expect((try? actual.get()) == expected, "\(frameCase.testDescription), positional \(positional): \(frame.name), \(player)")
                    if frameCase.json { mergedEntries += try jsonOps(expected).filter { $0 == MergedPatchOpcode.set.rawValue }.count }
                }
            }
            if frameCase.json && !frameCase.rows {
                // The script merges an atomic field with a scalar of one parent.
                #expect(mergedEntries > 0, "no merged entry in \(frameCase.testDescription)")
            }
        }
    }

    @Test("Positional frames differ from keyed ones: the script has atomic values on every path kind")
    func scriptIsPositional() throws {
        let script = try PatternIndexScript()
        let positional = script.encoder(json: true, positional: true, rows: false, index: true)
        let keyed = script.encoder(json: true, positional: false, rows: false, index: true)
        var differing: [String] = []
        for frame in script.frames {
            let a = try positional.encode(update: frame.update, landID: "pattern-index", playerID: PlayerID("p1"))
            let b = try keyed.encode(update: frame.update, landID: "pattern-index", playerID: PlayerID("p1"))
            if a != b { differing.append(frame.name) }
        }
        #expect(differing.count == script.frames.count, "frames with no atomic value: \(Set(script.frames.map(\.name)).subtracting(differing))")
    }
}
