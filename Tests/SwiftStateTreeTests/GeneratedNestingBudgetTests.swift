// Tests/SwiftStateTreeTests/GeneratedNestingBudgetTests.swift
//
// #716 S1a-2a: the budget reaches every conversion the macros generate, and typed maps take
// their fast path by conformance instead of a collection cast. Values past the limit are built
// iteratively, and in-process cases stay at the limit and one past it. The exit tests would
// overflow only if a guard were removed: run those mutants on the Linux host, never on the Mac.

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Fixtures

/// A node chain: each level's only child sits in its `children` map, so each level below the
/// root adds two containers (the child's object and its map).
@StateNodeBuilder
private struct ChainNode: StateNodeProtocol {
    @Sync(.broadcast) var children: [String: ChainNode] = [:]
    init() {}
}

/// A root with `levels` nodes below it, built without recursion. Converted by the root's own
/// members, its fields hold `1 + 2 · levels` containers on the deepest path.
private func chain(_ levels: Int) -> ChainNode {
    var node = ChainNode()
    for _ in 0..<levels {
        var parent = ChainNode()
        parent.children["c"] = node
        node = parent
    }
    return node
}

/// Properties named like the generated code's `budget` and `inner`.
@SnapshotConvertible
private struct BudgetNamed {
    var inner: Int = 1
    var budget: String = "b"
    var leaf: ConvertibleLeaf = ConvertibleLeaf()
}

@SnapshotConvertible
private struct ConvertibleLeaf: Equatable {
    var hp: Int = 3
}

/// A node that is also `@SnapshotConvertible` (`PlayerState`'s shape): as a node it leaves out
/// its server-only field, as a convertible it would not.
@StateNodeBuilder
@SnapshotConvertible
private struct BothNode: StateNodeProtocol {
    @Sync(.broadcast) var hp: Int = 5
    @Sync(.serverOnly) var secret: Int = 9
    init() {}
}

/// A node with a player-dependent field: refused in the view without a player (#179).
@StateNodeBuilder
private struct PerPlayerNode: StateNodeProtocol {
    @Sync(.perPlayerSlice()) var own: [PlayerID: Int] = [:]
    init() {}
}

/// A struct that converts through `Mirror`: one container.
private struct MirrorLeaf { var hp = 1 }

/// `hops` nested `Optional<Any>` around a `MirrorLeaf`: `hops` unwraps, then one container.
private func optionalChain(_ hops: Int) -> Any {
    var value: Any = MirrorLeaf()
    for _ in 0..<hops { value = Optional<Any>.some(value) as Any }
    return value
}

private func isNestingRefusal(_ error: any Error, _ counter: NestingBudget.Counter, limit: Int) -> Bool {
    guard case let SyncError.nestingTooDeep(seen, seenLimit, _) = error else { return false }
    return seen == counter && seenLimit == limit
}

/// Expects `body` to throw `SyncError.nestingTooDeep` for `counter` at `limit`.
private func expectRefusal(
    _ counter: NestingBudget.Counter,
    limit: Int,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    let error = #expect(throws: SyncError.self, sourceLocation: sourceLocation) { try body() }
    #expect(error.map { isNestingRefusal($0, counter, limit: limit) } == true,
            "refused by \(counter) at \(limit): \(String(describing: error))", sourceLocation: sourceLocation)
}

/// A budget of `containers` with the default hops.
private func containers(_ count: Int) -> NestingBudget {
    NestingBudget(containers: count, hops: NestingBudget.hopLimit)
}

// MARK: - The typed-map casts before #716 S1a-2a

