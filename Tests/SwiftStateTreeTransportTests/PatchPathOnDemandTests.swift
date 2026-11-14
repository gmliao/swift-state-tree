// Tests/SwiftStateTreeTransportTests/PatchPathOnDemandTests.swift
//
// The typed diff's positions (#392): a lossless walk makes split-only patches; a literal whose
// trie label is String-equal but spelled with other bytes keeps today's stored pair (path and
// split, row metadata included); a walk-off rebuilds the path once and goes on as a string.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

@StateNodeBuilder
struct PathOnDemandInner: StateNodeProtocol {
    @Sync(.broadcast) var deep: Int = 0
    @Sync(.broadcast) var other: Int = 0
    /// Labelled with U+212A below the root: a lossy literal under lossless ancestors.
    @Sync(.broadcast) var Kdeep: Int = 0

    public init() {}
}

@StateNodeBuilder
struct PathOnDemandOuter: StateNodeProtocol {
    @Sync(.broadcast) var inner: PathOnDemandInner = PathOnDemandInner()

    public init() {}
}

/// Field names with a `K`: the hasher below spells it U+212A KELVIN SIGN, which is `String`-equal
/// to `K` but has other bytes.
@StateNodeBuilder
struct PathOnDemandState: StateNodeProtocol {
    @Sync(.broadcast) var Kunits: [Int: DirtyIdentityUnit] = [:]
    @Sync(.broadcast) var Kx: Int = 0
    @Sync(.broadcast) var Kboss: PathOnDemandOuter = PathOnDemandOuter()
    @Sync(.broadcast) var boss: PathOnDemandOuter = PathOnDemandOuter()

    public init() {}
}

@SnapshotConvertible(atomic: true)
struct PathOnDemandXY: Codable, Equatable, Sendable {
    var x: Int
    var y: Int

    init() {
        x = 0
        y = 0
    }

    init(x: Int, y: Int) {
        self.x = x
        self.y = y
    }
}

/// An atomic value with an atomic value inside (`origin`): the positional form recurses.
@SnapshotConvertible(atomic: true)
struct PathOnDemandMarker: Codable, Equatable, Sendable {
    var origin: PathOnDemandXY
    var radius: Int

    init() {
        origin = PathOnDemandXY()
        radius = 0
    }

    init(origin: PathOnDemandXY, radius: Int) {
        self.origin = origin
        self.radius = radius
    }
}

@StateNodeBuilder
struct PathOnDemandUnit: StateNodeProtocol {
    @Sync(.broadcast) var marker: PathOnDemandMarker = PathOnDemandMarker()
    @Sync(.broadcast) var hp: Int = 0

    public init() {}
}

@StateNodeBuilder
struct PathOnDemandAtomicState: StateNodeProtocol {
    @Sync(.broadcast) var units: [Int: PathOnDemandUnit] = [:]

    public init() {}
}

@StateNodeBuilder
struct PathDiffRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.broadcast) var inner: PathOnDemandInner = PathOnDemandInner()

    public init() {}
}

/// The differential fixture: rows and map entries under keys that escape (`~`, `/`), an empty
/// key, NFD and NFC keys (in different maps: one `Dictionary` holds them as one key), and the
/// bosses of `PathOnDemandState` for the walk-offs.
@StateNodeBuilder
struct PathDiffState: StateNodeProtocol {
    @Sync(.broadcast) var units: [String: PathDiffRow] = [:]
    @Sync(.broadcast) var m: [String: Int] = [:]
    @Sync(.broadcast) var Kboss: PathOnDemandOuter = PathOnDemandOuter()
    @Sync(.broadcast) var boss: PathOnDemandOuter = PathOnDemandOuter()

    public init() {}
}

@Suite("The typed diff's positions: split-only, stored pair, walk-off (#392)")
struct PatchPathOnDemandTests {
    static let kelvin = "\u{212A}"

