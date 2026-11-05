// Tests/SwiftStateTreeTests/NestedNodePolicyTests.swift
//
// A nested state node's own @Sync policies apply wherever the node sits: in a map keyed by
// String, PlayerID or Int, in an array, as an optional, as a single field, deeper in a map of
// nodes, and under a per-player parent policy (#175). Every container is checked with a node
// that also has @SnapshotConvertible and with one that does not.

import Foundation
import Testing
@testable import SwiftStateTree

private let alice = PlayerID("alice")
private let bob = PlayerID("bob")

// MARK: - Nodes

/// A node with one field of each policy. Values are distinct, so a leaked one can be found by
/// name and a masked one by value.
@StateNodeBuilder
@SnapshotConvertible
struct ConvertibleProbeNode: StateNodeProtocol {
    @Sync(.broadcast)
    var shown: Int = 7

    @Sync(.serverOnly)
    var secret: Int = 8

    @Sync(.perPlayer({ (value: Int, playerID: PlayerID) in playerID.rawValue == "alice" ? value : nil }))
    var aliceOnly: Int = 9

    @Sync(.masked({ (_: Int) in 0 }))
    var masked: Int = 10

    init() {}
}

/// The same fields without @SnapshotConvertible.
@StateNodeBuilder
struct PlainProbeNode: StateNodeProtocol {
    @Sync(.broadcast)
    var shown: Int = 7

    @Sync(.serverOnly)
    var secret: Int = 8

    @Sync(.perPlayer({ (value: Int, playerID: PlayerID) in playerID.rawValue == "alice" ? value : nil }))
    var aliceOnly: Int = 9

    @Sync(.masked({ (_: Int) in 0 }))
    var masked: Int = 10

    init() {}
}

@StateNodeBuilder
@SnapshotConvertible
struct ConvertibleProbeHolder: StateNodeProtocol {
    @Sync(.broadcast)
    var inner: [String: ConvertibleProbeNode] = ["n": ConvertibleProbeNode()]

    @Sync(.serverOnly)
    var holderSecret: Int = 11

    init() {}
}

@StateNodeBuilder
struct PlainProbeHolder: StateNodeProtocol {
    @Sync(.broadcast)
    var inner: [String: PlainProbeNode] = ["n": PlainProbeNode()]

    @Sync(.serverOnly)
    var holderSecret: Int = 11

    init() {}
}

// MARK: - Roots

@StateNodeBuilder
struct ConvertibleProbeRoot: StateNodeProtocol {
    @Sync(.broadcast) var byString: [String: ConvertibleProbeNode] = ["k": ConvertibleProbeNode()]
    @Sync(.broadcast) var byPlayer: [PlayerID: ConvertibleProbeNode] = [PlayerID("p"): ConvertibleProbeNode()]
    @Sync(.broadcast) var byInt: [Int: ConvertibleProbeNode] = [1: ConvertibleProbeNode()]
    @Sync(.broadcast) var array: [ConvertibleProbeNode] = [ConvertibleProbeNode()]
    @Sync(.broadcast) var optional: ConvertibleProbeNode? = ConvertibleProbeNode()
    @Sync(.broadcast) var single: ConvertibleProbeNode = ConvertibleProbeNode()
    @Sync(.broadcast) var deep: [String: ConvertibleProbeHolder] = ["h": ConvertibleProbeHolder()]
    @Sync(.perPlayer({ (value: [String: ConvertibleProbeNode], _: PlayerID) in value }))
    var perPlayerMap: [String: ConvertibleProbeNode] = ["k": ConvertibleProbeNode()]
    @Sync(.perPlayerSlice())
    var slice: [PlayerID: ConvertibleProbeNode] = [PlayerID("alice"): ConvertibleProbeNode(), PlayerID("bob"): ConvertibleProbeNode()]
    @Sync(.broadcast) var tick: Int = 0

    init() {}
}