/// Today's existential casts for typed maps, kept here as the oracle the conformance paths must
/// match: nil when none of them catches `value`.
private func oldTypedMap(_ value: Any, for playerID: PlayerID?) throws -> SnapshotValue? {
    if let map = value as? [PlayerID: SnapshotValueConvertible] {
        var object: [String: SnapshotValue] = [:]
        for (key, val) in map { object[key.rawValue] = try SnapshotValue.make(from: val, for: playerID) }
        return .object(object)
    }
    if let map = value as? [PlayerID: any StateNodeProtocol] {
        var object: [String: SnapshotValue] = [:]
        for (key, val) in map {
            if playerID == nil, type(of: val).hasPlayerDependentSyncFields {
                throw SyncError.unsupportedValue("player-dependent")
            }
            object[key.rawValue] = .object(try val.snapshot(for: playerID, dirtyFields: nil).values)
        }
        return .object(object)
    }
    if let map = value as? [String: SnapshotValueConvertible] {
        var object: [String: SnapshotValue] = [:]
        for (key, val) in map { object[SnapshotValue.wireKey(key)] = try SnapshotValue.make(from: val, for: playerID) }
        return .object(object)
    }
    // A map of nodes with `String` keys went through `[String: Any]`.
    if let map = value as? [String: Any] {
        var object: [String: SnapshotValue] = [:]
        for (key, val) in map { object[SnapshotValue.wireKey(key)] = try SnapshotValue.make(from: val, for: playerID) }
        return .object(object)
    }
    return nil
}

// MARK: - Tests

@Suite("The nesting budget through generated conversions (#716 S1a-2a)")
struct GeneratedNestingBudgetTests {
    @Test("a property named budget or inner converts as itself, not as the generated local")
    func generatedNamesDontShadowProperties() throws {
        let expected = SnapshotValue.object(["inner": .int(1), "budget": .string("b"), "leaf": .object(["hp": .int(3)])])
        #expect(try SnapshotValue.make(from: BudgetNamed()) == expected)
        #expect(try SnapshotValue.makeFull(from: BudgetNamed()) == expected)
    }

    @Test("a node chain at the limit converts through every generated member, and one level more is refused")
    func generatedMembersCarryTheBudget() throws {
        let levels = 10
        let atLimit = containers(1 + 2 * levels)
        let pastLimit = containers(2 * levels)
        let node = chain(levels)
        let player = PlayerID("p")
        _ = try node.snapshot(for: nil, dirtyFields: nil, budget: atLimit)
        _ = try node.snapshot(for: player, dirtyFields: nil, budget: atLimit)
        _ = try node.broadcastSnapshot(dirtyFields: nil, budget: atLimit)
        _ = try node.snapshotForSync(playerIDs: [player], dirtyFields: nil, budget: atLimit)
        _ = try node.fullStateSnapshot(budget: atLimit)
        let limit = 2 * levels
        expectRefusal(.containers, limit: limit) { _ = try node.snapshot(for: nil, dirtyFields: nil, budget: pastLimit) }
        expectRefusal(.containers, limit: limit) { _ = try node.snapshot(for: player, dirtyFields: nil, budget: pastLimit) }
        expectRefusal(.containers, limit: limit) { _ = try node.broadcastSnapshot(dirtyFields: nil, budget: pastLimit) }
        expectRefusal(.containers, limit: limit) { _ = try node.snapshotForSync(playerIDs: [player], dirtyFields: nil, budget: pastLimit) }
        expectRefusal(.containers, limit: limit) { _ = try node.fullStateSnapshot(budget: pastLimit) }
    }

    @Test("make, makeFull and a convertible's budget-aware form spend the value's own object")
    func generatedConvertibleCarriesTheBudget() throws {
        // `BudgetNamed`'s object, then its `leaf`'s object: two containers.
        _ = try SnapshotValue.make(from: BudgetNamed(), budget: containers(2))
        _ = try BudgetNamed().toSnapshotValue(budget: containers(2))
        _ = try BudgetNamed().toFullSnapshotValue(budget: containers(2))
        expectRefusal(.containers, limit: 1) { _ = try SnapshotValue.make(from: BudgetNamed(), budget: containers(1)) }
        expectRefusal(.containers, limit: 1) { _ = try BudgetNamed().toSnapshotValue(budget: containers(1)) }
        expectRefusal(.containers, limit: 1) { _ = try BudgetNamed().toFullSnapshotValue(budget: containers(1)) }
        // A node reached through `make` spends its object: 2 + 2 · levels.
        _ = try SnapshotValue.make(from: chain(10), budget: containers(22))
        expectRefusal(.containers, limit: 21) { _ = try SnapshotValue.make(from: chain(10), budget: containers(21)) }
        _ = try SnapshotValue.makeFull(from: chain(10), budget: containers(22))
        expectRefusal(.containers, limit: 21) { _ = try SnapshotValue.makeFull(from: chain(10), budget: containers(21)) }
    }

