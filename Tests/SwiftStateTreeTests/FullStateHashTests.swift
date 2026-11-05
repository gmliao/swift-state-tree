// Tests/SwiftStateTreeTests/FullStateHashTests.swift
//
// The replay state hash covers every `@Sync` field at every depth, whatever its policy (#180),
// and never reaches a client path.

import Foundation
import Testing
@testable import SwiftStateTree

@Suite("Full-state replay hash")
struct FullStateHashTests {
    @Test("The full snapshot has every @Sync field at every depth, unfiltered; @Internal is out")
    func everyField() throws {
        let state = FullHashState.sample()
        let values = try state.fullStateSnapshot().values
        #expect(Set(values.keys) == ["monsters", "list", "maybe", "seed", "notes", "score", "tags", "ids", "byKey"])
        #expect(values["seed"] == .int(7), "server-only")
        #expect(values["score"] == .int(42), "masked: the raw value, not the mask")
        #expect(values["notes"] == .object(["alice": .int(1), "bob": .int(2)]), "per-player: the whole value")
        guard case .object(let monsters)? = values["monsters"], case .object(let goblin)? = monsters["goblin"] else {
            Issue.record("monsters.goblin missing: \(String(describing: values["monsters"]))")
            return
        }
        #expect(goblin["progress"] == .int(3), "server-only field of a nested node in a map")
        guard case .array(let list)? = values["list"], case .object(let first)? = list.first else {
            Issue.record("list missing")
            return
        }
        #expect(first["progress"] == .int(5), "in an array")
        guard case .object(let maybe)? = values["maybe"] else {
            Issue.record("maybe missing")
            return
        }
        #expect(maybe["progress"] == .int(9), "in an optional")
    }

