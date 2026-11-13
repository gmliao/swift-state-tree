// Tests/SwiftStateTreeTests/SyncPolicyPerTypeTests.swift
//
// A `@Sync` field's policy belongs to its declaration (#520): `@StateNodeBuilder` emits it as a
// static of the node type. Pins when the policy expression is evaluated (once per type in a
// non-generic node, on every read in a generic one), that every reader filters through it, and
// that a node of trivially copyable fields is trivially copyable.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Evaluation

/// A value the policy factories below read when they are evaluated.
final class PolicyEvaluationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0

    func set(_ newValue: Int) { lock.withLock { value = newValue } }
    func get() -> Int { lock.withLock { value } }
}

/// Each counter is read by one fixture type only, which only its own test reads: no other test
/// can evaluate that type's policy first.
let oncePerTypeCounter = PolicyEvaluationCounter()
let perReadCounter = PolicyEvaluationCounter()

/// A policy that replaces every value with the counter's value at the time the policy is
/// evaluated.
func counterPolicy(_ counter: PolicyEvaluationCounter) -> SyncPolicy<Int> {
    let captured = counter.get()
    return .masked { _ in captured }
}

@StateNodeBuilder
struct PolicyOncePerTypeNode: StateNodeProtocol {
    @Sync(counterPolicy(oncePerTypeCounter)) var value: Int = 0
    init() {}
}

@StateNodeBuilder
struct PolicyPerReadNode<Tag: Sendable>: StateNodeProtocol {
    @Sync(counterPolicy(perReadCounter)) var value: Int = 0
    init() {}
}

/// The masked value a node's snapshot carries for `value`.
private func filtered<N: StateNodeProtocol>(_ node: N) throws -> SnapshotValue? {
    try node.snapshot(for: nil, dirtyFields: nil).values["value"]
}

@Suite("Sync policy per declaration")
struct SyncPolicyPerTypeTests {
    @Test("A non-generic node's policy is evaluated once, at its first read, for every instance")
    func oncePerType() throws {
        oncePerTypeCounter.set(1)
        let a = PolicyOncePerTypeNode()
        oncePerTypeCounter.set(2)
        let b = PolicyOncePerTypeNode()
        oncePerTypeCounter.set(3)
        // The first read: not the value at either init.
        #expect(try filtered(a) == .int(3))
        oncePerTypeCounter.set(4)
        #expect(try filtered(a) == .int(3))
        #expect(try filtered(b) == .int(3))
    }

    @Test("A generic node's policy is evaluated on every read")
    func perReadInGenericNode() throws {
        perReadCounter.set(1)
        let a = PolicyPerReadNode<Int>()
        perReadCounter.set(2)
        let b = PolicyPerReadNode<Int>()
        perReadCounter.set(3)
        #expect(try filtered(a) == .int(3))
        perReadCounter.set(4)
        #expect(try filtered(a) == .int(4))
        #expect(try filtered(b) == .int(4))
    }

    // MARK: - Layout

    @Test("A node whose field values are trivially copyable is trivially copyable, whatever its policies")
    func trivialNode() {
        #expect(_isPOD(PolicyTrivialNode.self))
        // Three `Sync<Int>` of size 9 and alignment 8: offsets 0, 16 and 32.
        #expect(MemoryLayout<PolicyTrivialNode>.size == 41)
        #expect(MemoryLayout<PolicyTrivialNode>.stride == 48)
    }

    // MARK: - Every reader through every kind of policy

    @Test("snapshot(for:) filters every kind of policy")
    func snapshotForPlayer() throws {
        let state = PolicyMatrixState.sample
        let a = try state.snapshot(for: PlayerID("a"), dirtyFields: nil).values
        #expect(a["open"] == .int(7))
        #expect(a["hidden"] == nil)
        #expect(a["mine"] == .object(["a": .int(1)]))
        #expect(a["hands"] == .object(["a": .int(3)]))
        #expect(a["bucket"] == .int(5))
        #expect(a["onlyA"] == .int(11))
        #expect(a["doubled"] == .int(10))
        // A filter that keeps a nil value sends null; one that returns nil hides the field.
        #expect(a["maybe"] == .null)
        #expect(a["rows"]?.objectValue?["1"]?.objectValue?["hp"] == .int(10))
        #expect(a["rows"]?.objectValue?["1"]?.objectValue?["bucket"] == .int(9))
        #expect(a["rows"]?.objectValue?["1"]?.objectValue?["secret"] == nil)

        let b = try state.snapshot(for: PlayerID("b"), dirtyFields: nil).values
        #expect(b["mine"] == .object(["b": .int(2)]))
        #expect(b["hands"] == .object(["b": .int(4)]))
        #expect(b["onlyA"] == nil)
        #expect(b["maybe"] == nil)

        let shared = try state.snapshot(for: nil, dirtyFields: nil).values
        #expect(Set(shared.keys) == ["open", "bucket", "doubled", "rows"])
        #expect(shared["bucket"] == .int(5))
        #expect(shared["doubled"] == .int(10))
    }