    /// `units.*.hp` etc. under labels spelled with U+212A; `inner` is an unhashed intermediate
    /// under both bosses, and `other` isn't in the trie (a walk-off).
    static let hasher = PathHasher(pathHashes: Dictionary(uniqueKeysWithValues: [
        "\(kelvin)units", "\(kelvin)units.*", "\(kelvin)units.*.hp", "\(kelvin)units.*.x",
        "\(kelvin)x",
        "\(kelvin)boss.inner.deep",
        "boss.inner.deep",
        "boss.inner.\(kelvin)deep",
    ].map { ($0, DeterministicHash.fnv1a32($0)) }))

    func diff(_ state: PathOnDemandState, _ changed: PathOnDemandState, cursor: PathHasher.Cursor?) -> [StatePatch] {
        let tables = SyncTableBroadcastDiff<PathOnDemandState>(pathCursor: cursor, typedLeafValues: true)
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        return tables.diff(changed, fields: nil, drops: &drops).patches
    }

    @Test("A lossy literal keeps the stored pair: the path as emitted, the split with its row slot and generation")
    func lossyLiteralKeepsThePair() throws {
        #expect("K" == Self.kelvin && !"K".utf8.elementsEqual(Self.kelvin.utf8))
        var state = PathOnDemandState()
        state.Kunits[1] = DirtyIdentityUnit()
        state.Kunits[2] = DirtyIdentityUnit()
        var changed = state
        changed.Kunits[1]?.hp = 9
        changed.Kunits[2] = nil
        changed.Kunits[7] = DirtyIdentityUnit()
        changed.Kx = 5

        let withCursor = diff(state, changed, cursor: Self.hasher.rootCursor)
        let without = diff(state, changed, cursor: nil)
        #expect(withCursor.map { Array($0.path.utf8) } == without.map { Array($0.path.utf8) })
        #expect(Set(withCursor.map(\.path)) == ["/Kunits/1/hp", "/Kunits/2", "/Kunits/7", "/Kx"])
        for patch in withCursor {
            #expect(!patch.isSplitOnly, "\(patch.path) is under a lossy literal")
            #expect(patch.path.utf8.starts(with: "/K".utf8), "the emitted bytes, not the label's")
            #expect(patch.split?.belongs(to: Self.hasher) == true, "\(patch.path) carries its split")
        }
        let byPath = Dictionary(uniqueKeysWithValues: withCursor.map { ($0.path, $0) })
        let created = try #require(byPath["/Kunits/7"]?.split?.row)
        #expect(created.generation != nil, "a create's row carries its generation")
        #expect(try #require(byPath["/Kunits/2"]?.split?.row).generation == nil)
        #expect(byPath["/Kunits/1/hp"]?.split?.row != nil, "a row's field carries the row")
    }

    @Test("A walk-off below an unhashed intermediate keeps the emitted bytes, under a lossy ancestor and under a lossless one")
    func walkOffBelowAnUnhashedIntermediate() throws {
        let state = PathOnDemandState()
        var changed = state
        changed.Kboss.inner.deep = 1
        changed.Kboss.inner.other = 2
        changed.boss.inner.deep = 3
        changed.boss.inner.other = 4
        changed.boss.inner.Kdeep = 5

        let withCursor = diff(state, changed, cursor: Self.hasher.rootCursor)
        let without = diff(state, changed, cursor: nil)
        #expect(withCursor.map { Array($0.path.utf8) } == without.map { Array($0.path.utf8) })
        let byPath = Dictionary(uniqueKeysWithValues: withCursor.map { ($0.path, $0) })
        // The lossless chain: the hashed leaf holds no path; the walk-off rebuilt the
        // intermediate's path once and holds a string, without a split.
        let deep = try #require(byPath["/boss/inner/deep"])
        #expect(deep.isSplitOnly)
        let other = try #require(byPath["/boss/inner/other"])
        #expect(!other.isSplitOnly && other.split == nil)
        // The lossy chain: everything is a string, the hashed leaf with its split.
        let lossyDeep = try #require(byPath["/Kboss/inner/deep"])
        #expect(!lossyDeep.isSplitOnly && lossyDeep.split != nil)
        let lossyOther = try #require(byPath["/Kboss/inner/other"])
        #expect(!lossyOther.isSplitOnly && lossyOther.split == nil)
        // A lossy literal below lossless ancestors: the stored pair, with today's bytes.
        let lossyLeaf = try #require(byPath["/boss/inner/Kdeep"])
        #expect(!lossyLeaf.isSplitOnly && lossyLeaf.split != nil)
        #expect(lossyLeaf.path.utf8.elementsEqual("/boss/inner/Kdeep".utf8))
    }

