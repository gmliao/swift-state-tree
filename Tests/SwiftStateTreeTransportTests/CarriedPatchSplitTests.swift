// Tests/SwiftStateTreeTransportTests/CarriedPatchSplitTests.swift
//
// A patch can carry its path's split (`StatePatch.split`), taken from the encoder's own path trie
// while the typed diff walks the state. The encoder then skips its own split of that path, so a
// carried split must be exactly the hasher's, and one from another hasher must not be used.

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

private let splitPatterns: [String: UInt32] = [
    "round": 1,
    "units": 2,
    "units.*": 3,
    "units.*.hp": 4,
    "units.*.bag": 5,
    "units.*.bag.*": 6,
    "boss": 7,
    "boss.x": 8,
]

/// The cursor walk of `path`, one component at a time from the root.
private func walked(_ hasher: PathHasher, _ path: String) -> PatchSplit? {
    hasher.rootCursor.split(of: path, under: "")
}

@Suite("A carried path split")
struct CarriedPatchSplitTests {
    @Test("The cursor walk gives the hasher's split for every path inside the schema", arguments: [
        "/round", "/units", "/units/7", "/units/-3/hp", "/units/a~1b/hp", "/units/t~0x/bag/k~1",
        "/units//hp", "/units/e\u{301}/hp", "/units/\u{e9}/hp", "/boss", "/boss/x", "/units/hp/hp",
    ])
    func cursorMatchesHasher(path: String) throws {
        let hasher = PathHasher(pathHashes: splitPatterns)
        let own = hasher.splitReportingMatch(path)
        let carried = try #require(walked(hasher, path), "\(path) is inside the schema")
        #expect(own.inSchema)
        #expect(carried.pathHash == own.pathHash)
        #expect(carried.dynamicKeys.map { Array($0.utf8) } == own.dynamicKeys.map { Array($0.utf8) })
        #expect(carried.belongs(to: hasher))
    }

    @Test("A path outside the schema has no carried split", arguments: ["/other", "/round/x", "/boss/y", "/units/1/bag/2/deep"])
    func outsideTheSchema(path: String) {
        let hasher = PathHasher(pathHashes: splitPatterns)
        #expect(hasher.splitReportingMatch(path).inSchema == false)
        #expect(walked(hasher, path) == nil)
    }

    @Test("A split under a base path continues the walk from that base")
    func splitUnderABase() throws {
        let hasher = PathHasher(pathHashes: splitPatterns)
        let units = try #require(hasher.rootCursor.descending("units"))
        let row = try #require(units.descending("a~1b"))
        #expect(row.split(of: "/units/a~1b", under: "/units/a~1b")?.pathHash == 3)
        let bag = try #require(row.split(of: "/units/a~1b/bag/k", under: "/units/a~1b"))
        #expect(bag.pathHash == 6)
        #expect(bag.dynamicKeys == ["a~1b", "k"])
    }

    @Test("The encoder's split takes a carried one only from its own hasher, patch by patch")
    func mixedListsAndForeignSplits() throws {
        let hasher = PathHasher(pathHashes: splitPatterns)
        // Same patterns, other hashes: its splits must never reach `hasher`'s frames.
        let other = PathHasher(pathHashes: splitPatterns.mapValues { $0 + 100 })
        let paths = ["/units/1/hp", "/round", "/units/2/bag/k", "/other/1/x"]
        let patches = paths.enumerated().map { index, path -> StatePatch in
            let operation = PatchOperation.set(.int(index))
            switch index {
            case 0: return StatePatch(path: path, operation: operation, split: walked(hasher, path))
            case 2: return StatePatch(path: path, operation: operation, split: walked(other, path))
            default: return StatePatch(path: path, operation: operation)
            }
        }
        #expect(patches[2].split != nil, "the foreign split is carried")
        for patch in patches {
            let used = FieldMergePlan.split(of: patch, hasher: hasher)
            let own = hasher.splitReportingMatch(patch.path)
            #expect(used.pathHash == own.pathHash, "\(patch.path)")
            #expect(used.dynamicKeys == own.dynamicKeys, "\(patch.path)")
            #expect(used.inSchema == own.inSchema, "\(patch.path)")
        }
        // The frame's splits are the hasher's, with and without the prefix cache.
        let expected = paths.map { hasher.splitReportingMatch($0).pathHash }
        for cache in [nil, FramePrefixCache()] as [FramePrefixCache?] {
            for _ in 0..<2 {
                let result = FieldMergePlan.splitsAndEntries(patches: patches, hasher: hasher, table: nil, cache: cache)
                #expect(result.splits.map(\.pathHash) == expected)
            }
        }
    }

    @Test("The typed diff's patches carry the hasher's split; a fallback field's and a hasher-less diff's don't")
    func typedDiffCarriesSplits() throws {
        let hasher = PathHasher(pathHashes: [
            "round": 1, "title": 2, "monsters": 3, "monsters.*": 4, "positions": 5, "positions.*": 6,
            "units": 7, "units.*": 8, "units.*.hp": 9, "units.*.x": 10, "boss": 11, "boss.hp": 12, "boss.x": 13,
        ])
        var state = DirtyIdentityState()
        state.units[1] = DirtyIdentityUnit()
        state.units[-2] = DirtyIdentityUnit()
        state.monsters[5] = 50
        state.positions["a/b"] = 1
        var changed = state
        changed.round = 3
        changed.units[1]?.hp = 9
        changed.units[-2] = nil
        changed.units[7] = DirtyIdentityUnit()
        changed.monsters[5] = 51
        changed.monsters[6] = 60
        changed.positions["a/b"] = 2
        changed.boss.x = 4

        for cursor in [hasher.rootCursor, nil] as [PathHasher.Cursor?] {
            let tables = SyncTableBroadcastDiff<DirtyIdentityState>(pathCursor: cursor)
            var drops = ExtractionDrops()
            tables.seed(state, drops: &drops)
            let patches = tables.diff(changed, fields: nil, drops: &drops).patches
            #expect(Set(patches.map(\.path)) == [
                "/round", "/units/1/hp", "/units/-2", "/units/7", "/monsters/5", "/monsters/6", "/positions/a~1b", "/boss/x",
            ])
            for patch in patches {
                guard cursor != nil else {
                    #expect(patch.split == nil, "\(patch.path)")
                    continue
                }
                let carried = try #require(patch.split, "\(patch.path) carries its split")
                let own = hasher.splitReportingMatch(patch.path)
                #expect(carried.belongs(to: hasher))
                #expect(own.inSchema && carried.pathHash == own.pathHash && carried.dynamicKeys == own.dynamicKeys, "\(patch.path)")
            }
        }
    }

    @Test("The split is not part of a patch's value")
    func equalityAndCodingIgnoreTheSplit() throws {
        let hasher = PathHasher(pathHashes: splitPatterns)
        let plain = StatePatch(path: "/units/1/hp", operation: .set(.int(3)))
        let carrying = StatePatch(path: "/units/1/hp", operation: .set(.int(3)), split: walked(hasher, "/units/1/hp"))
        #expect(carrying.split != nil)
        #expect(plain == carrying)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        #expect(try encoder.encode(plain) == encoder.encode(carrying))
        #expect(try JSONDecoder().decode(StatePatch.self, from: encoder.encode(carrying)).split == nil)
    }
}
