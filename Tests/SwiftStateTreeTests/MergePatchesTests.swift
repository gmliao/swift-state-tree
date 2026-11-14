// Tests/SwiftStateTreeTests/MergePatchesTests.swift
//
// `SyncEngine.mergePatches` with the broadcast index built once per sync (#392): the result is
// the old per-recipient merge's in every case.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("mergePatches with a broadcast index built once per sync (#392)")
struct MergePatchesTests {
    let engine = SyncEngine(for: AsyncResolverConsistencyTestState.self)

    func patch(_ path: String, _ value: Int) -> StatePatch {
        StatePatch(path: path, operation: .set(.int(value)))
    }

    /// The merge as it was before the index (a set of paths, `firstIndex` to replace): the
    /// oracle the indexed merge must match.
    func oldMerge(_ broadcast: [StatePatch], _ perPlayer: [StatePatch]) -> [StatePatch] {
        var merged: [StatePatch] = []
        var seen: Set<String> = []
        for patch in broadcast where !seen.contains(patch.path) {
            merged.append(patch)
            seen.insert(patch.path)
        }
        for patch in perPlayer {
            if !seen.contains(patch.path) {
                merged.append(patch)
                seen.insert(patch.path)
            } else if let index = merged.firstIndex(where: { $0.path == patch.path }) {
                merged[index] = patch
            }
        }
        return merged
    }

    @Test(
        "Duplicates on both sides, canonically equal paths and the order match the old merge",
        arguments: [
            // Broadcast duplicates keep the first.
            ([("/a", 1), ("/b", 2), ("/a", 3)], []),
            // Two per-player patches at one path over an empty broadcast: one patch, the second.
            ([], [("/x", 1), ("/y", 2), ("/x", 3)]),
            // A per-player patch replaces the broadcast one in place; a new path is appended.
            ([("/a", 1), ("/b", 2)], [("/c", 3), ("/a", 4), ("/c", 5)]),
            // Canonically equal spellings (NFC and NFD of one name) are one path, on both sides.
            ([("/m/caf\u{E9}", 1), ("/m/cafe\u{301}", 2)], [("/m/cafe\u{301}", 3), ("/z", 4), ("/m/caf\u{E9}", 5)]),
            ([("/a", 1)], [("/m/cafe\u{301}", 2), ("/m/caf\u{E9}", 3)]),
        ]
    )
    func matchesTheOldMerge(broadcast: [(String, Int)], perPlayer: [(String, Int)]) {
        let b = broadcast.map { patch($0.0, $0.1) }
        let p = perPlayer.map { patch($0.0, $0.1) }
        let expected = oldMerge(b, p)
        let index = SyncEngine.BroadcastMergeIndex(b)
        let merged = engine.mergePatches(index, p)
        #expect(merged == expected)
        // The stored bytes too: the kept patch is the same patch, not only an equal one.
        #expect(merged.map { Array($0.path.utf8) } == expected.map { Array($0.path.utf8) })
        // The index is shared by recipients: a second recipient's merge doesn't see the first's.
        #expect(engine.mergePatches(index, []) == oldMerge(b, []))
        #expect(engine.mergePatches(b, p) == expected)
    }

    /// A split-only patch at `path` (#392): it holds no path string.
    func splitOnly(_ hasher: PathHasher, _ path: String, _ value: Int) throws -> StatePatch {
        var cursor = hasher.rootCursor
        for component in PathHasher.components(of: path) {
            cursor = try #require(cursor.descending(component))
        }
        let patch = StatePatch(split: try #require(cursor.split), operation: .set(.int(value)))
        #expect(patch.isSplitOnly)
        return patch
    }

    @Test("The path index waits for a recipient with per-player patches; the recipients after it still merge")
    func pathIndexOnFirstPerPlayerMerge() throws {
        let hasher = PathHasher(pathHashes: ["m": 1, "m.*": 2])
        let broadcast = [try splitOnly(hasher, "/m/a", 1), try splitOnly(hasher, "/m/b", 2), try splitOnly(hasher, "/m/a", 3)]
        let index = SyncEngine.BroadcastMergeIndex(broadcast)
        let recipients: [[StatePatch]] = [
            [],
            [patch("/m/b", 4), patch("/m/c", 5)],
            [],
            [patch("/m/a", 6)],
            [patch("/m/c", 7), patch("/m/c", 8)],
        ]
        for (number, perPlayer) in recipients.enumerated() {
            let expected = oldMerge(broadcast, perPlayer)
            let merged = engine.mergePatches(index, perPlayer)
            #expect(merged == expected, "recipient \(number)")
            let operations = merged.map { $0.operation }
            #expect(operations == expected.map { $0.operation }, "recipient \(number)")
            #expect(index.hasPathPositionsForTesting == (number >= 1), "recipient \(number)")
        }
    }

    @Test("A broadcast list mixing split and string patches, or two hashers' splits, keeps String equality's duplicates")
    func mixedBroadcastKeepsStringEquality() throws {
        let hasher = PathHasher(pathHashes: ["m": 1, "m.*": 2])
        let other = PathHasher(pathHashes: ["m": 1, "m.*": 2])
        let lists: [[StatePatch]] = [
            [try splitOnly(hasher, "/m/a", 1), patch("/m/a", 2), try splitOnly(hasher, "/m/b", 3)],
            [patch("/m/a", 1), try splitOnly(hasher, "/m/a", 2)],
            [try splitOnly(hasher, "/m/a", 1), try splitOnly(other, "/m/a", 2), try splitOnly(other, "/m/b", 3)],
        ]
        for (number, broadcast) in lists.enumerated() {
            let index = SyncEngine.BroadcastMergeIndex(broadcast)
            let expected = oldMerge(broadcast, [])
            #expect(index.patches == expected, "list \(number)")
            #expect(index.patches.map { $0.operation } == expected.map { $0.operation }, "list \(number)")
            let perPlayer = [patch("/m/a", 9)]
            #expect(engine.mergePatches(index, perPlayer).map { $0.operation } == oldMerge(broadcast, perPlayer).map { $0.operation }, "list \(number)")
        }
    }

    @Test("A split-only patch and a string-form patch at one path are one path, on either side")
    func splitAndStringFormsAreOnePath() throws {
        let hasher = PathHasher(pathHashes: ["m": 1, "m.*": 2])
        let splitBroadcast = [try splitOnly(hasher, "/m/a", 1), try splitOnly(hasher, "/m/b", 2), try splitOnly(hasher, "/m/a", 3)]
        let stringPerPlayer = [patch("/m/b", 4), patch("/m/c", 5), patch("/m/a", 6)]
        let stringBroadcast = [patch("/m/a", 1), patch("/m/b", 2)]
        let splitPerPlayer = [try splitOnly(hasher, "/m/b", 4), try splitOnly(hasher, "/m/c", 5), try splitOnly(hasher, "/m/c", 6)]
        for (b, p) in [(splitBroadcast, stringPerPlayer), (stringBroadcast, splitPerPlayer)] {
            let expected = oldMerge(b, p)
            let merged = engine.mergePatches(SyncEngine.BroadcastMergeIndex(b), p)
            #expect(merged == expected)
            let paths = merged.map { $0.path }
            #expect(paths == ["/m/a", "/m/b", "/m/c"])
            let values = merged.map { $0.operation }
            #expect(values == expected.map { $0.operation })
        }
    }
}