    @Test(
        "The typed diff with a cursor gives the snapshot diff's patches, path bytes included: escaped, empty, NFD and NFC keys, rows created, retagged and deleted, walk-offs",
        arguments: [false, true]
    )
    func matchesTheSnapshotDiff(rowCreates: Bool) throws {
        let hasher = PathHasher(pathHashes: Dictionary(uniqueKeysWithValues: [
            // `inner` is unhashed under the wildcard, and `other` walks off below it.
            "units", "units.*", "units.*.hp", "units.*.inner.deep", "units.*.inner.\(Self.kelvin)deep",
            "m", "m.*",
            "\(Self.kelvin)boss.inner.deep",
            "boss.inner.deep",
        ].map { ($0, DeterministicHash.fnv1a32($0)) }))
        let nfd = "cafe\u{301}"
        let nfc = "caf\u{E9}"
        var state = PathDiffState()
        for key in ["a~b", "a/b", "", nfd] { state.units[key] = PathDiffRow() }
        state.m = ["~1": 1, "": 2, nfc: 3, "x": 4]
        var changed = state
        changed.units["a~b"]?.hp = 5
        changed.units["a~b"]?.inner.Kdeep = 8
        changed.units["a/b"]?.inner.deep = 6
        changed.units[""]?.inner.other = 7
        changed.units[nfd] = nil
        changed.units["~1"] = PathDiffRow()
        changed.units["n"] = PathDiffRow()
        changed.m["~1"] = 10
        changed.m[""] = nil
        changed.m[nfc] = 30
        changed.m["a/b"] = 40
        changed.Kboss.inner.other = 1
        changed.boss.inner.deep = 2
        changed.boss.inner.other = 3

        let tables = SyncTableBroadcastDiff<PathDiffState>(pathCursor: hasher.rootCursor, typedLeafValues: true)
        tables.emitsRowCreates = rowCreates
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        let typed = tables.diff(changed, fields: nil, drops: &drops).patches
        // The order: the cursor changes no patch's place. The typed diff's order itself (the
        // canonical one) is pinned on the wire by the goldens (SyncOutputGoldenTests,
        // SyncTablesByteIdentityTests); the snapshot diff isn't in that order, so the comparison
        // with it below sorts both sides by path bytes.
        let plain = SyncTableBroadcastDiff<PathDiffState>(pathCursor: nil, typedLeafValues: true)
        plain.emitsRowCreates = rowCreates
        var plainDrops = ExtractionDrops()
        plain.seed(state, drops: &plainDrops)
        let withoutCursor = plain.diff(changed, fields: nil, drops: &plainDrops).patches
        #expect(typed.map { Array($0.path.utf8) } == withoutCursor.map { Array($0.path.utf8) })
        #expect(typed.map { $0.operation } == withoutCursor.map { $0.operation })
        let snapshot = SyncEngine.diffSnapshotValues(
            from: try SnapshotValue.broadcastView(of: state),
            to: try SnapshotValue.broadcastView(of: changed),
            basePath: "",
            layout: AtomicLayoutTable.forState(PathDiffState.self).root
        )
        func keyed(_ patches: [StatePatch]) -> [([UInt8], PatchOperation)] {
            patches.map { (Array($0.path.utf8), $0.operation) }.sorted { $0.0.lexicographicallyPrecedes($1.0) }
        }
        let expected = keyed(snapshot)
        let actual = keyed(typed)
        #expect(actual.map(\.0) == expected.map(\.0), "\(typed.map(\.path)) vs \(snapshot.map(\.path))")
        #expect(actual.map(\.1) == expected.map(\.1))
        // The fixture reaches every form: split-only, the stored pair, and a string without a split.
        #expect(typed.contains { $0.isSplitOnly })
        #expect(typed.contains { !$0.isSplitOnly && $0.split != nil })
        #expect(typed.contains { $0.split == nil })
        #expect(typed.contains { $0.split?.row?.generation != nil }, "a created row is retagged with its generation")
    }

