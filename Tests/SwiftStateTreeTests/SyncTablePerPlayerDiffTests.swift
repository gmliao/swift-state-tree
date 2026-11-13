// Tests/SwiftStateTreeTests/SyncTablePerPlayerDiffTests.swift
//
// The typed per-player diff (`SyncTablePerPlayerDiff`, #514) against today's per-player snapshot
// diff (`SyncEngine.generatePerPlayerUpdateFromSnapshot`): per player, the same patches in
// canonical order, the same drops and the same last-sent, over random mutation sequences with
// players joining and leaving, failed plans and key resets.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - States

/// A visible entity: a node with a broadcast and a server-only field.
@StateNodeBuilder
struct PPEntity: StateNodeProtocol {
    @Sync(.broadcast) var x: Int = 0
    @Sync(.broadcast) var label: String = ""
    @Sync(.serverOnly) var step: Int = 0
    init() {}
}

/// A value whose conversion throws for a negative `n`.
struct PPThrowing: Equatable, Sendable, SnapshotValueConvertible {
    var n: Int = 0
    func toSnapshotValue() throws -> SnapshotValue {
        if n < 0 { throw SyncError.unsupportedValue("negative n \(n)") }
        return .object(["n": .int(n)])
    }
}

/// A value that isn't `Equatable` (the typed tables' snapshot fallback).
struct PPNonEquatable: Sendable {
    var n: Int = 0
}

/// A node with player-dependent fields of its own: under a per-player root it is converted for
/// the player (M2).
@StateNodeBuilder
struct PPHolder: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.perPlayer({ (v: Int, player: PlayerID) in player.rawValue == "p0" ? v : nil })) var onlyP0: Int = 0
    @Sync(.custom({ (player: PlayerID, v: Int) in player.rawValue == "p1" ? v : nil })) var onlyP1: Int = 0
    @Sync(.serverOnly) var hidden: Int = 0
    init() {}
}

/// A policy the macro can't read: classified `.unknown`, so treated as player-dependent.
let ppUnknownPolicy: SyncPolicy<Int> = .masked { $0 * 2 }

/// The entity is within a player's radius: player `pN` sees x in N-2...N+2. Pure in the value
/// and the player, as the per-player diff requires (#199).
private func ppVisible(_ entity: PPEntity, to player: PlayerID) -> Bool {
    guard let n = Int(player.rawValue.dropFirst()) else { return false }
    return abs(entity.x - n) <= 2
}

@StateNodeBuilder
struct PPRoot: StateNodeProtocol {
    /// The visibility land's shape: a node map filtered by radius.
    @Sync(.perPlayer({ (v: [String: PPEntity], player: PlayerID) in v.filter { ppVisible($0.value, to: player) } }))
    var entities: [String: PPEntity] = [:]
    /// A player's entry, removed and added again: the whole field leaves and returns (M1).
    @Sync(.perPlayerSlice()) var hands: [PlayerID: [String]] = [:]
    /// A masked root map.
    @Sync(.masked({ (v: [String: Int]) in v.filter { $0.value > 0 } })) var positive: [String: Int] = [:]
    /// An optional node output: nil and a value, and hidden for p3.
    @Sync(.perPlayer({ (v: PPEntity?, player: PlayerID) -> PPEntity?? in player.rawValue == "p3" ? .none : .some(v) }))
    var maybe: PPEntity? = nil
    /// NaN and -0.0.
    @Sync(.perPlayer({ (v: Double, _: PlayerID) in v })) var ratio: Double = 0
    /// Throws for p1 only, while `n` is negative.
    @Sync(.perPlayer({ (v: PPThrowing, player: PlayerID) in player.rawValue == "p1" ? v : PPThrowing(n: abs(v.n)) }))
    var risky: PPThrowing = PPThrowing()
    @Sync(.perPlayer({ (v: PPHolder, _: PlayerID) in v })) var holder: PPHolder = PPHolder()
    @Sync(ppUnknownPolicy) var doubled: Int = 0
    /// NFC and NFD forms of one key.
    @Sync(.perPlayer({ (v: [String: Int], _: PlayerID) in v })) var keyed: [String: Int] = [:]
    /// The snapshot fallback's presence: hidden from p2 while `n` is 2.
    @Sync(.perPlayer({ (v: PPNonEquatable, player: PlayerID) -> PPNonEquatable? in player.rawValue == "p2" && v.n == 2 ? nil : v }))
    var opaque: PPNonEquatable = PPNonEquatable()
    @Sync(.broadcast) var tick: Int = 0
    @Sync(.serverOnly) var secret: Int = 0
    init() {}
}

/// A node whose first leaf converts and whose second can throw, in declaration and path order.
@StateNodeBuilder
struct PPPairNode: StateNodeProtocol {
    @Sync(.broadcast) var a: Int = 0
    @Sync(.broadcast) var b: PPThrowing = PPThrowing()
    init() {}
}

