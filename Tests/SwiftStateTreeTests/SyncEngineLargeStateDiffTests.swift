// Tests/SwiftStateTreeTests/SyncEngineLargeStateDiffTests.swift

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test Data Structures

/// Test nested structure: Player state with multiple fields
struct BenchmarkPlayerState: StateProtocol {
    var name: String
    var hpCurrent: Int
    var hpMax: Int
}

/// Test nested structure: Hand state containing cards
struct BenchmarkHandState: StateProtocol {
    var ownerID: PlayerID
    var cards: [BenchmarkCard]
}

/// Test nested structure: Card with multiple properties
struct BenchmarkCard: StateProtocol {
    let id: Int
    let suit: Int
    let rank: Int
}

/// Test StateNode with nested struct structures for benchmarking
@StateNodeBuilder
struct BenchmarkStateRootNode: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]

    @Sync(.perPlayerSlice())
    var hands: [PlayerID: BenchmarkHandState] = [:]

    @Sync(.serverOnly)
    var hiddenDeck: [BenchmarkCard] = []

    @Sync(.broadcast)
    var round: Int = 0
}

/// Generate test state with specified size
func generateTestState(
    playerCount: Int,
    cardsPerPlayer: Int
) -> BenchmarkStateRootNode {
    var state = BenchmarkStateRootNode()

    for i in 0..<playerCount {
        let playerID = PlayerID("player_\(i)")

        // Add player
        state.players[playerID] = BenchmarkPlayerState(
            name: "Player \(i)",
            hpCurrent: 100,
            hpMax: 100
        )

        // Add hand with cards
        var cards: [BenchmarkCard] = []
        for j in 0..<cardsPerPlayer {
            cards.append(BenchmarkCard(
                id: i * cardsPerPlayer + j,
                suit: j % 4,
                rank: j % 13
            ))
        }
        state.hands[playerID] = BenchmarkHandState(
            ownerID: playerID,
            cards: cards
        )
    }

    state.round = 1
    return state
}

// MARK: - Large-State Diff Tests

/// A one-field change in a large state (up to 100 players, 10 cards each) produces exactly its own
/// patches, with dirty tracking and with a full compare. Each case syncs two engines on the same
/// state, applies one change, and checks both diffs against the patches the change must produce.
/// Each case also checks the dirty set the change leaves: the same patches come out of a full
/// compare, so a change marked too widely (everything dirty) or a missed mark (an empty dirty set
/// falls back to comparing everything, `SyncEngine.generateDiff`) would pass on the patches alone.
/// SyncEngineDirtyTrackingTests covers the same modes on small states.
///
/// How long either diff takes is measured by `DiffBenchmarkRunner` (SwiftStateTreeBenchmarks), on
/// this same state shape, not here: a millisecond ceiling in a unit test measures the machine's
/// load as much as the code, and fails on a loaded runner (#467).
@Suite("SyncEngine Large-State Diff Tests")
struct SyncEngineLargeStateDiffTests {

    private let viewer = PlayerID("player_0")
    private let changed = PlayerID("player_3")

    @Test("One dirty field: dirty tracking reports the same patch as a full compare")
    func oneDirtyField() throws {
        let diffs = try diffBothWays(generateTestState(playerCount: 100, cardsPerPlayer: 10)) { state in
            state.players[changed]?.hpCurrent = 90
        }
        #expect(diffs.dirtyFields == ["players"])
        let expected = [StatePatch(path: "/players/player_3/hpCurrent", operation: .set(.int(90)))]
        #expect(sortedPatches(diffs.dirtyTracked) == expected, "\(diffs.dirtyTracked)")
        #expect(sortedPatches(diffs.full) == expected, "\(diffs.full)")
    }

    @Test("Several dirty fields: dirty tracking reports every changed field")
    func severalDirtyFields() throws {
        let diffs = try diffBothWays(generateTestState(playerCount: 50, cardsPerPlayer: 5)) { state in
            state.round = 2
            state.players[changed]?.hpCurrent = 80
        }
        #expect(diffs.dirtyFields == ["players", "round"])
        let expected = [
            StatePatch(path: "/players/player_3/hpCurrent", operation: .set(.int(80))),
            StatePatch(path: "/round", operation: .set(.int(2))),
        ]
        #expect(sortedPatches(diffs.dirtyTracked) == expected, "\(diffs.dirtyTracked)")
        #expect(sortedPatches(diffs.full) == expected, "\(diffs.full)")
    }

    @Test("No dirty field: both diffs report no change")
    func noDirtyField() throws {
        let diffs = try diffBothWays(generateTestState(playerCount: 100, cardsPerPlayer: 10)) { _ in }
        #expect(diffs.dirtyFields.isEmpty)
        #expect(diffs.dirtyTracked == .noChange, "\(diffs.dirtyTracked)")
        #expect(diffs.full == .noChange, "\(diffs.full)")
    }

    @Test("A dictionary insert: dirty tracking reports the new entry")
    func dictionaryInsert() throws {
        let diffs = try diffBothWays(generateTestState(playerCount: 50, cardsPerPlayer: 5)) { state in
            state.players[PlayerID("new_player")] = BenchmarkPlayerState(name: "New Player", hpCurrent: 100, hpMax: 100)
        }
        #expect(diffs.dirtyFields == ["players"])
        let expected = [
            StatePatch(
                path: "/players/new_player",
                operation: .set(.object(["name": .string("New Player"), "hpCurrent": .int(100), "hpMax": .int(100)]))
            ),
        ]
        #expect(sortedPatches(diffs.dirtyTracked) == expected, "\(diffs.dirtyTracked)")
        #expect(sortedPatches(diffs.full) == expected, "\(diffs.full)")
    }

    // MARK: - Helpers

    /// Syncs two engines on `state`, applies `change` to it, and diffs the result with dirty
    /// tracking on one engine and a full compare on the other. Also returns the fields the change
    /// left dirty.
    private func diffBothWays(
        _ state: BenchmarkStateRootNode,
        change: (inout BenchmarkStateRootNode) -> Void
    ) throws -> (dirtyTracked: StateUpdate, full: StateUpdate, dirtyFields: Set<String>) {
        var state = state
        var tracked = SyncEngine(for: BenchmarkStateRootNode.self)
        var full = SyncEngine(for: BenchmarkStateRootNode.self)
        _ = try tracked.generateDiff(for: viewer, from: state)
        _ = try full.generateDiff(for: viewer, from: state)
        state.clearDirty()
        change(&state)
        return (
            try tracked.generateDiff(for: viewer, from: state, useDirtyTracking: true),
            try full.generateDiff(for: viewer, from: state, useDirtyTracking: false),
            state.getDirtyFields()
        )
    }

    /// A `.diff`'s patches sorted by path; nil for any other update.
    private func sortedPatches(_ update: StateUpdate) -> [StatePatch]? {
        guard case .diff(let patches) = update else { return nil }
        return patches.sorted { $0.path < $1.path }
    }
}