@StateNodeBuilder
struct PlainProbeRoot: StateNodeProtocol {
    @Sync(.broadcast) var byString: [String: PlainProbeNode] = ["k": PlainProbeNode()]
    @Sync(.broadcast) var byPlayer: [PlayerID: PlainProbeNode] = [PlayerID("p"): PlainProbeNode()]
    @Sync(.broadcast) var byInt: [Int: PlainProbeNode] = [1: PlainProbeNode()]
    @Sync(.broadcast) var array: [PlainProbeNode] = [PlainProbeNode()]
    @Sync(.broadcast) var optional: PlainProbeNode? = PlainProbeNode()
    @Sync(.broadcast) var single: PlainProbeNode = PlainProbeNode()
    @Sync(.broadcast) var deep: [String: PlainProbeHolder] = ["h": PlainProbeHolder()]
    @Sync(.perPlayer({ (value: [String: PlainProbeNode], _: PlayerID) in value }))
    var perPlayerMap: [String: PlainProbeNode] = ["k": PlainProbeNode()]
    @Sync(.perPlayerSlice())
    var slice: [PlayerID: PlainProbeNode] = [PlayerID("alice"): PlainProbeNode(), PlayerID("bob"): PlainProbeNode()]
    @Sync(.broadcast) var tick: Int = 0

    init() {}
}

// MARK: - Checks

private let containers = ["byString", "byPlayer", "byInt", "array", "optional", "single", "deep", "perPlayerMap", "slice"]

/// What one container's value shows a player: problems found, as readable strings.
private func violations(in value: SnapshotValue, for playerID: PlayerID?, at path: String) -> [String] {
    var found: [String] = []
    func walk(_ value: SnapshotValue, _ path: String) {
        switch value {
        case .object(let object):
            let isProbeNode = object["shown"] != nil
            if isProbeNode || object["secret"] != nil {
                if object["secret"] != nil { found.append("\(path).secret (serverOnly) sent") }
                if let aliceOnly = object["aliceOnly"], playerID != alice {
                    found.append("\(path).aliceOnly (perPlayer) sent to \(playerID?.rawValue ?? "broadcast"): \(aliceOnly)")
                }
                if playerID == alice, object["aliceOnly"] == nil { found.append("\(path).aliceOnly missing for alice") }
                if let masked = object["masked"], masked != .int(0) { found.append("\(path).masked unmasked: \(masked)") }
            }
            if object["holderSecret"] != nil { found.append("\(path).holderSecret (serverOnly) sent") }
            for (key, child) in object.sorted(by: { $0.key < $1.key }) {
                walk(child, "\(path).\(key)")
            }
        case .array(let array):
            for (index, child) in array.enumerated() { walk(child, "\(path)[\(index)]") }
        default:
            break
        }
    }
    walk(value, path)
    return found
}

private func snapshotViolations(_ snapshot: StateSnapshot, for playerID: PlayerID?) -> [String] {
    containers.flatMap { name in snapshot.values[name].map { violations(in: $0, for: playerID, at: name) } ?? [] }
}

private func patchViolations(_ update: StateUpdate, for playerID: PlayerID) -> [String] {
    let patches: [StatePatch]
    switch update {
    case .firstSync(let p), .diff(let p): patches = p
    case .noChange: patches = []
    }
    return patches.flatMap { patch -> [String] in
        let leaf = patch.path.split(separator: "/").last.map(String.init) ?? ""
        var found: [String] = []
        if leaf == "secret" || leaf == "holderSecret" { found.append("patch \(patch.path) (serverOnly)") }
        if leaf == "aliceOnly", playerID != alice { found.append("patch \(patch.path) (perPlayer) to \(playerID.rawValue)") }
        switch patch.operation {
        case .set(let value), .add(let value):
            found += violations(in: value, for: playerID, at: "patch \(patch.path)")
        case .delete:
            break
        }
        return found
    }
}

/// Every view of the state a client can receive, for both players, after a first sync and
/// after a change to every field of every probe node.
private func allViolations<Root: StateNodeProtocol>(
    _ root: inout Root,
    change: (inout Root) -> Void
) throws -> [String] {
    var found: [String] = []
    for player in [alice, bob] {
        found += snapshotViolations(try root.snapshot(for: player, dirtyFields: nil), for: player).map { "snapshot(for: \(player.rawValue)) \($0)" }
    }
    found += snapshotViolations(try root.broadcastSnapshot(dirtyFields: nil), for: nil).map { "broadcastSnapshot \($0)" }
    let forSync = try root.snapshotForSync(playerIDs: [alice, bob], dirtyFields: nil)
    found += snapshotViolations(forSync.broadcast, for: nil).map { "snapshotForSync broadcast \($0)" }
    for (player, snapshot) in forSync.perPlayer {
        found += snapshotViolations(snapshot, for: player).map { "snapshotForSync \(player.rawValue) \($0)" }
    }
    for useDirtyTracking in [true, false] {
        var engine = SyncEngine()
        var state = root
        for player in [alice, bob] {
            // The joiner's full state (what a late join or a first sync sends).
            found += snapshotViolations(try engine.lateJoinSnapshot(for: player, from: state), for: player)
                .map { "lateJoinSnapshot \(player.rawValue) \($0)" }
        }
        for player in [alice, bob] {
            found += patchViolations(try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking), for: player)
                .map { "firstSync \(player.rawValue) dirty=\(useDirtyTracking) \($0)" }
        }
        state.clearDirty()
        change(&state)
        for player in [alice, bob] {
            found += patchViolations(try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking), for: player)
                .map { "diff \(player.rawValue) dirty=\(useDirtyTracking) \($0)" }
        }
    }
    return found
}