@StateNodeBuilder
struct PPPairRoot: StateNodeProtocol {
    @Sync(.perPlayer({ (v: PPPairNode, _: PlayerID) in v })) var pair: PPPairNode = PPPairNode()
    init() {}
}

/// Two roots that can throw, and one that can't.
@StateNodeBuilder
struct PPTwoRoots: StateNodeProtocol {
    @Sync(.perPlayer({ (v: PPThrowing, _: PlayerID) in v })) var first: PPThrowing = PPThrowing()
    @Sync(.perPlayer({ (v: PPThrowing, _: PlayerID) in v })) var second: PPThrowing = PPThrowing()
    @Sync(.perPlayer({ (v: Int, _: PlayerID) in v })) var fine: Int = 0
    init() {}
}

/// A map whose entries can throw.
@StateNodeBuilder
struct PPLeafRoot: StateNodeProtocol {
    @Sync(.perPlayer({ (v: [String: PPThrowing], _: PlayerID) in v })) var byKey: [String: PPThrowing] = [:]
    init() {}
}

private func ppTouch(_ entities: inout [String: PPEntity]) {
    entities["touched"] = PPEntity()
}

// MARK: - Mutations

private let ppDoubles: [Double] = [0, -0.0, .nan, 1.5, -2.25]
private let ppKeys = ["a", "b", "\u{E9}", "e\u{301}", "x/y", "t~1"]
private let ppPlayers = ["p0", "p1", "p2", "p3"].map { PlayerID($0) }

private func ppMutate(_ state: inout PPRoot, _ g: inout PPGenerator, allowsThrows: Bool) {
    switch Int.random(in: 0...13, using: &g) {
    case 0, 1:
        let key = "e\(Int.random(in: 0...5, using: &g))"
        if state.entities[key] != nil, Bool.random(using: &g) {
            state.entities[key]!.x += [-1, 1].randomElement(using: &g)!
        } else if Bool.random(using: &g) {
            var entity = PPEntity()
            entity.x = Int.random(in: -1...5, using: &g)
            state.entities[key] = entity
        } else {
            state.entities.removeValue(forKey: key)
        }
    case 2:
        if let key = state.entities.keys.sorted().randomElement(using: &g) {
            if Bool.random(using: &g) { state.entities[key]!.label = ["", "l", "m"].randomElement(using: &g)! } else { state.entities[key]!.step += 1 }
        }
    case 3:
        let player = ppPlayers.randomElement(using: &g)!
        switch Int.random(in: 0...2, using: &g) {
        case 0: state.hands.removeValue(forKey: player)
        case 1: state.hands[player] = []
        default: state.hands[player, default: []].append(["c", "d"].randomElement(using: &g)!)
        }
    case 4: state.positive[ppKeys.randomElement(using: &g)!] = Int.random(in: -1...2, using: &g)
    case 5:
        switch Int.random(in: 0...2, using: &g) {
        case 0: state.maybe = nil
        case 1: state.maybe = PPEntity()
        default: state.maybe?.x += 1
        }
    case 6: state.ratio = ppDoubles.randomElement(using: &g)!
    case 7: state.risky.n = Int.random(in: allowsThrows ? -1...2 : 0...2, using: &g)
    case 8:
        switch Int.random(in: 0...3, using: &g) {
        case 0: state.holder.a += 1
        case 1: state.holder.onlyP0 += 1
        case 2: state.holder.onlyP1 += 1
        default: state.holder.hidden += 1
        }
    case 9: state.doubled = Int.random(in: 0...2, using: &g)
    case 10: state.keyed[ppKeys.randomElement(using: &g)!] = Bool.random(using: &g) ? Int.random(in: 0...2, using: &g) : nil
    case 11: state.opaque.n = Int.random(in: 0...2, using: &g)
    case 12: state.tick += 1
    default: state.secret += 1
    }
}

// MARK: - Harness

/// Today's per-player diff and the typed one, side by side on one state.
private struct PerPlayerPair<State: StateNodeProtocol> {
    var engine = SyncEngine(for: State.self)
    let typed = SyncTablePerPlayerDiff<State>()
    let order = CanonicalPatchOrder.forState(State.self)
    let perPlayerNames: Set<String>

    init() {
        perPlayerNames = Set(typed.fieldNames)
    }

    struct Step {
        var today: [PlayerID: [StatePatch]] = [:]
        var typed: [PlayerID: [StatePatch]] = [:]
        var todayDrops = ExtractionDrops()
        var typedDrops = ExtractionDrops()
    }

