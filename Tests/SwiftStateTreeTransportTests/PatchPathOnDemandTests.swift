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
            #expect(patch.path.hasPrefix("/K"), "the emitted bytes, not the label's")
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
    }
}
