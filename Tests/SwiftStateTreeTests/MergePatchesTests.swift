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
}
