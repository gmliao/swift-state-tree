// Tests/SwiftStateTreeTests/NestedNodePolicyTests.swift
//
// A nested state node's own @Sync policies apply wherever the node sits: in a map keyed by
// String, PlayerID or Int, in an array, as an optional, as a single field, deeper in a map of
// nodes, and under a per-player parent policy (#175). Every container is checked with a node
// that also has @SnapshotConvertible and with one that does not.
//
// The nesting rule (#179): a per-player field must not have a broadcast ancestor
// (`SyncPolicyNesting`). Broadcast containers therefore hold nodes with broadcast, server-only
// and masked fields; per-player parents hold nodes with a per-player field too.

import Foundation
import Testing
@testable import SwiftStateTree

private let alice = PlayerID("alice")
private let bob = PlayerID("bob")

/// The mask: a negated value. Raw values are positive, so an unmasked one is found by its sign,
/// and a stale masked one by the view check.
private let negate: @Sendable (Int) -> Int = { -$0 }

// MARK: - Nodes for broadcast containers

/// A node with one field of each player-independent policy. Values are distinct, so a leaked
/// one can be found by name and an unmasked one by its sign.
@StateNodeBuilder
@SnapshotConvertible
struct ConvertibleProbeNode: StateNodeProtocol {
    @Sync(.broadcast)
    var shown: Int = 7

    @Sync(.serverOnly)
    var secret: Int = 8

    @Sync(.masked({ (value: Int) in -value }))
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

    @Sync(.masked({ (value: Int) in -value }))
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

// MARK: - Nodes for per-player parents

/// A node with a per-player field as well. `ppShown` marks it, so the checks know to expect
/// `aliceOnly` for alice.
@StateNodeBuilder
@SnapshotConvertible
struct ConvertiblePerPlayerProbeNode: StateNodeProtocol {
    @Sync(.broadcast)
    var ppShown: Int = 7

    @Sync(.serverOnly)
    var secret: Int = 8

    @Sync(.perPlayer({ (value: Int, playerID: PlayerID) in playerID.rawValue == "alice" ? value : nil }))
    var aliceOnly: Int = 9

    @Sync(.masked({ (value: Int) in -value }))
    var masked: Int = 10

    init() {}
}

@StateNodeBuilder
struct PlainPerPlayerProbeNode: StateNodeProtocol {
    @Sync(.broadcast)
    var ppShown: Int = 7

    @Sync(.serverOnly)
    var secret: Int = 8

    @Sync(.perPlayer({ (value: Int, playerID: PlayerID) in playerID.rawValue == "alice" ? value : nil }))
    var aliceOnly: Int = 9

    @Sync(.masked({ (value: Int) in -value }))
    var masked: Int = 10

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
    @Sync(.perPlayer({ (value: [String: ConvertiblePerPlayerProbeNode], _: PlayerID) in value }))
    var perPlayerMap: [String: ConvertiblePerPlayerProbeNode] = ["k": ConvertiblePerPlayerProbeNode()]
    @Sync(.perPlayerSlice())
    var slice: [PlayerID: ConvertiblePerPlayerProbeNode] = [PlayerID("alice"): ConvertiblePerPlayerProbeNode(), PlayerID("bob"): ConvertiblePerPlayerProbeNode()]
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
    @Sync(.perPlayer({ (value: [String: PlainPerPlayerProbeNode], _: PlayerID) in value }))
    var perPlayerMap: [String: PlainPerPlayerProbeNode] = ["k": PlainPerPlayerProbeNode()]
    @Sync(.perPlayerSlice())
    var slice: [PlayerID: PlainPerPlayerProbeNode] = [PlayerID("alice"): PlainPerPlayerProbeNode(), PlayerID("bob"): PlainPerPlayerProbeNode()]
    @Sync(.broadcast) var tick: Int = 0