    @Test("Changing any server-only field changes the full-state hash, not the broadcast-view hash")
    func serverOnlyFieldsCount() {
        let base = FullHashState.sample()
        let mutations: [(String, (inout FullHashState) -> Void)] = [
            ("root seed", { $0.seed += 1 }),
            ("map node", { $0.monsters["goblin"]?.progress += 1 }),
            ("array node", { $0.list[0].progress += 1 }),
            ("optional node", { $0.maybe?.progress += 1 }),
            ("masked", { $0.score += 1 }),
            ("per-player", { $0.notes[PlayerID("alice")] = 5 }),
            ("set", { $0.tags.insert("new") }),
        ]
        for (name, mutate) in mutations {
            var changed = base
            mutate(&changed)
            #expect(ReevaluationEngine.calculateStateHash(changed) != ReevaluationEngine.calculateStateHash(base), "\(name)")
            #expect(
                ReevaluationEngine.calculateBroadcastViewHash(changed) == ReevaluationEngine.calculateBroadcastViewHash(base),
                "\(name) is not in the broadcast view"
            )
        }
        var internalChanged = base
        internalChanged.cache = 99
        #expect(ReevaluationEngine.calculateStateHash(internalChanged) == ReevaluationEngine.calculateStateHash(base), "@Internal is not hashed")
    }

    @Test("Insertion order of maps and sets does not reach the hash")
    func ordering() {
        var a = FullHashState()
        var b = FullHashState()
        let names = (0..<40).map { "m\($0)" }
        for name in names { a.monsters[name] = FullHashMonster(hp: name.count, progress: 1) }
        for name in names.reversed() { b.monsters[name] = FullHashMonster(hp: name.count, progress: 1) }
        a.tags = Set(names)
        b.tags.reserveCapacity(1000)
        for name in names.reversed() { b.tags.insert(name) }
        a.ids = Set((0..<40).map { FullHashMonster(hp: $0, progress: $0 % 3) })
        b.ids.reserveCapacity(1000)
        for i in (0..<40).reversed() { b.ids.insert(FullHashMonster(hp: i, progress: i % 3)) }
        #expect(ReevaluationEngine.calculateStateHash(a) == ReevaluationEngine.calculateStateHash(b))
    }

    @Test("Set elements are ordered by their full conversion, server-only fields included")
    func setOrderUsesFullConversion() throws {
        var state = FullHashState()
        state.ids = [FullHashMonster(hp: 1, progress: 2), FullHashMonster(hp: 1, progress: 1)]
        let values = try state.fullStateSnapshot().values
        #expect(values["ids"] == .array([
            .object(["hp": .int(1), "progress": .int(1)]),
            .object(["hp": .int(1), "progress": .int(2)]),
        ]))
    }

    @Test("Map keys that collide as strings throw instead of hashing ambiguously")
    func keyCollision() {
        var state = FullHashState()
        state.byKey = [CollidingKey(id: 1): 1, CollidingKey(id: 2): 2]
        #expect(throws: SyncError.self) { try state.fullStateSnapshot() }
        #expect(ReevaluationEngine.stateHash(state, definition: .fullState) == nil)
    }

    @Test("The record version picks the hash definition")
    func definitionByVersion() {
        #expect(ReevaluationRecordVersion.current == "2.4")
        #expect(ReevaluationRecordVersion.hashDefinition(recorded: "2.4") == .fullState)
        #expect(ReevaluationRecordVersion.hashDefinition(recorded: "2.9") == .fullState)
        #expect(ReevaluationRecordVersion.hashDefinition(recorded: ReevaluationRecordVersion.current) == .fullState)
        for old in ["2", "2.0", "2.1", "2.2", "2.3"] {
            #expect(ReevaluationRecordVersion.hashDefinition(recorded: old) == .broadcastView, "\(old)")
        }
    }

    @Test("The initialize check compares with the record's hash definition")
    func initializeByDefinition() {
        let state = FullHashState.sample()
        let full = ReevaluationEngine.calculateStateHash(state)
        let broadcast = ReevaluationEngine.calculateBroadcastViewHash(state)
        #expect(full != broadcast)
        func verify(_ hash: String, _ definition: ReevaluationHashDefinition) -> ReevaluationEngine.InitializeVerification {
            ReevaluationEngine.verifyInitialize(
                record: ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: hash),
                emitted: [], state: state, hashDefinition: definition
            )
        }
        #expect(verify(full, .fullState) == .passed)
        #expect(verify(broadcast, .broadcastView) == .passed)
        guard case .failed = verify(broadcast, .fullState) else {
            Issue.record("a broadcast-view hash must not pass as a full-state hash")
            return
        }
    }

    @Test("Client paths never run the full conversion")
    func offClientPaths() throws {
        let state = FullHashState.sample()
        let alice = PlayerID("alice")
        let clientCalls = try FullStateConversionProbe.count {
            var engine = SyncEngine()
            _ = try engine.lateJoinSnapshot(for: alice, from: state)
            _ = try engine.generateDiff(for: alice, from: state)
            var changed = state
            changed.seed += 1
            changed.monsters["goblin"]?.hp += 1
            _ = try engine.generateDiff(for: alice, from: changed)
            _ = try engine.extractWithSnapshotForSync(from: changed, playerIDs: [alice])
            _ = try engine.snapshot(from: changed)
            _ = ReevaluationEngine.calculateBroadcastViewHash(changed)
        }
        #expect(clientCalls == 0)
        let hashCalls = FullStateConversionProbe.count { _ = ReevaluationEngine.calculateStateHash(state) }
        #expect(hashCalls > 0)
    }
}

struct CollidingKey: Hashable, Sendable, CustomStringConvertible {
    let id: Int
    var description: String { "same" }
}

@StateNodeBuilder
@SnapshotConvertible
struct FullHashMonster: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 0
    @Sync(.serverOnly) var progress: Int = 0

    init() {}
    init(hp: Int, progress: Int) {
        self.hp = hp
        self.progress = progress
    }

}

extension FullHashMonster: Hashable {
    static func == (a: FullHashMonster, b: FullHashMonster) -> Bool { a.hp == b.hp && a.progress == b.progress }
    func hash(into hasher: inout Hasher) {
        hasher.combine(hp)
        hasher.combine(progress)
    }
}

@StateNodeBuilder
struct FullHashState: StateNodeProtocol {
    @Sync(.broadcast) var monsters: [String: FullHashMonster] = [:]
    @Sync(.broadcast) var list: [FullHashMonster] = []
    @Sync(.broadcast) var maybe: FullHashMonster? = nil
    @Sync(.serverOnly) var seed: Int = 0
    @Sync(.perPlayer({ (value: [PlayerID: Int], player: PlayerID) in value.filter { $0.key == player } }))
    var notes: [PlayerID: Int] = [:]
    @Sync(.masked({ (_: Int) in 0 })) var score: Int = 0
    @Sync(.serverOnly) var tags: Set<String> = []
    @Sync(.serverOnly) var ids: Set<FullHashMonster> = []
    @Sync(.serverOnly) var byKey: [CollidingKey: Int] = [:]
    @Internal var cache: Int = 0

