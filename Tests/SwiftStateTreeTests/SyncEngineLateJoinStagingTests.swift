// Tests/SwiftStateTreeTests/SyncEngineLateJoinStagingTests.swift
//
// A staged firstSync (`lateJoinSnapshot(for:from:staged:)`, #91) stages a player's cache only
// when the player has none. Over a player that's already cached, applying it must keep the
// cache, so the next diff is still against what that player was last sent. An overwrite would
// make a change the player never received look already sent (#98's second layer).

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("SyncEngine staged late join keeps an existing cache (#91, #98)")
struct SyncEngineLateJoinStagingTests {
    enum Variant: CaseIterable, Sendable { case plain, withDrops }

    @Test("A staged firstSync over a cached player leaves its cache, so the next diff carries X→Y", arguments: Variant.allCases)
    func stagedFirstSyncKeepsExistingCache(variant: Variant) throws {
        var engine = SyncEngine(for: OptimizationTestStateRootNode.self)
        var state = OptimizationTestStateRootNode()
        let player = PlayerID("alice")

        // The player's cache holds X.
        state.hands[player] = ["x"]
        _ = try engine.generateDiff(for: player, from: state)

        // The state moves to Y, and a firstSync for the player is planned from Y and applied.
        state.hands[player] = ["y"]
        var staged = SyncEngine.StagedCaches()
        switch variant {
        case .plain:
            _ = try engine.lateJoinSnapshot(for: player, from: state, staged: &staged)
        case .withDrops:
            var drops = ExtractionDrops()
            _ = engine.lateJoinSnapshot(for: player, from: state, staged: &staged, drops: &drops)
        }
        #expect(staged.perPlayer[player] == nil, "nothing staged over an existing cache")
        engine.applyStaged(staged)

        // The diff at Y is still against X. Had the firstSync overwritten the cache with Y, it
        // would be empty.
        let update = try engine.generateDiff(for: player, from: state)
        guard case .diff(let patches) = update else {
            Issue.record("expected a diff, got \(update)")
            return
        }
        #expect(!patches.isEmpty, "X→Y must be sent: \(update)")
    }
}
