// Tests/SwiftStateTreeTests/SyncEngineVisibilityTransitionTests.swift
//
// Per-player visibility that changes across sync cycles, with dirty tracking on (#58). After
// every cycle, a client-side copy built only from the emitted patches must equal the server-side
// projection for that player, for each way the transport extracts and diffs.

import Foundation
import Testing
@testable import SwiftStateTree

/// Who may see a value: the comma-separated player IDs before the first ":" (pure in the value
/// and the player, as filters must be for dirty tracking to stay correct).
private func visible(_ value: String, to playerID: PlayerID) -> Bool {
    guard let audience = value.split(separator: ":", maxSplits: 1).first else { return false }
    return audience.split(separator: ",").contains { $0 == playerID.rawValue }
}

@StateNodeBuilder
struct VisibilityTransitionState: StateNodeProtocol {
    @Sync(.broadcast)
    var tick: Int = 0

    /// Top-level field: hidden (nil) from players not in its audience.
    @Sync(.perPlayer { banner, playerID in visible(banner, to: playerID) ? banner : nil })
    var banner: String = ""

    /// Dictionary filtered per player: each entry is visible to its own audience.
    @Sync(.perPlayer { entities, playerID in entities.filter { visible($0.value, to: playerID) } })
    var entities: [String: String] = [:]
}

/// How the transport extracts snapshots (`useSnapshotForSync` on and off). Either way it diffs
/// as the transport does: the broadcast diff once per cycle, shared by every player, then each
/// player's update from it and that player's own snapshot.
enum VisibilitySyncPath: String, CaseIterable, Sendable, CustomStringConvertible {
    /// `useSnapshotForSync` off: broadcast and each player's snapshot extracted separately.
    case separateExtraction
    /// `useSnapshotForSync` on: one `snapshotForSync` walk for broadcast and every player.
    case snapshotForSync

    var description: String { rawValue }
}

/// One server engine and one client copy per player.
private struct VisibilityHarness {
    let path: VisibilitySyncPath
    var engine = SyncEngine(for: VisibilityTransitionState.self)
    var state = VisibilityTransitionState()
    var clients: [PlayerID: SnapshotClientView] = [:]

    init(path: VisibilitySyncPath) {
        self.path = path
    }

    /// A joiner, at any time: seeded from its join snapshot as the transport does (which also
    /// fills the engine's caches); its next update is the `.firstSync` the transport applies.
    mutating func join(_ playerID: PlayerID) throws {
        let snapshot = try engine.lateJoinSnapshot(for: playerID, from: state)
        clients[playerID] = SnapshotClientView(fields: snapshot.values)
    }

    /// One sync cycle: every client applies its update, then the state's dirty flags clear.
    mutating func sync() throws {
        let players = clients.keys.sorted { $0.rawValue < $1.rawValue }
        let mode: SnapshotMode = state.isDirty() ? .dirtyTracking(state.getDirtyFields()) : .all
        let extracted: (broadcast: StateSnapshot, perPlayer: [PlayerID: StateSnapshot])
        switch path {
        case .snapshotForSync:
            extracted = try engine.extractWithSnapshotForSync(from: state, playerIDs: players, mode: mode)
        case .separateExtraction:
            var perPlayer: [PlayerID: StateSnapshot] = [:]
            for playerID in players {
                perPlayer[playerID] = try engine.extractPerPlayerSnapshot(for: playerID, from: state, mode: mode)
            }
            extracted = (try engine.extractBroadcastSnapshot(from: state, mode: mode), perPlayer)
        }
        let broadcastDiff = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: extracted.broadcast, mode: mode)
        for playerID in players {
            let update = engine.generateUpdateFromBroadcastDiff(
                for: playerID,
                broadcastDiff: broadcastDiff,
                perPlayerSnapshot: extracted.perPlayer[playerID] ?? StateSnapshot(values: [:]),
                perPlayerMode: mode
            )
            switch update {
            case .noChange: break
            case .firstSync(let patches), .diff(let patches): try clients[playerID]!.apply(patches)
            }
        }
        state.clearDirty()
    }

    /// Every client's copy equals the server-side projection for its player.
    func expectConverged(_ step: String, sourceLocation: SourceLocation = #_sourceLocation) throws {
        for (playerID, client) in clients {
            let projection = try state.snapshot(for: playerID, dirtyFields: nil).values
            #expect(client.fields == projection, "\(path), \(step), player \(playerID.rawValue)", sourceLocation: sourceLocation)
        }
    }
}

