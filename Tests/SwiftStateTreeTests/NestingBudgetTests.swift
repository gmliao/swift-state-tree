// Tests/SwiftStateTreeTests/NestingBudgetTests.swift
//
// #716 S1a-1: the budget every state conversion carries. Every value past the limit is built
// iteratively, and in-process cases stay at the limit and one past it, so a regression fails a
// test instead of overflowing the runner. The exit tests would overflow only if a guard were
// removed: run those mutants on the Linux host, never on the Mac (a crash raises a dialog there).

import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Values built without recursion

/// `depth` nested `[Any]` arrays around an `Int`: `depth` containers, converted through `Mirror`.
private func nestedAny(_ depth: Int) -> Any {
    var value: Any = 1
    for _ in 0..<depth { value = [value] as [Any] }
    return value
}

/// `depth` nested `SnapshotValue` arrays around an `.int`: a prebuilt tree of `depth` containers.
private func nestedSnapshot(_ depth: Int) -> SnapshotValue {
    var value = SnapshotValue.int(1)
    for _ in 0..<depth { value = .array([value]) }
    return value
}

/// A struct that converts through `Mirror`: one container.
private struct NestingLeaf { var hp = 1 }

/// `hops` nested `Optional<Any>` around a `NestingLeaf`: `hops` unwraps, then one container.
private func optionalChain(_ hops: Int) -> Any {
    var value: Any = NestingLeaf()
    for _ in 0..<hops { value = Optional<Any>.some(value) as Any }
    return value
}

/// A hand-written conversion that returns a prebuilt tree of `depth` containers.
private struct HandWrittenDeep: SnapshotValueConvertible {
    let depth: Int
    func toSnapshotValue() throws -> SnapshotValue { nestedSnapshot(depth) }
}

@StateNodeBuilder
private struct NestingTreeNode: StateNodeProtocol {
    @Sync(.broadcast) var tree: SnapshotValue = SnapshotValue.null
    init() {}
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

private let limit = NestingBudget.containerLimit

// MARK: - Tests

@Suite("A state conversion's nesting budget (#716)")
struct NestingBudgetTests {
    @Test("the limits are the provisional constants, and leave room for one hop a level")
    func limits() {
        #expect(NestingBudget.containerLimit == PayloadNesting.stateMaxDepth)
        #expect(NestingBudget.hopLimit == PayloadNesting.stateMaxHops)
        #expect(PayloadNesting.stateMaxHops >= PayloadNesting.stateMaxDepth, "Optional<Node> at every level")
        #expect(PayloadNesting.stateMaxDepth < PayloadNesting.serverFrameMaxDepth)
    }

    @Test("entering a container and hopping each spend their own count, and throw when it's spent")
    func budgetCounts() throws {
        let one = NestingBudget(containers: 1, hops: 1)
        let inner = try one.enteringContainer()
        #expect(inner.containersLeft == 0 && inner.hopsLeft == 1)
        expectRefusal(.containers, limit: 1) { _ = try inner.enteringContainer() }
        let hopped = try one.hop()
        #expect(hopped.containersLeft == 1 && hopped.hopsLeft == 0)
        expectRefusal(.hops, limit: 1) { _ = try hopped.hop() }
    }

    @Test("make: a value exactly at the limit converts, and one container more is refused")
    func makeAtTheLimit() throws {
        _ = try SnapshotValue.make(from: nestedAny(limit))
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.make(from: nestedAny(limit + 1)) }
    }