    #if DEBUG
    @Test("the generated path refuses in the conversion, never in a default's check of the result")
    func generatedPathChecksNoResult() throws {
        let probe = NestingBudget.Probe()
        try NestingBudget.$probe.withValue(probe) {
            let node = chain(10)
            _ = try node.snapshotForSync(playerIDs: [PlayerID("p")], dirtyFields: nil, budget: containers(21))
            _ = try node.fullStateSnapshot(budget: containers(21))
            _ = try SnapshotValue.make(from: BudgetNamed())
            expectRefusal(.containers, limit: 20) { _ = try node.snapshot(for: nil, dirtyFields: nil, budget: containers(20)) }
        }
        #expect(probe.count(.resultCheck) == 0)
        #expect(probe.count(.nodeMap) > 0, "the chain's maps take the node-map conformance")
    }

    @Test("a typed map takes its conformance's fast path, not the boxing fallback")
    func typedMapsTakeTheConformance() throws {
        let nodes = NestingBudget.Probe()
        try NestingBudget.$probe.withValue(nodes) {
            _ = try SnapshotValue.make(from: [PlayerID("a"): BothNode()], for: PlayerID("a"))
        }
        #expect(nodes.count(.nodeMap) == 1)
        #expect(nodes.count(.convertibleMap) == 0)
        let convertibles = NestingBudget.Probe()
        try NestingBudget.$probe.withValue(convertibles) {
            _ = try SnapshotValue.make(from: ["k": ConvertibleLeaf()])
            _ = try SnapshotValue.make(from: [PlayerID("a"): ConvertibleLeaf()])
        }
        #expect(convertibles.count(.convertibleMap) == 2)
        #expect(convertibles.count(.nodeMap) == 0)
    }
    #endif

    @Test("a typed map converts exactly as the casts before it did")
    func typedMapsMatchTheOldCasts() throws {
        let a = PlayerID("a"), b = PlayerID("b")
        // A key whose NFC form differs: written as the wire spells it.
        let decomposed = "e\u{0301}"
        let cases: [(name: String, value: Any)] = [
            ("[PlayerID: convertible]", [a: ConvertibleLeaf(), b: ConvertibleLeaf(hp: 4)]),
            ("[String: convertible]", ["x": ConvertibleLeaf(), decomposed: ConvertibleLeaf(hp: 4)]),
            ("[PlayerID: node]", [a: chain(2), b: chain(0)]),
            ("[String: node]", ["x": chain(2), decomposed: chain(1)]),
            ("[PlayerID: node and convertible]", [a: BothNode(), b: BothNode()]),
            ("[String: node and convertible]", ["x": BothNode()]),
            ("[PlayerID: player-dependent node]", [a: PerPlayerNode()]),
            ("empty [PlayerID: node]", [PlayerID: ChainNode]()),
        ]
        for (name, value) in cases {
            for player in [nil, a] {
                let old = Result { try oldTypedMap(value, for: player) }
                let new = Result { try SnapshotValue.make(from: value, for: player) }
                switch (old, new) {
                case let (.success(expected), .success(actual)):
                    #expect(expected == actual, "\(name), player \(String(describing: player))")
                case (.failure, .failure):
                    // Both refuse a player-dependent node without a player (#179).
                    #expect(player == nil && name.contains("player-dependent"), "\(name)")
                default:
                    Issue.record("\(name), player \(String(describing: player)): old \(old), new \(new)")
                }
            }
        }
        // A node converts by its own policies, so the server-only field is left out.
        #expect(try SnapshotValue.make(from: [a: BothNode()], for: a) == .object(["a": .object(["hp": .int(5)])]))
    }

    @Test("concrete collections convert by their exact type, as before")
    func concreteCollections() throws {
        let decomposed = "e\u{0301}"
        let composed = "\u{00E9}"
        #expect(try SnapshotValue.make(from: [SnapshotValue.int(1)]) == .array([.int(1)]))
        #expect(try SnapshotValue.make(from: [decomposed: SnapshotValue.int(1)]) == .object([composed: .int(1)]))
        #expect(try SnapshotValue.make(from: [PlayerID("a"): SnapshotValue.int(1)]) == .object(["a": .int(1)]))
        #expect(try SnapshotValue.make(from: ["x", "y"]) == .array([.string("x"), .string("y")]))
        #expect(try SnapshotValue.make(from: [1, 2]) == .array([.int(1), .int(2)]))
        // The same elements boxed in `[Any]` convert element by element, to the same values.
        #expect(try SnapshotValue.make(from: ["x", "y"] as [Any]) == .array([.string("x"), .string("y")]))
        #expect(try SnapshotValue.make(from: [1, 2] as [Any]) == .array([.int(1), .int(2)]))
        #expect(try SnapshotValue.make(from: ["k": 1] as [String: Any]) == .object(["k": .int(1)]))
    }