    @Test("Under a lossy field name, a row's create, update and delete go out as row entries, the bytes of the lossless name's frame", arguments: [false, true])
    func lossyRowWireBytes(pathIndex: Bool) throws {
        // The same patterns and hashes, the field's label spelled with `K` or with U+212A.
        let ascii = ["Kunits", "Kunits.*", "Kunits.*.hp", "Kunits.*.x", "Kx"]
        func hasher(_ label: String) -> PathHasher {
            PathHasher(pathHashes: Dictionary(uniqueKeysWithValues: ascii.map {
                ($0.replacingOccurrences(of: "K", with: label, options: .literal), DeterministicHash.fnv1a32($0))
            }))
        }
        let lossless = hasher("K")
        let lossy = hasher(Self.kelvin)
        var state = PathOnDemandState()
        state.Kunits[1] = DirtyIdentityUnit()
        state.Kunits[2] = DirtyIdentityUnit()
        var changed = state
        changed.Kunits[1]?.hp = 9
        changed.Kunits[2] = nil
        changed.Kunits[7] = DirtyIdentityUnit()

        func diff(_ hasher: PathHasher) -> [StatePatch] {
            let tables = SyncTableBroadcastDiff<PathOnDemandState>(pathCursor: hasher.rootCursor, typedLeafValues: true)
            tables.emitsRowCreates = true
            var drops = ExtractionDrops()
            tables.seed(state, drops: &drops)
            return tables.diff(changed, fields: nil, drops: &drops).patches
        }
        let pair = diff(lossy)
        let splitOnly = diff(lossless)
        #expect(pair.allSatisfy { !$0.isSplitOnly && $0.split?.row != nil })
        #expect(splitOnly.allSatisfy { $0.isSplitOnly })
        let json = (
            OpcodeJSONStateUpdateEncoder(pathHasher: lossy, pathIndex: pathIndex).withRowAddressing(),
            OpcodeJSONStateUpdateEncoder(pathHasher: lossless, pathIndex: pathIndex).withRowAddressing()
        )
        let pack = (
            OpcodeMessagePackStateUpdateEncoder(pathHasher: lossy, pathIndex: pathIndex).withRowAddressing(),
            OpcodeMessagePackStateUpdateEncoder(pathHasher: lossless, pathIndex: pathIndex).withRowAddressing()
        )
        let player = PlayerID("p")
        let jsonPair = try json.0.encode(update: .diff(pair), landID: "lossy", playerID: player)
        let jsonSplit = try json.1.encode(update: .diff(splitOnly), landID: "lossy", playerID: player)
        #expect(jsonPair == jsonSplit)
        let packPair = try pack.0.encode(update: .diff(pair), landID: "lossy", playerID: player)
        let packSplit = try pack.1.encode(update: .diff(splitOnly), landID: "lossy", playerID: player)
        #expect(packPair == packSplit)
    }

    @Test("The json encoding gets no path trie, so its typed diff's patches are all string-form")
    func jsonIsStringForm() {
        let encoders: [any StateUpdateEncoder] = [JSONStateUpdateEncoder(), OpcodeJSONStateUpdateEncoder()]
        for encoder in encoders {
            #expect((encoder as? any PathSplittingStateUpdateEncoder)?.splittingPathHasher == nil, "\(type(of: encoder))")
        }
        var state = PathOnDemandState()
        state.Kunits[1] = DirtyIdentityUnit()
        var changed = state
        changed.Kunits[1]?.hp = 2
        changed.Kunits[3] = DirtyIdentityUnit()
        changed.boss.inner.deep = 4
        let tables = SyncTableBroadcastDiff<PathOnDemandState>(pathCursor: nil, typedLeafValues: true)
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        let patches = tables.diff(changed, fields: nil, drops: &drops).patches
        #expect(patches.count == 3)
        #expect(patches.allSatisfy { !$0.isSplitOnly && $0.split == nil })
    }