    /// One plan for `players` on both sides; `commit` false discards both, as a failed sync does.
    /// `onePass`: today's one-pass extraction (every per-player field), which falls back to the
    /// separate extraction for every player when any conversion throws (T1), and the typed seed
    /// of every field; otherwise the separate extraction of `mode`'s fields.
    /// `resetsKeys`: the adapter's key reset, which keeps the cycle's mode and the `.cached`
    /// baseline and only retypes the update `.firstSync`, so the patches are the cycle's.
    mutating func step(
        _ state: State,
        players: [PlayerID],
        fields: Set<String>?,
        onePass: Bool,
        resetsKeys: Bool,
        commit: Bool
    ) throws -> Step {
        let mode: SnapshotMode = fields.map { .dirtyTracking($0) } ?? .all
        let baseline: SyncEngine.DiffBaseline = .cached
        var result = Step()
        var staged = SyncEngine.StagedCaches()
        let extracted = onePass ? try? state.snapshotForSync(playerIDs: players, dirtyFields: mode.fields).perPlayer : nil
        for player in players {
            let snapshot = extracted?[player]
                ?? engine.extractPerPlayerSnapshot(for: player, from: state, mode: mode, drops: &result.todayDrops)
            let update = engine.generatePerPlayerUpdateFromSnapshot(
                for: player, perPlayerSnapshot: snapshot, perPlayerMode: mode, baseline: baseline, staged: &staged
            )
            switch update {
            case .diff(let patches), .firstSync(let patches): result.today[player] = order.sorted(patches)
            case .noChange: result.today[player] = []
            }
        }
        var typedStaged = SyncTablePerPlayerStaged()
        for player in players {
            result.typed[player] = typed.planDiff(
                state, for: player, fields: mode.fields, seedsAll: onePass,
                drops: &result.typedDrops, into: &typedStaged
            )
        }
        if commit {
            engine.applyStaged(staged)
            typed.apply(typedStaged)
        }
        return result
    }

    mutating func leave(_ player: PlayerID) {
        engine.clearCacheForDisconnectedPlayer(player)
        typed.clear(player)
    }

    /// Last-sent per player: the committed boxes against today's cache, values compared as the
    /// diff compares them.
    func lastSentDiffers(_ player: PlayerID) -> String? {
        let boxes = typed.lastSentSnapshot(for: player)
        let cache = engine.cachedPerPlayerSnapshotForTesting(player)
        switch (boxes, cache) {
        case (nil, nil): return nil
        case (let b?, let c?):
            let bv = b.values.filter { perPlayerNames.contains($0.key) }
            let cv = c.values.filter { perPlayerNames.contains($0.key) }
            guard Set(bv.keys) == Set(cv.keys) else { return "fields \(bv.keys.sorted()) against \(cv.keys.sorted())" }
            // As the diff compares (-0.0 equals 0.0): a sign change sends nothing, and today's
            // cache takes the new sign while a box keeps its client's, which no later diff can
            // tell apart. The patches, the wire, are compared by bit pattern.
            for (key, value) in bv where !SnapshotValue.sameValue(value, cv[key]!) {
                return "\(key): \(value) against \(cv[key]!)"
            }
            return nil
        default:
            return "boxes \(boxes == nil ? "missing" : "present"), cache \(cache == nil ? "missing" : "present")"
        }
    }
}

/// Values equal as the wire sees them: doubles by bit pattern (-0.0 isn't 0.0), NaN equal to NaN.
private func ppSameValue(_ lhs: SnapshotValue, _ rhs: SnapshotValue) -> Bool {
    switch (lhs, rhs) {
    case (.double(let x), .double(let y)):
        return (x.isNaN && y.isNaN) || x.bitPattern == y.bitPattern
    case (.array(let x), .array(let y)):
        return x.count == y.count && zip(x, y).allSatisfy { ppSameValue($0, $1) }
    case (.object(let x), .object(let y)):
        return x.count == y.count && x.allSatisfy { key, value in y[key].map { ppSameValue(value, $0) } ?? false }
    default:
        return SnapshotValue.sameValue(lhs, rhs)
    }
}

/// Patch lists equal, values compared by `ppSameValue`, paths by bytes.
private func ppSamePatches(_ lhs: [StatePatch], _ rhs: [StatePatch]) -> Bool {
    guard lhs.count == rhs.count else { return false }
    for (a, b) in zip(lhs, rhs) {
        guard a.path.utf8.elementsEqual(b.path.utf8) else { return false }
        switch (a.operation, b.operation) {
        case (.set(let x), .set(let y)):
            guard ppSameValue(x, y) else { return false }
        default:
            guard a.operation == b.operation else { return false }
        }
    }
    return true
}

private func ppDescribe(_ patches: [StatePatch]?) -> String {
    (patches ?? []).map { "\($0.path) \($0.operation)" }.joined(separator: "\n")
}