    @Test("an Optional chain inside an [Any] or a [String: Any] spends a hop per Optional")
    func optionalChainInsideCollections() throws {
        let hops = 4
        for full in [false, true] {
            func convert(_ value: Any, _ budget: NestingBudget) throws -> SnapshotValue {
                try full ? SnapshotValue.makeFull(from: value, budget: budget) : SnapshotValue.make(from: value, budget: budget)
            }
            let within = NestingBudget(containers: NestingBudget.containerLimit, hops: hops)
            _ = try convert([optionalChain(hops)] as [Any], within)
            _ = try convert(["k": optionalChain(hops)] as [String: Any], within)
            expectRefusal(.hops, limit: hops) { _ = try convert([optionalChain(hops + 1)] as [Any], within) }
            expectRefusal(.hops, limit: hops) { _ = try convert(["k": optionalChain(hops + 1)] as [String: Any], within) }
        }
    }

    @Test("an AnyHashable around NSNull is refused as an unsupported value, no longer converted to null")
    func anyHashableAroundNSNullIsUnsupported() {
        // Since #735 the NSNull check matches the exact type, so the box isn't looked through;
        // `@Sync` refuses `AnyHashable`, so only a hand-written conversion can pass one.
        for full in [false, true] {
            let error = #expect(throws: SyncError.self) {
                _ = try full ? SnapshotValue.makeFull(from: AnyHashable(NSNull())) : SnapshotValue.make(from: AnyHashable(NSNull()))
            }
            guard case .unsupportedValue(_)? = error else {
                Issue.record("expected unsupportedValue, got \(String(describing: error))")
                continue
            }
        }
    }

    @Test("a node chain far past the limit is refused before the conversion recurses deep (exit test)")
    func farPastTheLimitThroughNodesIsRefused() async {
        // With the generated members restarting the count (the budget not passed on), this
        // overflows the child's stack: a mutant for the Linux host.
        await #expect(processExitsWith: .success) {
            let deep = chain(100_000)
            // `deep` must outlive the process: its release recurses once per level, and a release
            // build would otherwise release it after its last use, before `exit`.
            withExtendedLifetime(deep) {
                let player = PlayerID("p")
                let attempts: [() throws -> Void] = [
                    { _ = try SnapshotValue.make(from: deep) },
                    { _ = try SnapshotValue.makeFull(from: deep) },
                    { _ = try deep.snapshotForSync(playerIDs: [player], dirtyFields: nil) },
                ]
                for attempt in attempts {
                    do {
                        try attempt()
                        exit(1)
                    } catch let error {
                        guard isNestingRefusal(error, .containers, limit: NestingBudget.containerLimit) else { exit(2) }
                    }
                }
                exit(0)
            }
        }
    }

    @Test("an Optional chain far past the hop limit inside collections is refused before a cast unwraps it (exit test)")
    func farPastTheHopLimitInsideCollectionsIsRefused() async {
        // With a collection cast in place of the exact-type check, the runtime unwraps the
        // chain element by element and overflows the child's stack: a mutant for the Linux host.
        await #expect(processExitsWith: .success) {
            let deep = optionalChain(100_000)
            // Kept alive until `exit`, as above.
            withExtendedLifetime(deep) {
                let values: [Any] = [[deep] as [Any], ["k": deep] as [String: Any]]
                for value in values {
                    for full in [false, true] {
                        do {
                            _ = try full ? SnapshotValue.makeFull(from: value) : SnapshotValue.make(from: value)
                            exit(1)
                        } catch let error {
                            guard isNestingRefusal(error, .hops, limit: NestingBudget.hopLimit) else { exit(2) }
                        }
                    }
                }
                exit(0)
            }
        }
    }
}