    init() {}
}

// MARK: - Checks

private let containers = ["byString", "byPlayer", "byInt", "array", "optional", "single", "deep", "perPlayerMap", "slice"]

private func isUnmasked(_ value: SnapshotValue) -> Bool {
    if case .int(let raw) = value { return raw > 0 }
    return true
}

/// What one container's value shows a player: problems found, as readable strings.
private func violations(in value: SnapshotValue, for playerID: PlayerID?, at path: String) -> [String] {
    var found: [String] = []
    func walk(_ value: SnapshotValue, _ path: String) {
        switch value {
        case .object(let object):
            let isProbeNode = object["shown"] != nil || object["ppShown"] != nil
            if isProbeNode || object["secret"] != nil {
                if object["secret"] != nil { found.append("\(path).secret (serverOnly) sent") }
                if let aliceOnly = object["aliceOnly"], playerID != alice {
                    found.append("\(path).aliceOnly (perPlayer) sent to \(playerID?.rawValue ?? "broadcast"): \(aliceOnly)")
                }
                if object["ppShown"] != nil, playerID == alice, object["aliceOnly"] == nil {
                    found.append("\(path).aliceOnly missing for alice")
                }
                if let masked = object["masked"], isUnmasked(masked) { found.append("\(path).masked unmasked: \(masked)") }
                if isProbeNode, object["masked"] == nil { found.append("\(path).masked missing") }
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
    patches(of: update).flatMap { patch -> [String] in
        let leaf = patch.path.split(separator: "/").last.map(String.init) ?? ""
        var found: [String] = []
        if leaf == "secret" || leaf == "holderSecret" { found.append("patch \(patch.path) (serverOnly)") }
        if leaf == "aliceOnly", playerID != alice { found.append("patch \(patch.path) (perPlayer) to \(playerID.rawValue)") }
        switch patch.operation {
        case .set(let value), .add(let value):
            // A scalar patch of the masked field itself, not only one inside an object value.
            if leaf == "masked", isUnmasked(value) { found.append("patch \(patch.path) masked unmasked: \(value)") }
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
        for player in [alice, bob] {
            // A fresh engine per player: with a shared one, the first player's diff consumes the
            // broadcast changes, and a per-player field leaked into a broadcast patch would never
            // reach the second player's diff.
            var engine = SyncEngine(for: type(of: root))
            var state = root
            let label = "\(player.rawValue) dirty=\(useDirtyTracking)"
            // The joiner's full state (what a late join or a first sync sends).
            let joined = try engine.lateJoinSnapshot(for: player, from: state)
            found += snapshotViolations(joined, for: player).map { "lateJoinSnapshot \(label) \($0)" }
            var view = SnapshotClientView(fields: joined.values)

            let first = try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking)
            found += patchViolations(first, for: player).map { "firstSync \(label) \($0)" }
            try view.apply(patches(of: first))
            found += viewDifferences(view, try state.snapshot(for: player, dirtyFields: nil)).map { "firstSync \(label) \($0)" }

            state.clearDirty()
            change(&state)
            let diff = try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking)
            found += patchViolations(diff, for: player).map { "diff \(label) \($0)" }
            // The client's copy after the patches must be the player's own view of the state.
            try view.apply(patches(of: diff))
            found += viewDifferences(view, try state.snapshot(for: player, dirtyFields: nil)).map { "diff \(label) \($0)" }
        }
    }
    return found
}

private func patches(of update: StateUpdate) -> [StatePatch] {
    switch update {
    case .firstSync(let p), .diff(let p): return p
    case .noChange: return []
    }
}

/// The paths, down to the leaf, where a client's patched copy differs from `snapshot(for:)`.
private func viewDifferences(_ view: SnapshotClientView, _ expected: StateSnapshot) -> [String] {
    var found: [String] = []
    func walk(_ actual: SnapshotValue?, _ wanted: SnapshotValue?, _ path: String) {
        guard actual != wanted else { return }
        switch (actual, wanted) {
        case (.object(let a)?, .object(let w)?):
            for key in Set(a.keys).union(w.keys).sorted() { walk(a[key], w[key], "\(path).\(key)") }
        case (.array(let a)?, .array(let w)?) where a.count == w.count:
            for index in a.indices { walk(a[index], w[index], "\(path)[\(index)]") }
        default:
            found.append("view differs from snapshot(for:) at \(path)")
        }
    }
    for field in Set(view.fields.keys).union(expected.values.keys).sorted() {
        walk(view.fields[field], expected.values[field], field)
    }
    return found
}

private func changeConvertible(_ node: inout ConvertibleProbeNode, _ step: Int) {
    node.shown += step; node.secret += step; node.masked += step
}

private func changePlain(_ node: inout PlainProbeNode, _ step: Int) {
    node.shown += step; node.secret += step; node.masked += step
}

private func changeConvertiblePerPlayer(_ node: inout ConvertiblePerPlayerProbeNode, _ step: Int) {
    node.ppShown += step; node.secret += step; node.aliceOnly += step; node.masked += step
}

private func changePlainPerPlayer(_ node: inout PlainPerPlayerProbeNode, _ step: Int) {
    node.ppShown += step; node.secret += step; node.aliceOnly += step; node.masked += step
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
    changeConvertiblePerPlayer(&state.perPlayerMap["k"]!, 100)
    changeConvertiblePerPlayer(&state.slice[alice]!, 100)
    changeConvertiblePerPlayer(&state.slice[bob]!, 100)
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
    changePlainPerPlayer(&state.perPlayerMap["k"]!, 100)
    changePlainPerPlayer(&state.slice[alice]!, 100)
    changePlainPerPlayer(&state.slice[bob]!, 100)
}

@Suite("Nested state node policies apply in every container (#175, #179)")
struct NestedNodePolicyTests {
    @Test("A @SnapshotConvertible node keeps its own policies in every container")
    func convertibleNode() throws {
        try SyncPolicyNesting.validate(ConvertibleProbeRoot.self)
        var root = ConvertibleProbeRoot()
        let found = try allViolations(&root, change: changeConvertibleRoot)
        #expect(found.isEmpty, "\(found.count) violations:\n\(found.joined(separator: "\n"))")
    }

    @Test("A node without @SnapshotConvertible keeps its own policies in every container")
    func plainNode() throws {
        try SyncPolicyNesting.validate(PlainProbeRoot.self)
        var root = PlainProbeRoot()
        let found = try allViolations(&root, change: changePlainRoot)
        #expect(found.isEmpty, "\(found.count) violations:\n\(found.joined(separator: "\n"))")
    }

    /// #179: a masked field under a broadcast parent is the same for everyone, so it is in the
    /// view without a player, and survives an array element's replacement.
    @Test("A masked field under a broadcast parent is sent masked, in snapshots and diffs")
    func maskedUnderBroadcast() throws {
        var root = PlainProbeRoot()
        let broadcast = try root.broadcastSnapshot(dirtyFields: nil)
        #expect(broadcast.values["array"] == .array([.object(["shown": .int(7), "masked": .int(-10)])]))
        #expect(broadcast.values["single"] == .object(["shown": .int(7), "masked": .int(-10)]))
        let forSync = try root.snapshotForSync(playerIDs: [alice], dirtyFields: nil)
        #expect(forSync.broadcast.values["single"] == .object(["shown": .int(7), "masked": .int(-10)]))
        #expect(forSync.broadcast.values["optional"] == .object(["shown": .int(7), "masked": .int(-10)]))

        // The diff after the change carries the new masked values.
        var engine = SyncEngine(for: PlainProbeRoot.self)
        _ = try engine.generateDiff(for: bob, from: root, useDirtyTracking: true)
        root.clearDirty()
        changePlainRoot(&root)
        let diff = patches(of: try engine.generateDiff(for: bob, from: root, useDirtyTracking: true))
        let maskedValues = diff.compactMap { patch -> SnapshotValue? in
            guard case .set(let value) = patch.operation else { return nil }
            return patch.path.hasSuffix("/masked") ? value : nil
        }
        #expect(maskedValues.contains(.int(-110)), "\(diff.map(\.path))")
    }
}

// MARK: - Array element replacement

/// Arrays whose elements are replaced whole: a broadcast one of player-independent nodes, and a
/// per-player one of nodes with a per-player field.
@StateNodeBuilder
struct ArrayReplacementRoot: StateNodeProtocol {
    @Sync(.broadcast) var shared: [PlainProbeNode] = [PlainProbeNode()]
    @Sync(.perPlayer({ (value: [PlainPerPlayerProbeNode], _: PlayerID) in value }))
    var own: [PlainPerPlayerProbeNode] = [PlainPerPlayerProbeNode()]
    init() {}
}

@Suite("An array element replaced whole keeps its nested policies (#179)")
struct ArrayElementReplacementTests {
    /// A child sees what its parent's filter left, then applies its own policy: the replacement
    /// value of a broadcast array keeps the masked field (masked), and a per-player array's keeps
    /// the per-player and masked fields for the player they're for.
    @Test("The replacement value carries the masked field under a broadcast array, and the per-player one under a per-player array")
    func replacedElement() throws {
        try SyncPolicyNesting.validate(ArrayReplacementRoot.self)
        for player in [alice, bob] {
            for useDirtyTracking in [true, false] {
                var state = ArrayReplacementRoot()
                var engine = SyncEngine(for: type(of: state))
                let joined = try engine.lateJoinSnapshot(for: player, from: state)
                var view = SnapshotClientView(fields: joined.values)
                try view.apply(patches(of: try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking)))
                state.clearDirty()

                var shared = PlainProbeNode()
                shared.shown = 70; shared.secret = 80; shared.masked = 100
                state.shared[0] = shared
                var own = PlainPerPlayerProbeNode()
                own.ppShown = 70; own.secret = 80; own.aliceOnly = 90; own.masked = 100
                state.own[0] = own

                try view.apply(patches(of: try engine.generateDiff(for: player, from: state, useDirtyTracking: useDirtyTracking)))
                let label = "\(player.rawValue) dirty=\(useDirtyTracking)"
                #expect(view.fields["shared"] == .array([.object(["shown": .int(70), "masked": .int(-100)])]), "\(label)")
                let expectedOwn: [String: SnapshotValue] = player == alice
                    ? ["ppShown": .int(70), "aliceOnly": .int(90), "masked": .int(-100)]
                    : ["ppShown": .int(70), "masked": .int(-100)]
                #expect(view.fields["own"] == .array([.object(expectedOwn)]), "\(label)")
                #expect(viewDifferences(view, try state.snapshot(for: player, dirtyFields: nil)).isEmpty, "\(label)")
            }
        }
    }
}

// MARK: - The nesting rule

@StateNodeBuilder
struct NestingMapRoot: StateNodeProtocol {
    @Sync(.broadcast) var byString: [String: PlainPerPlayerProbeNode] = [:]
    init() {}
}

@StateNodeBuilder
struct NestingArrayRoot: StateNodeProtocol {
    @Sync(.broadcast) var items: [PlainPerPlayerProbeNode] = []
    init() {}
}

@StateNodeBuilder
struct NestingOptionalRoot: StateNodeProtocol {
    @Sync(.broadcast) var maybe: PlainPerPlayerProbeNode? = nil
    init() {}
}

@StateNodeBuilder
struct NestingSingleRoot: StateNodeProtocol {
    @Sync(.broadcast) var single: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
    init() {}
}

/// A per-player node two levels down, through a map of arrays and a holder node.
@StateNodeBuilder
struct NestingDeepHolder: StateNodeProtocol {
    @Sync(.broadcast) var nodes: [Int: [PlainPerPlayerProbeNode]] = [:]
    init() {}
}

@StateNodeBuilder
struct NestingDeepRoot: StateNodeProtocol {
    @Sync(.broadcast) var holders: [PlayerID: NestingDeepHolder?] = [:]
    init() {}
}

@StateNodeBuilder
struct NestingSliceAndCustomNode: StateNodeProtocol {
    @Sync(.perPlayerSlice()) var hands: [PlayerID: Int] = [:]
    @available(*, deprecated)
    @Sync(.custom({ (_: PlayerID, value: Int) in value })) var legacy: Int = 0
    init() {}
}

@StateNodeBuilder
struct NestingSliceAndCustomRoot: StateNodeProtocol {
    @Sync(.broadcast) var node: NestingSliceAndCustomNode = NestingSliceAndCustomNode()
    init() {}
}

/// A masked node under a broadcast parent: its per-player child still has a broadcast ancestor.
@StateNodeBuilder
struct NestingMaskedHolder: StateNodeProtocol {
    @Sync(.masked({ (node: PlainPerPlayerProbeNode) in node })) var masked: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
    init() {}
}

@StateNodeBuilder
struct NestingMaskedRoot: StateNodeProtocol {
    @Sync(.broadcast) var holder: NestingMaskedHolder = NestingMaskedHolder()
    init() {}
}

/// Allowed: per-player nodes under per-player and server-only parents, and under a top-level
/// masked field.
@StateNodeBuilder
struct NestingAllowedRoot: StateNodeProtocol {
    @Sync(.perPlayerSlice()) var slice: [PlayerID: PlainPerPlayerProbeNode] = [:]
    @Sync(.perPlayer({ (value: [String: PlainPerPlayerProbeNode], _: PlayerID) in value }))
    var perPlayer: [String: PlainPerPlayerProbeNode] = [:]
    @Sync(.serverOnly) var hidden: [String: PlainPerPlayerProbeNode] = [:]
    @Sync(.masked({ (node: PlainPerPlayerProbeNode) in node })) var masked: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
    @Sync(.broadcast) var shared: [String: PlainProbeNode] = [:]
    init() {}
}

/// A recursive node: its own per-player field is fine at the top, not below its broadcast children.
@StateNodeBuilder
struct NestingRecursiveNode: StateNodeProtocol {
    @Sync(.perPlayer({ (value: Int, playerID: PlayerID) in playerID.rawValue == "alice" ? value : nil }))
    var secret: Int = 0
    @Sync(.broadcast) var children: [NestingRecursiveNode] = []
    init() {}
}

/// A plain struct (not a state node) holding a per-player node: the encoder walks it like a child.
struct NestingPlainBox: Sendable {
    var label: String = "box"
    var node: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
}

@StateNodeBuilder
struct NestingPlainBoxRoot: StateNodeProtocol {
    @Sync(.broadcast) var box: NestingPlainBox = NestingPlainBox()
    init() {}
}

/// The same box in an empty array: no instance for the check to look into.
@StateNodeBuilder
struct NestingHiddenBoxRoot: StateNodeProtocol {
    @Sync(.broadcast) var boxes: [NestingPlainBox] = []
    init() {}
}

/// A plain struct of player-independent values under a broadcast field is fine.
struct NestingPlainStats: Sendable {
    var hp: Int = 1
    var node: PlainProbeNode = PlainProbeNode()
}

@StateNodeBuilder
struct NestingPlainStatsRoot: StateNodeProtocol {
    @Sync(.broadcast) var stats: NestingPlainStats = NestingPlainStats()
    @Sync(.broadcast) var list: [NestingPlainStats] = []
    init() {}
}

/// A plain struct that reaches per-player nodes through containers: the encoder gets to each
/// node through `SnapshotValue.make`'s node branch.
struct NestingNodeListBox: Sendable {
    var nodes: [PlainPerPlayerProbeNode] = []
    var byKey: [String: PlainPerPlayerProbeNode] = [:]
    var maybe: PlainPerPlayerProbeNode? = nil
}

@StateNodeBuilder
struct NestingNodeListBoxRoot: StateNodeProtocol {
    @Sync(.broadcast) var box: NestingNodeListBox = NestingNodeListBox()
    init() {}
}

/// A class whose default instance points at itself.
final class NestingCyclicObject: @unchecked Sendable {
    var label = "loop"
    var next: NestingCyclicObject?

    static func selfLoop() -> NestingCyclicObject {
        let object = NestingCyclicObject()
        object.next = object
        return object
    }
}

@StateNodeBuilder
struct NestingCyclicRoot: StateNodeProtocol {
    @Sync(.broadcast) var object: NestingCyclicObject = NestingCyclicObject.selfLoop()
    init() {}
}

/// Policies the macro can't read (not written as `.name` or `.name(...)`) are `.unknown`.
let nestingUnknownIntPolicy: SyncPolicy<Int> = .broadcast
let nestingUnknownNodePolicy: SyncPolicy<PlainPerPlayerProbeNode> = .broadcast

@StateNodeBuilder
struct NestingUnknownNode: StateNodeProtocol {
    @Sync(nestingUnknownIntPolicy) var value: Int = 0
    init() {}
}

@StateNodeBuilder
struct NestingUnknownRoot: StateNodeProtocol {
    @Sync(.broadcast) var node: NestingUnknownNode = NestingUnknownNode()
    @Sync(nestingUnknownNodePolicy) var holder: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
    init() {}
}

private func nestingViolations(_ type: any StateNodeProtocol.Type) -> [SyncPolicyNestingError.Violation]? {
    do {
        try SyncPolicyNesting.validate(type)
        return nil
    } catch let error as SyncPolicyNestingError {
        return error.violations
    } catch {
        return []
    }
}

@Suite("A per-player field under a broadcast parent is rejected (#179)")
struct SyncPolicyNestingTests {
    @Test("Each container kind is looked through", arguments: [
        (NestingMapRoot.self as any StateNodeProtocol.Type, "NestingMapRoot.byString[*].aliceOnly", "NestingMapRoot.byString"),
        (NestingArrayRoot.self, "NestingArrayRoot.items[*].aliceOnly", "NestingArrayRoot.items"),
        (NestingOptionalRoot.self, "NestingOptionalRoot.maybe.aliceOnly", "NestingOptionalRoot.maybe"),
        (NestingSingleRoot.self, "NestingSingleRoot.single.aliceOnly", "NestingSingleRoot.single"),
        (NestingDeepRoot.self, "NestingDeepRoot.holders[*].nodes[*][*].aliceOnly", "NestingDeepRoot.holders"),
        (NestingMaskedRoot.self, "NestingMaskedRoot.holder.masked.aliceOnly", "NestingMaskedRoot.holder"),
    ])
    func rejected(type: any StateNodeProtocol.Type, path: String, ancestor: String) {
        let found = nestingViolations(type)
        #expect(found == [.init(path: path, policy: .perPlayer, broadcastAncestor: ancestor)])
    }

    @Test("A recursive type is walked again below a broadcast field of its own type")
    func recursive() {
        #expect(nestingViolations(NestingRecursiveNode.self) == [
            .init(path: "NestingRecursiveNode.children[*].secret", policy: .perPlayer, broadcastAncestor: "NestingRecursiveNode.children"),
        ])
    }