/// SplitMix64, so a failure reproduces from its printed seed.
private struct PPGenerator: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// The steps per differential run: 10 000 by default; `SYNC_TABLE_STEPS` sets a long run and
/// `SYNC_TABLE_SEED` replays a printed seed.
private let ppSteps: Int = {
    guard let text = ProcessInfo.processInfo.environment["SYNC_TABLE_STEPS"] else { return 10_000 }
    guard let steps = Int(text), steps > 0 else { preconditionFailure("SYNC_TABLE_STEPS must be a positive integer, got \(text)") }
    return steps
}()

/// Random steps on both diffs: players join and leave, one plan in ten fails (nothing commits,
/// the dirty fields are carried), one in twenty resets the key scopes. Every step's patches,
/// drops and last-sent must be equal per player.
///
/// It yields every 64 steps so its cases don't hold every cooperative pool thread
/// (`Notes/solutions/2026-11-11-cpu-bound-tests-starve-the-cooperative-pool.md`).
private func runPerPlayerDifferential(
    allFields: Bool,
    onePass: Bool,
    allowsThrows: Bool,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    let seed = ProcessInfo.processInfo.environment["SYNC_TABLE_SEED"].flatMap { UInt64($0) } ?? UInt64.random(in: 0...UInt64.max)
    var g = PPGenerator(state: seed)
    var state = PPRoot()
    var pair = PerPlayerPair<PPRoot>()
    var players: [PlayerID] = [ppPlayers[0], ppPlayers[1]]
    var carried: Set<String> = []
    for index in 0..<ppSteps {
        if index % 64 == 0 { await Task.yield() }
        // Players join and leave between plans.
        if Int.random(in: 0..<16, using: &g) == 0 {
            let player = ppPlayers.randomElement(using: &g)!
            if let at = players.firstIndex(of: player) {
                players.remove(at: at)
                pair.leave(player)
            } else {
                players.append(player)
            }
        }
        for _ in 0..<Int.random(in: 1...4, using: &g) { ppMutate(&state, &g, allowsThrows: allowsThrows) }
        let dirty = state.getDirtyFields().union(carried)
        state.clearDirty()
        let commit = Int.random(in: 0..<10, using: &g) != 0
        let resetsKeys = Int.random(in: 0..<20, using: &g) == 0
        // As the adapter plans it: no dirty field diffs every field (`.all`).
        let result: PerPlayerPair<PPRoot>.Step
        do {
            result = try pair.step(
                state, players: players, fields: allFields || dirty.isEmpty ? nil : dirty,
                onePass: onePass, resetsKeys: resetsKeys, commit: commit
            )
        } catch {
            Issue.record("seed \(seed), step \(index): \(error)", sourceLocation: sourceLocation)
            return
        }
        carried = commit ? [] : dirty
        for player in players {
            let lastSent = commit ? pair.lastSentDiffers(player) : nil
            guard ppSamePatches(result.today[player] ?? [], result.typed[player] ?? []),
                  result.todayDrops.perPlayerFields[player] == result.typedDrops.perPlayerFields[player],
                  lastSent == nil
            else {
                Issue.record("""
                seed \(seed), step \(index), \(player)\(resetsKeys ? " (key reset)" : ""): the typed per-player diff differs from today's
                today (drops \(result.todayDrops.perPlayerFields[player]?.sorted() ?? [])):
                \(ppDescribe(result.today[player]))
                typed (drops \(result.typedDrops.perPlayerFields[player]?.sorted() ?? [])):
                \(ppDescribe(result.typed[player]))
                last-sent: \(lastSent ?? "equal")
                """, sourceLocation: sourceLocation)
                return
            }
        }
        #expect(result.todayDrops.count == result.typedDrops.count, "seed \(seed), step \(index): drop count", sourceLocation: sourceLocation)
        // No cursor: a per-player patch never carries a split, so never a row tag (plan §7).
        #expect(result.typed.values.allSatisfy { $0.allSatisfy { $0.split == nil } }, "seed \(seed), step \(index): a split", sourceLocation: sourceLocation)
    }
}

// MARK: - Tests