    #if DEBUG
    @Test(
        "Encoding split-only patches builds no path: an atomic leaf, a nested atomic value in a row create, a row delete, a plain field",
        arguments: [false, true]
    )
    func encodingBuildsNoPath(pathIndex: Bool) throws {
        let hasher = PathHasher(pathHashes: Dictionary(uniqueKeysWithValues: [
            "units", "units.*", "units.*.marker", "units.*.hp",
        ].map { ($0, DeterministicHash.fnv1a32($0)) }))
        let layout = AtomicLayoutTable.forState(PathOnDemandAtomicState.self)
        /// The typed diff's walk of `path`; `rowSlot` tags the row below `/units/<key>`.
        func split(_ path: String, rowSlot: Int32? = nil) throws -> PatchSplit {
            var cursor = hasher.rootCursor
            for (depth, component) in PathHasher.components(of: path).enumerated() {
                cursor = try #require(cursor.descending(component))
                if depth == 1, let rowSlot { cursor = cursor.asRow(rowSlot) }
            }
            #expect(cursor.isLossless)
            return try #require(cursor.split)
        }
        var unit = PathOnDemandUnit()
        unit.marker = PathOnDemandMarker(origin: PathOnDemandXY(x: 3, y: 4), radius: 5)
        let marker = try SnapshotValue.make(from: unit.marker)
        let row = try SnapshotValue.broadcastView(of: unit)
        // (path, operation, the split as the typed diff tags it)
        let frame: [(String, PatchOperation, PatchSplit)] = [
            ("/units/1/marker", .set(marker), try split("/units/1/marker", rowSlot: 0)),
            ("/units/1/hp", .set(.int(9)), try split("/units/1/hp", rowSlot: 0)),
            ("/units/7", .set(row), try split("/units/7").asRow(1, generation: 1)),
            ("/units/2", .delete, try split("/units/2", rowSlot: 2)),
        ]
        let splitOnly = frame.map { StatePatch(split: $0.2, operation: $0.1) }
        let stored = frame.map { StatePatch(path: $0.0, operation: $0.1, split: $0.2) }
        #expect(splitOnly.map(\.path) == frame.map(\.0))

        for rows in [false, true] {
            let json = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, atomicLayout: layout, pathIndex: pathIndex).withRowAddressing(rows)
            let pack = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, atomicLayout: layout, pathIndex: pathIndex).withRowAddressing(rows)
            let freshJSON = OpcodeJSONStateUpdateEncoder(pathHasher: hasher, atomicLayout: layout, pathIndex: pathIndex).withRowAddressing(rows)
            let freshPack = OpcodeMessagePackStateUpdateEncoder(pathHasher: hasher, atomicLayout: layout, pathIndex: pathIndex).withRowAddressing(rows)
            let counter = PathRebuildCounter()
            let (jsonBytes, packBytes) = try StatePatch.$pathRebuilds.withValue(counter) {
                (
                    try json.encode(update: .diff(splitOnly), landID: "path-on-demand", playerID: PlayerID("p")),
                    try pack.encode(update: .diff(splitOnly), landID: "path-on-demand", playerID: PlayerID("p"))
                )
            }
            #expect(counter.count == 0, "rows \(rows): a success-path reader built a path")
            // The same bytes as the stored pair's frame.
            #expect(jsonBytes == (try freshJSON.encode(update: .diff(stored), landID: "path-on-demand", playerID: PlayerID("p"))))
            #expect(packBytes == (try freshPack.encode(update: .diff(stored), landID: "path-on-demand", playerID: PlayerID("p"))))
        }
    }
    #endif
}