@Suite("Per-player visibility transitions across sync cycles (dirty tracking on)")
struct SyncEngineVisibilityTransitionTests {
    let p1 = PlayerID("p1")
    let p2 = PlayerID("p2")

    @Test("A top-level field goes visible, hidden and visible again", arguments: VisibilitySyncPath.allCases)
    func topLevelField(path: VisibilitySyncPath) throws {
        var h = VisibilityHarness(path: path)
        try h.join(p1)
        try h.join(p2)
        try h.sync()
        try h.expectConverged("initial")

        let steps: [(String, String)] = [
            ("visible to p1", "p1:hello"),
            ("hidden from p1, visible to p2", "p2:hello"),
            ("visible to both", "p1,p2:hello"),
            ("hidden from both", "nobody:hello"),
            ("visible to p1 again, new value", "p1:again"),
            ("unchanged", "p1:again"),
            ("hidden from p1", "nobody:again"),
            // The value p1 last saw: a cache that kept the hidden value would send nothing.
            ("visible to p1 again, the value it last saw", "p1:again"),
        ]
        for (index, (step, banner)) in steps.enumerated() {
            if h.state.banner != banner { h.state.banner = banner }
            h.state.tick = index + 1
            try h.sync()
            try h.expectConverged(step)
        }
    }

    @Test("Dictionary entries enter and leave each player's view repeatedly", arguments: VisibilitySyncPath.allCases)
    func dictionaryEntries(path: VisibilitySyncPath) throws {
        var h = VisibilityHarness(path: path)
        try h.join(p1)
        try h.join(p2)
        h.state.entities = ["e1": "p1:a", "e2": "p2:b"]
        try h.sync()
        try h.expectConverged("initial")

        for cycle in 0..<6 {
            // e1 alternates between the players, e2 between both and nobody, e3 comes and goes.
            h.state.entities["e1"] = cycle.isMultiple(of: 2) ? "p2:a\(cycle)" : "p1:a\(cycle)"
            h.state.entities["e2"] = cycle.isMultiple(of: 2) ? "nobody:b" : "p1,p2:b"
            if cycle.isMultiple(of: 3) {
                h.state.entities.removeValue(forKey: "e3")
            } else {
                h.state.entities["e3"] = "p1:c\(cycle)"
            }
            try h.sync()
            try h.expectConverged("cycle \(cycle)")
        }

        // Everything hidden from everyone, then everything visible to everyone.
        h.state.entities = h.state.entities.mapValues { "nobody:" + $0.split(separator: ":").last! }
        try h.sync()
        try h.expectConverged("all hidden")
        h.state.entities = h.state.entities.mapValues { "p1,p2:" + $0.split(separator: ":").last! }
        try h.sync()
        try h.expectConverged("all visible")
    }

    @Test("A late joiner sees an entry that was hidden from it when it joined", arguments: VisibilitySyncPath.allCases)
    func lateJoinWhileHidden(path: VisibilitySyncPath) throws {
        var h = VisibilityHarness(path: path)
        try h.join(p1)
        h.state.entities = ["e1": "p1:a", "e2": "p1:secret"]
        h.state.banner = "p1:only"
        try h.sync()
        try h.expectConverged("before join")

        h.state.tick = 1
        try h.join(p2)
        try h.sync()
        try h.expectConverged("after join, still hidden from p2")

        h.state.entities["e2"] = "p1,p2:secret"
        h.state.banner = "p1,p2:only"
        try h.sync()
        try h.expectConverged("entry and banner visible to p2")

        h.state.entities["e2"] = "p1:secret"
        h.state.banner = "p1:only"
        try h.sync()
        try h.expectConverged("hidden from p2 again")
    }
}