    @Test("snapshotForSync's broadcast and per-player parts together are each player's snapshot")
    func perPlayerSplit() throws {
        let state = PolicyMatrixState.sample
        let players = [PlayerID("a"), PlayerID("b")]
        let split = try state.snapshotForSync(playerIDs: players, dirtyFields: nil)
        #expect(split.broadcast == (try state.broadcastSnapshot(dirtyFields: nil)))
        // The player-dependent fields are in the per-player part, each filtered for its player.
        let a = try #require(split.perPlayer[PlayerID("a")]).values
        #expect(a["mine"] == .object(["a": .int(1)]))
        #expect(a["hands"] == .object(["a": .int(3)]))
        #expect(a["onlyA"] == .int(11))
        #expect(a["maybe"] == .null)
        let b = try #require(split.perPlayer[PlayerID("b")]).values
        #expect(b["mine"] == .object(["b": .int(2)]))
        #expect(b["hands"] == .object(["b": .int(4)]))
        #expect(b["onlyA"] == nil)
        #expect(b["maybe"] == nil)
        #expect(split.broadcast.values["mine"] == nil)
        for player in players {
            var merged = split.broadcast.values
            for (key, value) in split.perPlayer[player]?.values ?? [:] { merged[key] = value }
            #expect(merged == (try state.snapshot(for: player, dirtyFields: nil)).values, "player \(player.rawValue)")
        }
    }

    @Test("The sync tables read each field through its policy")
    func tablesRead() throws {
        let state = PolicyMatrixState.sample
        let tables = SyncTableBroadcastDiff<PolicyMatrixState>()
        var drops = ExtractionDrops()
        tables.seed(state, drops: &drops)
        let seeded = try #require(tables.lastSentSnapshot).values
        let shared = try state.snapshot(for: nil, dirtyFields: nil).values
        #expect(!seeded.isEmpty)
        for (key, value) in seeded {
            #expect(shared[key] == value, "field \(key)")
        }
        // The node map's rows: the masked field masked, the server-only one left out.
        #expect(seeded["rows"]?.objectValue?["1"]?.objectValue?["bucket"] == .int(9))
        #expect(seeded["rows"]?.objectValue?["1"]?.objectValue?["secret"] == nil)
    }
}

// MARK: - Fixtures

@StateNodeBuilder
struct PolicyTrivialNode: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.perPlayer({ (v: Int, _: PlayerID) in v })) var b: Int = 0
    @Sync(.masked({ (v: Int) in v / 10 })) var c: Int = 0
    init() {}
}

/// A policy that isn't written as `.name` or `.name(...)`: classified `.unknown`.
let policyMatrixDoubling: SyncPolicy<Int> = .masked { $0 * 2 }

@StateNodeBuilder
struct PolicyMatrixRow: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.masked({ (v: Int) in v / 10 })) var bucket: Int = 0
    @Sync(.serverOnly) var secret: Int = 0
    init() {}
}

@StateNodeBuilder
struct PolicyMatrixState: StateNodeProtocol {
    @Sync(.broadcast) var open: Int = 0
    @Sync(.serverOnly) var hidden: Int = 0
    @Sync(.perPlayer({ (v: [String: Int], player: PlayerID) in v.filter { $0.key == player.rawValue } }))
    var mine: [String: Int] = [:]
    @Sync(.perPlayerSlice()) var hands: [PlayerID: Int] = [:]
    @Sync(.masked({ (v: Int) in v / 10 })) var bucket: Int = 0
    @Sync(.custom({ (player: PlayerID, v: Int) in player.rawValue == "a" ? v : nil })) var onlyA: Int = 0
    @Sync(policyMatrixDoubling) var doubled: Int = 0
    @Sync(.perPlayer({ (v: Int?, player: PlayerID) -> Int?? in player.rawValue == "a" ? .some(v) : .none }))
    var maybe: Int? = nil
    @Sync(.broadcast) var rows: [Int: PolicyMatrixRow] = [:]
    init() {}

    static var sample: PolicyMatrixState {
        var state = PolicyMatrixState()
        state.open = 7
        state.hidden = 9
        state.mine = ["a": 1, "b": 2]
        state.hands = [PlayerID("a"): 3, PlayerID("b"): 4]
        state.bucket = 57
        state.onlyA = 11
        state.doubled = 5
        var row = PolicyMatrixRow()
        row.hp = 10
        row.bucket = 99
        row.secret = 5
        state.rows = [1: row]
        return state
    }
}