    init() {}

    static func sample() -> FullHashState {
        var state = FullHashState()
        state.monsters = ["goblin": FullHashMonster(hp: 10, progress: 3)]
        state.list = [FullHashMonster(hp: 4, progress: 5)]
        state.maybe = FullHashMonster(hp: 8, progress: 9)
        state.seed = 7
        state.notes = [PlayerID("alice"): 1, PlayerID("bob"): 2]
        state.score = 42
        state.tags = ["a", "b"]
        return state
    }
}

@StateNodeBuilder
struct UnhashableTickState: StateNodeProtocol {
    @Sync(.broadcast) var ticks: Int = 0
    @Sync(.serverOnly) var byKey: [CollidingKey: Int] = [CollidingKey(id: 1): 1, CollidingKey(id: 2): 2]

    init() {}
}

@Test("A live state hash that cannot be computed is recorded as unavailable; the tick still runs (#180)")
func liveUnavailableStateHash() async throws {
    let definition = Land("unhashable-tick", using: UnhashableTickState.self) {
        Rules {}
        Lifetime {
            Tick(every: .seconds(3600)) { (state: inout UnhashableTickState, _: LandContext) in
                state.ticks += 1
            }
        }
    }
    let keeper = LandKeeper<UnhashableTickState>(
        definition: definition,
        initialState: UnhashableTickState(),
        enableLiveStateHashRecording: true,
        autoStartLoops: false
    )
    let recorder = try #require(await keeper.getReevaluationRecorder())
    await keeper.stepTickOnce()
    await keeper.stepTickOnce()
    #expect(await keeper.currentState().ticks == 2)
    #expect(await keeper.stateHashUnavailableCount >= 2)
    await keeper.waitForRecorderSubmissionsForTesting()
    let hashes = await recorder.getAllFrames().compactMap(\.stateHash)
    #expect(hashes.count >= 2)
    #expect(hashes.allSatisfy { ReevaluationEngine.isUnavailableHash($0) && $0.hasPrefix(ReevaluationEngine.unavailableHashPrefix) }, "\(hashes)")
}

// MARK: - Review round 1 (#185)

@SnapshotConvertible
struct NodeHolder: Sendable {
    var label: String = ""
    var node: FullHashMonster = FullHashMonster()
}

enum NodeChoice: Sendable {
    case none
    case one(FullHashMonster)
}

@StateNodeBuilder
struct WrapperHashState: StateNodeProtocol {
    @Sync(.serverOnly) var holder: NodeHolder = NodeHolder()
    @Sync(.serverOnly) var choice: NodeChoice = NodeChoice.none
    @Sync(.serverOnly) var big: UInt64 = UInt64.max
    @Sync(.broadcast) var bigShown: UInt64 = UInt64.max
    @Sync(.broadcast) var bigUInt: UInt = UInt.max
    @Sync(.serverOnly) var ratio: Double = 0

    init() {}
}

@Suite("Full-state replay hash: wrappers, unsigned values, NaN")
struct FullStateHashReviewTests {
    @Test("A node inside a @SnapshotConvertible value or an enum payload is hashed in full")
    func nodesInsideWrappers() throws {
        var state = WrapperHashState()
        state.holder.node = FullHashMonster(hp: 1, progress: 2)
        state.choice = .one(FullHashMonster(hp: 3, progress: 4))
        let values = try state.fullStateSnapshot().values
        #expect(values["holder"] == .object(["label": .string(""), "node": .object(["hp": .int(1), "progress": .int(2)])]))
        #expect(values["choice"] == .object(["one": .object(["hp": .int(3), "progress": .int(4)])]))
        var changed = state
        changed.holder.node.progress = 9
        #expect(ReevaluationEngine.calculateStateHash(changed) != ReevaluationEngine.calculateStateHash(state))
        changed = state
        changed.choice = .one(FullHashMonster(hp: 3, progress: 5))
        #expect(ReevaluationEngine.calculateStateHash(changed) != ReevaluationEngine.calculateStateHash(state))
        #expect(try WrapperHashState().fullStateSnapshot().values["choice"] == .string("none"))
    }