@Suite("Typed per-player sync diff (#514)")
struct SyncTablePerPlayerDiffTests {
    @Test("The per-player fields are today's, in path order")
    func fieldNames() {
        let diff = SyncTablePerPlayerDiff<PPRoot>()
        #expect(diff.fieldNames == ["doubled", "entities", "hands", "holder", "keyed", "maybe", "opaque", "positive", "ratio", "risky"])
        #expect(PPRoot._syncTablePerPlayerFields(for: PlayerID("p0"))?.map(\.name).sorted() == diff.fieldNames)
        // Typed slots, so the saving is real: a nil `_syncTablePerPlayerFields` would put every
        // field on `.fallback`. A root holding nested player-dependent fields takes the fallback
        // (M2), as does a non-Equatable one.
        #expect(diff.kinds == [
            "doubled": .value, "entities": .nodeMap, "hands": .value, "holder": .fallback, "keyed": .value,
            "maybe": .optionalNode, "opaque": .fallback, "positive": .value, "ratio": .value, "risky": .value,
        ])
    }

    @Test(
        "Random mutations: the typed per-player diff equals today's separate extraction, throws included",
        .serialized, arguments: [false, true]
    )
    func differentialSeparate(allFields: Bool) async throws {
        try await runPerPlayerDifferential(allFields: allFields, onePass: false, allowsThrows: true)
    }

    /// The one-pass extraction falls back as a whole when any conversion throws (M8), which the
    /// typed diff doesn't copy (T1): this run has no throwing value.
    @Test("Random mutations: the typed per-player diff equals today's one-pass extraction", .serialized, arguments: [false, true])
    func differentialOnePass(allFields: Bool) async throws {
        try await runPerPlayerDifferential(allFields: allFields, onePass: true, allowsThrows: false)
    }

    @Test("A field leaves a player's view and comes back: a delete of the root, then a set of the whole field (M1)")
    func leavesAndReturns() throws {
        var state = PPRoot()
        let p0 = PlayerID("p0")
        state.hands[p0] = ["c"]
        var pair = PerPlayerPair<PPRoot>()
        _ = try pair.step(state, players: [p0], fields: nil, onePass: false, resetsKeys: false, commit: true)
        state.hands.removeValue(forKey: p0)
        let gone = try pair.step(state, players: [p0], fields: ["hands"], onePass: false, resetsKeys: false, commit: true)
        #expect(ppSamePatches(gone.today[p0]!, gone.typed[p0]!), "\(ppDescribe(gone.today[p0]))\n--\n\(ppDescribe(gone.typed[p0]))")
        #expect(gone.typed[p0]!.map(\.path) == ["/hands"])
        #expect(pair.lastSentDiffers(p0) == nil)
        state.hands[p0] = ["d"]
        let back = try pair.step(state, players: [p0], fields: ["hands"], onePass: false, resetsKeys: false, commit: true)
        #expect(ppSamePatches(back.today[p0]!, back.typed[p0]!), "\(ppDescribe(back.today[p0]))\n--\n\(ppDescribe(back.typed[p0]))")
        #expect(back.typed[p0]!.map(\.path) == ["/hands"])
    }

    @Test("A conversion that throws for one player drops that player's field only, as today (T1)")
    func throwsForOnePlayer() throws {
        var state = PPRoot()
        let p0 = PlayerID("p0"), p1 = PlayerID("p1")
        var pair = PerPlayerPair<PPRoot>()
        _ = try pair.step(state, players: [p0, p1], fields: nil, onePass: false, resetsKeys: false, commit: true)
        state.risky.n = -1
        state.ratio = 2
        let step = try pair.step(state, players: [p0, p1], fields: ["risky", "ratio"], onePass: false, resetsKeys: false, commit: true)
        #expect(step.typedDrops.perPlayerFields == [p1: ["risky"]])
        #expect(step.todayDrops.perPlayerFields == step.typedDrops.perPlayerFields)
        #expect(step.typed[p0]!.map(\.path) == ["/ratio", "/risky/n"])
        #expect(step.typed[p1]!.map(\.path) == ["/ratio"])
        for player in [p0, p1] {
            #expect(ppSamePatches(step.today[player]!, step.typed[player]!))
            #expect(pair.lastSentDiffers(player) == nil)
        }
    }

    /// An entry that throws can't enter the box, so T2 (an unchanged leaf whose conversion would
    /// throw) needs a conversion that isn't pure; with a pure one the incremental diff drops the
    /// field until the entry converts or goes, as today's extraction does. Interim until #535.
    @Test("An entry that throws drops the map for the player until it converts or goes; the other entries then flow")
    func throwingEntry() throws {
        var state = PPLeafRoot()
        let p0 = PlayerID("p0")
        state.byKey["good"] = PPThrowing(n: 1)
        var pair = PerPlayerPair<PPLeafRoot>()
        _ = try pair.step(state, players: [p0], fields: nil, onePass: false, resetsKeys: false, commit: true)
        state.byKey["bad"] = PPThrowing(n: -1)
        let added = try pair.step(state, players: [p0], fields: ["byKey"], onePass: false, resetsKeys: false, commit: true)
        #expect(added.typedDrops.perPlayerFields == [p0: ["byKey"]])
        #expect(added.todayDrops.perPlayerFields == added.typedDrops.perPlayerFields)
        #expect(added.typed[p0] == [] && added.today[p0] == [])
        state.byKey["good"] = PPThrowing(n: 2)
        let still = try pair.step(state, players: [p0], fields: ["byKey"], onePass: false, resetsKeys: false, commit: true)
        #expect(still.typedDrops.perPlayerFields == [p0: ["byKey"]] && still.typed[p0] == [])
        state.byKey.removeValue(forKey: "bad")
        let gone = try pair.step(state, players: [p0], fields: ["byKey"], onePass: false, resetsKeys: false, commit: true)
        #expect(ppSamePatches(gone.today[p0]!, gone.typed[p0]!))
        #expect(gone.typed[p0]!.map(\.path) == ["/byKey/good/n"])
        #expect(pair.lastSentDiffers(p0) == nil)
    }

    @Test("Every write route marks a per-player field dirty (D1)")
    func writeRoutesMarkDirty() {
        func dirty(_ write: (inout PPRoot) -> Void) -> Set<String> {
            var state = PPRoot()
            state.entities["k"] = PPEntity()
            state.holder = PPHolder()
            state.clearDirty()
            write(&state)
            return state.getDirtyFields()
        }
        #expect(dirty { $0.entities = [:] } == ["entities"], "the setter")
        #expect(dirty { $0.entities["k"] = PPEntity() } == ["entities"], "a map subscript write")
        #expect(dirty { $0.entities["k"]?.x = 3 } == ["entities"], "a nested write through the subscript")
        #expect(dirty { $0.holder.onlyP0 = 1 } == ["holder"], "a nested node field write")
        #expect(dirty { ppTouch(&$0.entities) } == ["entities"], "an inout write")
    }

    @Test("A nested node's per-player fields are converted for the player (M2)")
    func nestedPerPlayerFields() throws {
        var state = PPRoot()
        let p0 = PlayerID("p0"), p1 = PlayerID("p1")
        var pair = PerPlayerPair<PPRoot>()
        _ = try pair.step(state, players: [p0, p1], fields: nil, onePass: false, resetsKeys: false, commit: true)
        state.holder.onlyP0 = 4
        state.holder.onlyP1 = 5
        let step = try pair.step(state, players: [p0, p1], fields: ["holder"], onePass: false, resetsKeys: false, commit: true)
        #expect(step.typed[p0]!.map(\.path) == ["/holder/onlyP0"])
        #expect(step.typed[p1]!.map(\.path) == ["/holder/onlyP1"])
        for player in [p0, p1] { #expect(ppSamePatches(step.today[player]!, step.typed[player]!)) }
    }

    @Test("A failed plan leaves the boxes as committed: the next plan equals today's")
    func failedPlan() throws {
        var state = PPRoot()
        let p0 = PlayerID("p0")
        var pair = PerPlayerPair<PPRoot>()
        _ = try pair.step(state, players: [p0], fields: nil, onePass: false, resetsKeys: false, commit: true)
        state.keyed["a"] = 1
        _ = try pair.step(state, players: [p0], fields: ["keyed"], onePass: false, resetsKeys: false, commit: false)
        state.keyed["b"] = 2
        let next = try pair.step(state, players: [p0], fields: ["keyed"], onePass: false, resetsKeys: false, commit: true)
        #expect(ppSamePatches(next.today[p0]!, next.typed[p0]!))
        #expect(next.typed[p0]!.map(\.path) == ["/keyed/a", "/keyed/b"])
    }

    @Test("A player's first plan seeds its boxes and sends nothing; a key reset diffs against what the client has")
    func seedAndReset() throws {
        var state = PPRoot()
        let p2 = PlayerID("p2")
        state.entities["e"] = PPEntity()
        state.entities["e"]!.x = 2
        var pair = PerPlayerPair<PPRoot>()
        let seeded = try pair.step(state, players: [p2], fields: ["entities"], onePass: false, resetsKeys: false, commit: true)
        #expect(seeded.typed[p2] == [])
        #expect(pair.typed.playersForTesting == [p2])
        state.entities["e"]!.x = 3
        let reset = try pair.step(state, players: [p2], fields: ["entities"], onePass: false, resetsKeys: true, commit: true)
        #expect(ppSamePatches(reset.today[p2]!, reset.typed[p2]!), "\(ppDescribe(reset.today[p2]))\n--\n\(ppDescribe(reset.typed[p2]))")
        #expect(reset.typed[p2]!.map(\.path) == ["/entities/e/x"])
        #expect(pair.lastSentDiffers(p2) == nil)
        pair.leave(p2)
        #expect(pair.typed.playersForTesting.isEmpty)
    }

    /// The nested-policy roots (`NestedNodePolicyTests`): per-player maps of nodes with their own
    /// player-dependent fields, `@SnapshotConvertible` and plain. Scripted on both diffs, one-pass
    /// on and off, every step compared.
    @Test("The nested-policy roots: the typed per-player diff equals today's", arguments: [false, true])
    func nestedPolicyRoots(onePass: Bool) throws {
        try ppScripted(ConvertibleProbeRoot(), onePass: onePass, steps: [
            { $0.perPlayerMap["k"]!.aliceOnly = 1 },
            { $0.perPlayerMap["k2"] = ConvertiblePerPlayerProbeNode() },
            { $0.slice[PlayerID("alice")]!.ppShown = 3; $0.tick += 1 },
            { $0.slice.removeValue(forKey: PlayerID("bob")) },
            { $0.perPlayerMap["k"]!.masked = 4 },
            { $0.slice[PlayerID("bob")] = ConvertiblePerPlayerProbeNode() },
            { $0.perPlayerMap.removeValue(forKey: "k") },
        ])
        try ppScripted(PlainProbeRoot(), onePass: onePass, steps: [
            { $0.perPlayerMap["k"]!.aliceOnly = 1 },
            { $0.perPlayerMap["k2"] = PlainPerPlayerProbeNode() },
            { $0.slice[PlayerID("alice")]!.ppShown = 3; $0.tick += 1 },
            { $0.slice.removeValue(forKey: PlayerID("bob")) },
            { $0.perPlayerMap["k"]!.masked = 4 },
            { $0.slice[PlayerID("bob")] = PlainPerPlayerProbeNode() },
            { $0.perPlayerMap.removeValue(forKey: "k") },
        ])
    }

    private func ppScripted<S: StateNodeProtocol>(
        _ initial: S, onePass: Bool, steps: [(inout S) -> Void], sourceLocation: SourceLocation = #_sourceLocation
    ) throws {
        let players = [PlayerID("alice"), PlayerID("bob")]
        var state = initial
        var pair = PerPlayerPair<S>()
        _ = try pair.step(state, players: players, fields: nil, onePass: onePass, resetsKeys: false, commit: true)
        state.clearDirty()
        for (index, mutate) in steps.enumerated() {
            mutate(&state)
            let dirty = state.getDirtyFields()
            state.clearDirty()
            let result = try pair.step(state, players: players, fields: dirty.isEmpty ? nil : dirty, onePass: onePass, resetsKeys: false, commit: true)
            for player in players {
                #expect(
                    ppSamePatches(result.today[player]!, result.typed[player]!),
                    "\(S.self) step \(index), \(player):\n\(ppDescribe(result.today[player]))\n--\n\(ppDescribe(result.typed[player]))",
                    sourceLocation: sourceLocation
                )
                #expect(pair.lastSentDiffers(player) == nil, "\(S.self) step \(index), \(player): last-sent", sourceLocation: sourceLocation)
            }
        }
    }

    // MARK: One-pass (B1) failure scenarios: D5's expected outputs (interim, #535), not today's

    /// One B1 plan on the typed side alone: today's B1 falls back to B2 for every player on a
    /// throw (T1), so these outputs are pinned, not compared.
    private func typedPlan<S: StateNodeProtocol>(
        _ typed: SyncTablePerPlayerDiff<S>, _ state: S, _ players: [PlayerID], fields: Set<String>?, seedsAll: Bool = true
    ) -> (patches: [PlayerID: [StatePatch]], drops: ExtractionDrops) {
        var staged = SyncTablePerPlayerStaged()
        var drops = ExtractionDrops()
        var patches: [PlayerID: [StatePatch]] = [:]
        for player in players {
            patches[player] = typed.planDiff(state, for: player, fields: fields, seedsAll: seedsAll, drops: &drops, into: &staged)
        }
        typed.apply(staged)
        return (patches, drops)
    }

    /// T1's cross-player case: p1 (with boxes) throws in S while p0 has no boxes yet. p0 is
    /// seeded with every per-player field, as B1 seeds it without the throw. It kills the global
    /// B2 fallback (seeding p0 with S once any throw counted). At the adapter that fallback can't
    /// be told apart: every recipient there has boxes (its firstSync commits them).
    @Test("One-pass: a player without boxes gets B1's seed while another player throws (T1)")
    func onePassCrossPlayerThrow() throws {
        var state = PPRoot()
        state.entities["e"] = PPEntity()
        state.hands[PlayerID("p0")] = ["c"]
        state.ratio = 1
        let p0 = PlayerID("p0"), p1 = PlayerID("p1")
        let typed = SyncTablePerPlayerDiff<PPRoot>()
        _ = typedPlan(typed, state, [p1], fields: nil)
        state.risky.n = -1
        state.ratio = 2
        let plan = typedPlan(typed, state, [p1, p0], fields: ["risky", "ratio"])
        #expect(plan.drops.perPlayerFields == [p1: ["risky"]] && plan.drops.count == 1)
        #expect(plan.patches[p1]!.map(\.path) == ["/ratio"], "the throwing pair sends nothing; the rest flows")
        #expect(plan.patches[p0] == [], "a seed sends nothing")
        // p0's seed: B1's, as in a plan without the throw.
        let reference = SyncTablePerPlayerDiff<PPRoot>()
        var clean = state
        clean.risky.n = 1
        _ = typedPlan(reference, clean, [p0], fields: ["risky", "ratio"])
        let seeded = try #require(typed.lastSentSnapshot(for: p0))
        let expected = try #require(reference.lastSentSnapshot(for: p0))
        #expect(Set(seeded.values.keys) == Set(expected.values.keys))
        #expect(seeded.values.keys.contains("entities") && seeded.values.keys.contains("hands"), "fields outside S are seeded")
        #expect(typed.lastSentSnapshot(for: p1)?.values["risky"] == .object(["n": .int(0)]), "p1's box keeps what its client has")
    }

    /// M10: a player without boxes whose own conversion throws, for a field outside S and one
    /// inside it: the fields that convert are seeded, the throwing one stays unseeded (absent)
    /// with one drop, and it is set whole when it is next compared.
    @Test("One-pass: a player without boxes whose own field throws leaves that field unseeded (M10)", arguments: [false, true])
    func onePassOwnThrow(insideS: Bool) throws {
        var state = PPRoot()
        state.risky.n = -1
        state.ratio = 1
        let p1 = PlayerID("p1")
        let typed = SyncTablePerPlayerDiff<PPRoot>()
        let seed = typedPlan(typed, state, [p1], fields: insideS ? ["risky"] : ["ratio"])
        #expect(seed.drops.perPlayerFields == [p1: ["risky"]] && seed.drops.count == 1)
        #expect(seed.patches[p1] == [])
        let boxes = try #require(typed.lastSentSnapshot(for: p1))
        #expect(boxes.values["risky"] == nil && boxes.values["ratio"] == .double(1), "\(boxes.values.keys.sorted())")
        state.risky.n = 3
        let next = typedPlan(typed, state, [p1], fields: ["risky"])
        #expect(next.drops.count == 0)
        #expect(next.patches[p1]!.map(\.path) == ["/risky"], "set whole: it was absent")
        // B2 seeds only S: outside S the throwing field isn't read, so nothing is counted.
        let b2 = SyncTablePerPlayerDiff<PPRoot>()
        state.risky.n = -1
        let b2Seed = typedPlan(b2, state, [p1], fields: insideS ? ["risky"] : ["ratio"], seedsAll: false)
        #expect(b2Seed.drops.count == (insideS ? 1 : 0))
    }

    /// Two failing roots for one player: each is dropped and counted, both boxes keep their
    /// values, and the other root flows; with B1 and B2 alike.
    @Test("Two failing roots for one player: two drops, both boxes kept, the other root flows", arguments: [false, true])
    func twoFailingRoots(onePass: Bool) throws {
        var state = PPTwoRoots()
        state.first.n = 1
        state.second.n = 1
        let p0 = PlayerID("p0")
        let typed = SyncTablePerPlayerDiff<PPTwoRoots>()
        _ = typedPlan(typed, state, [p0], fields: nil, seedsAll: onePass)
        state.first.n = -1
        state.second.n = -2
        state.fine = 3
        let plan = typedPlan(typed, state, [p0], fields: ["first", "second", "fine"], seedsAll: onePass)
        #expect(plan.drops.perPlayerFields == [p0: ["first", "second"]] && plan.drops.count == 2)
        #expect(plan.patches[p0]!.map(\.path) == ["/fine"])
        let boxes = try #require(typed.lastSentSnapshot(for: p0))
        #expect(boxes.values["first"] == .object(["n": .int(1)]) && boxes.values["second"] == .object(["n": .int(1)]))
    }

    /// A root whose conversion throws after some of its patches were emitted keeps none of them,
    /// and its box isn't advanced: the next plan sends the whole change.
    @Test("A node root whose second leaf throws keeps none of its patches (T1)")
    func partialRoot() throws {
        var state = PPPairRoot()
        let p0 = PlayerID("p0")
        let typed = SyncTablePerPlayerDiff<PPPairRoot>()
        _ = typedPlan(typed, state, [p0], fields: nil)
        state.pair.a = 2
        state.pair.b.n = -1
        let failing = typedPlan(typed, state, [p0], fields: ["pair"])
        #expect(failing.drops.count == 1)
        #expect(failing.patches[p0] == [], "the converted first leaf isn't kept: \(ppDescribe(failing.patches[p0]))")
        state.pair.b.n = 5
        let next = typedPlan(typed, state, [p0], fields: ["pair"])
        #expect(next.patches[p0]!.map(\.path) == ["/pair/a", "/pair/b/n"])
    }
}