    @Test("makeFull: a value exactly at the limit converts, and one container more is refused")
    func makeFullAtTheLimit() throws {
        _ = try SnapshotValue.makeFull(from: nestedAny(limit))
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.makeFull(from: nestedAny(limit + 1)) }
    }

    @Test("a prebuilt tree is checked at every short circuit, in make and makeFull",
          arguments: ["SnapshotValue", "StateSnapshot", "[SnapshotValue]", "[String: SnapshotValue]", "[PlayerID: SnapshotValue]"])
    func prebuiltTrees(kind: String) throws {
        // Each wraps the tree in the kind's own container, except `SnapshotValue` itself.
        func wrapped(_ depth: Int) -> Any {
            switch kind {
            case "SnapshotValue": nestedSnapshot(depth)
            case "StateSnapshot": StateSnapshot(values: ["a": nestedSnapshot(depth - 1)])
            case "[SnapshotValue]": [nestedSnapshot(depth - 1)]
            case "[String: SnapshotValue]": ["a": nestedSnapshot(depth - 1)]
            default: [PlayerID("p"): nestedSnapshot(depth - 1)]
            }
        }
        _ = try SnapshotValue.make(from: wrapped(limit))
        _ = try SnapshotValue.makeFull(from: wrapped(limit))
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.make(from: wrapped(limit + 1)) }
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.makeFull(from: wrapped(limit + 1)) }
    }

    @Test("an Optional unwrapped through Mirror spends a hop: within the hops it converts, one more is refused")
    func optionalHops() throws {
        // A small hop budget, so the test never recurses deep: an unwrap of a nested
        // `Optional<Any>` costs more stack than a container (each cast unwraps the rest again),
        // and 65 of them overflowed the debug pool stack on macOS. S0 sizes `stateMaxHops`.
        let budget = NestingBudget(containers: limit, hops: 4)
        _ = try SnapshotValue.make(from: optionalChain(4), budget: budget)
        _ = try SnapshotValue.makeFull(from: optionalChain(4), budget: budget)
        expectRefusal(.hops, limit: 4) { _ = try SnapshotValue.make(from: optionalChain(5), budget: budget) }
        expectRefusal(.hops, limit: 4) { _ = try SnapshotValue.makeFull(from: optionalChain(5), budget: budget) }
    }

    @Test("a hand-written conversion's result is checked against the budget at its value")
    func handWrittenConversion() throws {
        _ = try SnapshotValue.make(from: HandWrittenDeep(depth: limit))
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.make(from: HandWrittenDeep(depth: limit + 1)) }
        // Inside a map, the map's object is one container above it.
        expectRefusal(.containers, limit: limit) { _ = try SnapshotValue.make(from: ["a": HandWrittenDeep(depth: limit)] as [String: SnapshotValueConvertible]) }
    }

    @Test("a node's budget-aware snapshot checks its fields within the budget it is given")
    func nodeBudget() throws {
        var node = NestingTreeNode()
        node.tree = nestedSnapshot(limit)
        _ = try node.snapshot(for: nil, dirtyFields: nil, budget: NestingBudget())
        _ = try node.fullStateSnapshot(budget: NestingBudget())
        node.tree = nestedSnapshot(limit + 1)
        expectRefusal(.containers, limit: limit) { _ = try node.snapshot(for: nil, dirtyFields: nil, budget: NestingBudget()) }
        expectRefusal(.containers, limit: limit) { _ = try node.broadcastSnapshot(dirtyFields: nil, budget: NestingBudget()) }
        expectRefusal(.containers, limit: limit) { _ = try node.fullStateSnapshot(budget: NestingBudget()) }
        expectRefusal(.containers, limit: limit) { _ = try node.snapshotForSync(playerIDs: [PlayerID("p")], dirtyFields: nil, budget: NestingBudget()) }
    }

    @Test("broadcastView spends one container for the node's object")
    func broadcastViewSpendsTheNode() throws {
        var node = NestingTreeNode()
        node.tree = nestedSnapshot(1)
        _ = try SnapshotValue.broadcastView(of: node, budget: NestingBudget(containers: 2, hops: 1))
        expectRefusal(.containers, limit: 1) { _ = try SnapshotValue.broadcastView(of: node, budget: NestingBudget(containers: 1, hops: 1)) }
    }

    @Test("a value far past the limit is refused before the conversion recurses deep (exit test)")
    func farPastTheLimitIsRefused() async {
        // With the container guard removed this overflows the child's stack: a mutant for the
        // Linux host.
        await #expect(processExitsWith: .success) {
            let deep = nestedAny(100_000)
            do {
                _ = try SnapshotValue.make(from: deep)
                exit(1)
            } catch let error {
                // Exit before `deep` is released: its release recurses once per level (§3.1).
                exit(isNestingRefusal(error, .containers, limit: NestingBudget.containerLimit) ? 0 : 2)
            }
        }
    }

    @Test("a refused tree just past the limit is released after its refusal (exit test)")
    func refusedTreeIsReleased() async {
        await #expect(processExitsWith: .success) {
            var deep: SnapshotValue? = nestedSnapshot(NestingBudget.containerLimit + 1)
            guard (try? SnapshotValue.make(from: deep as Any)) == nil else { exit(1) }
            deep = nil
            _ = deep
        }
    }
}