    @Test("Unsigned values above Int.max convert losslessly instead of trapping")
    func largeUnsigned() throws {
        let state = WrapperHashState()
        let full = try state.fullStateSnapshot().values
        #expect(full["big"] == .string("18446744073709551615"))
        let broadcast = try state.snapshot(for: nil, dirtyFields: nil).values
        #expect(broadcast["bigShown"] == .string("18446744073709551615"), "the broadcast path no longer traps")
        #expect(broadcast["bigUInt"] == .string(String(UInt.max)))
        #expect(try SnapshotValue.make(from: UInt64(5)) == .int(5), "values that fit stay ints")
        #expect(!ReevaluationEngine.isUnavailableHash(ReevaluationEngine.calculateStateHash(state)))
    }

    @Test("A server-only UInt64.max is recorded with a valid live hash (#185)")
    func largeUnsignedLive() async throws {
        let definition = Land("big-unsigned", using: WrapperHashState.self) {
            Rules {}
            Lifetime {
                Tick(every: .seconds(3600)) { (state: inout WrapperHashState, _: LandContext) in
                    state.ratio += 1
                }
            }
        }
        let keeper = LandKeeper<WrapperHashState>(
            definition: definition,
            initialState: WrapperHashState(),
            enableLiveStateHashRecording: true,
            autoStartLoops: false
        )
        let recorder = try #require(await keeper.getReevaluationRecorder())
        await keeper.stepTickOnce()
        await keeper.waitForRecorderSubmissionsForTesting()
        #expect(await keeper.stateHashUnavailableCount == 0)
        let hashes = await recorder.getAllFrames().compactMap(\.stateHash)
        #expect(!hashes.isEmpty && hashes.allSatisfy { !ReevaluationEngine.isUnavailableHash($0) }, "\(hashes)")
    }

    @Test("NaN makes a tick's state hash unavailable")
    func nanIsUnavailable() {
        var state = WrapperHashState()
        state.ratio = .nan
        #expect(ReevaluationEngine.stateHash(state, definition: .fullState) == nil)
        #expect(ReevaluationEngine.isUnavailableHash(ReevaluationEngine.calculateStateHash(state)))
    }

    @Test("Initialize: recorded unavailable is unverifiable; a valid recording the replay cannot compute fails")
    func initializeUnavailable() {
        let unavailable = ReevaluationEngine.verifyInitialize(
            record: ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: "unavailable: x"),
            emitted: [], state: FullHashState()
        )
        guard case .unverifiable = unavailable else {
            Issue.record("expected unverifiable, got \(unavailable)")
            return
        }
        var throwing = FullHashState()
        throwing.byKey = [CollidingKey(id: 1): 1, CollidingKey(id: 2): 2]
        let diverged = ReevaluationEngine.verifyInitialize(
            record: ReevaluationRecordedInitialize(sequence: 0, serverEvents: [], stateHash: "0123456789abcdef"),
            emitted: [], state: throwing
        )
        guard case .failed = diverged else {
            Issue.record("expected failed, got \(diverged)")
            return
        }
    }
}

@StateNodeBuilder
struct UnsignedRoundTripState: StateNodeProtocol, StateFromSnapshotDecodable {
    @Sync(.broadcast) var big: UInt64 = 0
    @Sync(.broadcast) var bigUInt: UInt = 0
    @Sync(.broadcast) var small: UInt64 = 0
}

@Test("UInt64.max and UInt.max round-trip through the broadcast snapshot as decimal strings")
func unsignedRoundTrip() throws {
    var state = UnsignedRoundTripState()
    state.big = UInt64.max
    state.bigUInt = UInt.max
    state.small = 7
    let snapshot = try state.broadcastSnapshot(dirtyFields: nil)
    #expect(snapshot.values["big"] == .string("18446744073709551615"))
    #expect(snapshot.values["small"] == .int(7))
    let decoded = try UnsignedRoundTripState(fromBroadcastSnapshot: snapshot)
    #expect(decoded.big == UInt64.max)
    #expect(decoded.bigUInt == UInt.max)
    #expect(decoded.small == 7)
    // Only the canonical form above Int.max is accepted as a string.
    #expect(throws: SnapshotDecodeError.self) { try UInt64(fromSnapshotValue: .string("7")) }
    #expect(throws: SnapshotDecodeError.self) { try UInt64(fromSnapshotValue: .string("018446744073709551615")) }
    #expect(throws: SnapshotDecodeError.self) { try UInt64(fromSnapshotValue: .string("x")) }
}