    @Test("A plain struct under a broadcast field is looked into, as the encoder walks it")
    func plainStruct() {
        #expect(nestingViolations(NestingPlainBoxRoot.self) == [
            .init(path: "NestingPlainBoxRoot.box.node.aliceOnly", policy: .perPlayer, broadcastAncestor: "NestingPlainBoxRoot.box"),
        ])
        #expect(nestingViolations(NestingPlainStatsRoot.self) == nil)
    }

    @Test("A plain struct the check can't see (in an empty array) is refused by the broadcast encoding")
    func hiddenPlainStruct() throws {
        // Nothing to look into at validation time.
        #expect(nestingViolations(NestingHiddenBoxRoot.self) == nil)
        var root = NestingHiddenBoxRoot()
        _ = try root.snapshot(for: nil, dirtyFields: nil)
        root.boxes = [NestingPlainBox()]
        #expect(throws: SyncError.self) {
            _ = try root.snapshot(for: nil, dirtyFields: nil)
        }
        // A player's view is still encoded, and player-independent holders are too.
        _ = try root.snapshot(for: alice, dirtyFields: nil)
        var stats = NestingPlainStatsRoot()
        stats.list = [NestingPlainStats()]
        _ = try stats.snapshot(for: nil, dirtyFields: nil)
    }

    @Test("A per-player node reached through a plain value's array, dictionary or optional is refused when encoded without a player")
    func nodeInPlainContainers() throws {
        // Validation sees the element types; the encoder is the backstop for a land built
        // without it (a LandKeeper or LandManager constructed directly).
        #expect(nestingViolations(NestingNodeListBoxRoot.self)?.isEmpty == false)
        _ = try NestingNodeListBoxRoot().snapshot(for: nil, dirtyFields: nil)
        let fills: [(String, (inout NestingNodeListBox) -> Void)] = [
            ("array", { $0.nodes = [PlainPerPlayerProbeNode()] }),
            ("dictionary", { $0.byKey = ["k": PlainPerPlayerProbeNode()] }),
            ("optional", { $0.maybe = PlainPerPlayerProbeNode() }),
        ]
        for (name, fill) in fills {
            var root = NestingNodeListBoxRoot()
            fill(&root.box)
            #expect(throws: SyncError.self, "\(name): broadcastSnapshot") {
                _ = try root.broadcastSnapshot(dirtyFields: nil)
            }
            #expect(throws: SyncError.self, "\(name): snapshotForSync") {
                _ = try root.snapshotForSync(playerIDs: [alice], dirtyFields: nil)
            }
            _ = try root.snapshot(for: alice, dirtyFields: nil)
        }
    }

    @Test("A per-player node directly under a broadcast field is refused by the one-pass sync extraction")
    func directNodeInSnapshotForSync() {
        #expect(throws: SyncError.self) {
            _ = try NestingSingleRoot().snapshotForSync(playerIDs: [alice], dirtyFields: nil)
        }
    }

    @Test("The player-dependence flag is stored per type")
    func playerDependenceFlag() {
        #expect(PlainPerPlayerProbeNode.hasPlayerDependentSyncFields)
        #expect(NestingSingleRoot.hasPlayerDependentSyncFields)
        #expect(!PlainProbeNode.hasPlayerDependentSyncFields)
        #expect(!NestingPlainStatsRoot.hasPlayerDependentSyncFields)
    }

    @Test("A self-referencing class in a default instance ends the check, and the encoder refuses it")
    func cyclicClass() {
        #expect(nestingViolations(NestingCyclicRoot.self) == nil)
        #expect(throws: SyncError.self) {
            _ = try NestingCyclicRoot().snapshot(for: nil, dirtyFields: nil)
        }
        #expect(throws: SyncError.self) {
            _ = try NestingCyclicRoot().fullStateSnapshot()
        }
        // A chain of objects without a cycle is still encoded.
        var root = NestingCyclicRoot()
        let shared = NestingCyclicObject()
        let head = NestingCyclicObject()
        head.next = shared
        root.object = head
        #expect((try? root.snapshot(for: nil, dirtyFields: nil)) != nil)
    }

    @Test("An unrecognized policy fails closed: rejected under a broadcast field, and checked as one")
    func unknownPolicy() {
        #expect(nestingViolations(NestingUnknownRoot.self) == [
            .init(path: "NestingUnknownRoot.node.value", policy: .unknown, broadcastAncestor: "NestingUnknownRoot.node"),
            .init(path: "NestingUnknownRoot.holder.aliceOnly", policy: .perPlayer, broadcastAncestor: "NestingUnknownRoot.holder"),
        ])
    }

    @Test("Schema extraction rejects the land at every entry point")
    func schemaEntryPoints() {
        let land = Land("nesting-array", using: NestingArrayRoot.self) { Rules {} }
        #expect(throws: SyncPolicyNestingError.self) {
            _ = try SchemaExtractor.extract(from: land)
        }
        #expect(throws: SyncPolicyNestingError.self) {
            _ = try SchemaGenCLI.generateSchema(landDefinitions: [AnyLandDefinition(land)])
        }
    }

    @Test("perPlayerSlice and the deprecated custom are rejected too")
    func sliceAndCustom() {
        let found = nestingViolations(NestingSliceAndCustomRoot.self)
        #expect(found == [
            .init(path: "NestingSliceAndCustomRoot.node.hands", policy: .perPlayerSlice, broadcastAncestor: "NestingSliceAndCustomRoot.node"),
            .init(path: "NestingSliceAndCustomRoot.node.legacy", policy: .custom, broadcastAncestor: "NestingSliceAndCustomRoot.node"),
        ])
    }

    @Test("Per-player parents, server-only and masked fields, and player-independent broadcast children are allowed")
    func allowed() {
        #expect(nestingViolations(NestingAllowedRoot.self) == nil)
    }

    @Test("The error names the field, its policy and the broadcast ancestor, and suggests the supported shape")
    func errorMessage() {
        do {
            try SyncPolicyNesting.validate(NestingArrayRoot.self)
            Issue.record("expected a rejection")
        } catch {
            let text = "\(error)"
            #expect(text.contains("NestingArrayRoot.items[*].aliceOnly is .perPlayer under the .broadcast field NestingArrayRoot.items"))
            #expect(text.contains("var hands: [PlayerID: Hand]"))
        }
    }

    @Test("SchemaGen rejects the land")
    func schemaGen() {
        let land = Land("nesting-array", using: NestingArrayRoot.self) { Rules {} }
        #expect(throws: SyncPolicyNestingError.self) {
            try SchemaGenCLI.generate(landDefinitions: [AnyLandDefinition(land)], outputPath: "/dev/null")
        }
    }

    /// The order of a masked node field: the mask runs on the server value first, then the
    /// node's own policies, for the player the snapshot is for.
    @Test("A masked node: the mask first, then the children's policies")
    func maskedNodeOrder() throws {
        @StateNodeBuilder
        struct MaskedNodeRoot: StateNodeProtocol {
            @Sync(.masked({ (node: PlainPerPlayerProbeNode) in
                var masked = node
                masked.ppShown = 0
                masked.aliceOnly = 1
                return masked
            }))
            var node: PlainPerPlayerProbeNode = PlainPerPlayerProbeNode()
            init() {}
        }
        try SyncPolicyNesting.validate(MaskedNodeRoot.self)
        let root = MaskedNodeRoot()
        let forAlice = try root.snapshot(for: alice, dirtyFields: nil).values["node"]
        let forBob = try root.snapshot(for: bob, dirtyFields: nil).values["node"]
        #expect(forAlice == .object(["ppShown": .int(0), "aliceOnly": .int(1), "masked": .int(-10)]))
        #expect(forBob == .object(["ppShown": .int(0), "masked": .int(-10)]))
    }
}