private func changeConvertible(_ node: inout ConvertibleProbeNode, _ step: Int) {
    node.shown += step; node.secret += step; node.aliceOnly += step; node.masked += step
}

private func changePlain(_ node: inout PlainProbeNode, _ step: Int) {
    node.shown += step; node.secret += step; node.aliceOnly += step; node.masked += step
}

@Suite("Nested state node policies apply in every container (#175)")
struct NestedNodePolicyTests {
    @Test("A @SnapshotConvertible node keeps its own policies in every container")
    func convertibleNode() throws {
        var root = ConvertibleProbeRoot()
        let found = try allViolations(&root, change: changeConvertibleRoot)
        let leaks = found.filter { !$0.contains("missing for alice") }
        #expect(leaks.isEmpty, "\(leaks.count) violations:\n\(leaks.joined(separator: "\n"))")
    }

    @Test("A node without @SnapshotConvertible keeps its own policies in every container")
    func plainNode() throws {
        var root = PlainProbeRoot()
        let found = try allViolations(&root, change: changePlainRoot)
        let leaks = found.filter { !$0.contains("missing for alice") }
        #expect(leaks.isEmpty, "\(leaks.count) violations:\n\(leaks.joined(separator: "\n"))")
    }

    /// The other direction: a per-player field nested under a broadcast parent is diffed from
    /// the shared broadcast snapshot, which has no player, so its own player loses it when a
    /// diff replaces the whole node (an array element). Not #175; tracked in #179.
    @Test("A per-player field nested under a broadcast array reaches its player in diffs")
    func nestedPerPlayerUnderBroadcastArray() throws {
        for (name, missing) in [
            ("convertible", try { var root = ConvertibleProbeRoot(); return try allViolations(&root, change: changeConvertibleRoot) }()),
            ("plain", try { var root = PlainProbeRoot(); return try allViolations(&root, change: changePlainRoot) }()),
        ].map({ ($0.0, $0.1.filter { $0.contains("missing for alice") }) }) {
            withKnownIssue("nested per-player fields under a broadcast parent are diffed without a player") {
                #expect(missing.isEmpty, "\(name): \(missing.joined(separator: "\n"))")
            }
        }
    }
}

private func changeConvertibleRoot(_ state: inout ConvertibleProbeRoot) {
    state.tick += 1
    changeConvertible(&state.byString["k"]!, 100)
    changeConvertible(&state.byPlayer[PlayerID("p")]!, 100)
    changeConvertible(&state.byInt[1]!, 100)
    changeConvertible(&state.array[0], 100)
    changeConvertible(&state.optional!, 100)
    changeConvertible(&state.single, 100)
    changeConvertible(&state.deep["h"]!.inner["n"]!, 100)
    state.deep["h"]!.holderSecret += 100
    changeConvertible(&state.perPlayerMap["k"]!, 100)
    changeConvertible(&state.slice[alice]!, 100)
    changeConvertible(&state.slice[bob]!, 100)
}

private func changePlainRoot(_ state: inout PlainProbeRoot) {
    state.tick += 1
    changePlain(&state.byString["k"]!, 100)
    changePlain(&state.byPlayer[PlayerID("p")]!, 100)
    changePlain(&state.byInt[1]!, 100)
    changePlain(&state.array[0], 100)
    changePlain(&state.optional!, 100)
    changePlain(&state.single, 100)
    changePlain(&state.deep["h"]!.inner["n"]!, 100)
    state.deep["h"]!.holderSecret += 100
    changePlain(&state.perPlayerMap["k"]!, 100)
    changePlain(&state.slice[alice]!, 100)
    changePlain(&state.slice[bob]!, 100)
}