/// The cache-merge sites the multi-player harness does not reach: a single player's
/// `generateDiff` (per-player cache, unstaged), a broadcast diff from a hand-built snapshot
/// (broadcast cache, staged), and `onlyPaths`.
@Suite("Dirty-tracking cache after a field leaves the view")
struct SyncEngineVanishedFieldCacheTests {
    let p1 = PlayerID("p1")

    /// One `generateDiff` cycle for `p1`, applied to `client`; the state's dirty flags clear.
    private func sync(
        _ engine: inout SyncEngine,
        _ state: inout VisibilityTransitionState,
        _ client: inout SnapshotClientView,
        onlyPaths: Set<String>? = nil,
        useDirtyTracking: Bool = true
    ) throws {
        switch try engine.generateDiff(for: p1, from: state, onlyPaths: onlyPaths, useDirtyTracking: useDirtyTracking) {
        case .noChange: break
        case .firstSync(let patches), .diff(let patches): try client.apply(patches)
        }
        state.clearDirty()
    }

    @Test("A single player's generateDiff: hidden, then back with the value it last saw")
    func singlePlayerGenerateDiff() throws {
        var engine = SyncEngine(for: VisibilityTransitionState.self)
        var state = VisibilityTransitionState()
        var client = SnapshotClientView(fields: try engine.lateJoinSnapshot(for: p1, from: state).values)
        for (step, banner) in [("visible", "p1:x"), ("hidden", "nobody:x"), ("hidden, new value", "nobody:y"), ("back, the value it last saw", "p1:x")] {
            state.banner = banner
            try sync(&engine, &state, &client)
            #expect(client.fields == (try state.snapshot(for: p1, dirtyFields: nil).values), "\(step)")
        }
    }

    @Test("A removal outside onlyPaths stays cached and is delivered by the next unfiltered sync")
    func filteredRemovalIsDeliveredLater() throws {
        var engine = SyncEngine(for: VisibilityTransitionState.self)
        var state = VisibilityTransitionState()
        var client = SnapshotClientView(fields: try engine.lateJoinSnapshot(for: p1, from: state).values)
        state.banner = "p1:x"
        try sync(&engine, &state, &client)
        #expect(client.fields["banner"] == .string("p1:x"))

        // Hidden in a cycle limited to /tick: the client keeps the banner for now.
        state.banner = "nobody:x"
        state.tick = 1
        try sync(&engine, &state, &client, onlyPaths: ["/tick"])
        #expect(client.fields["banner"] == .string("p1:x"))
        #expect(client.fields["tick"] == .int(1))

        // The next unfiltered sync sends the delete the filtered one held back.
        try sync(&engine, &state, &client, useDirtyTracking: false)
        #expect(client.fields == (try state.snapshot(for: p1, dirtyFields: nil).values))
        #expect(client.fields["banner"] == nil)
    }

    @Test("The broadcast cache drops a dirty field the snapshot no longer has")
    func broadcastSnapshotDiff() {
        var engine = SyncEngine(for: VisibilityTransitionState.self)
        func diff(_ values: [String: SnapshotValue], dirty: Set<String>) -> [StatePatch] {
            engine.computeBroadcastDiffFromSnapshot(currentBroadcast: StateSnapshot(values: values), mode: .dirtyTracking(dirty))
        }
        _ = engine.computeBroadcastDiffFromSnapshot(currentBroadcast: StateSnapshot(values: ["a": .int(1), "b": .int(2)]), mode: .all)
        var client = SnapshotClientView(fields: ["a": .int(1), "b": .int(2)])

        let steps: [(String, [String: SnapshotValue], Set<String>)] = [
            ("b leaves", [:], ["b"]),
            ("b still gone, dirty again", [:], ["b"]),
            ("b back with its old value", ["b": .int(2)], ["b"]),
        ]
        for (step, values, dirty) in steps {
            let patches = diff(values, dirty: dirty)
            #expect((try? client.apply(patches)) != nil, "\(step): \(patches)")
        }
        #expect(client.fields == ["a": .int(1), "b": .int(2)])
    }
}
