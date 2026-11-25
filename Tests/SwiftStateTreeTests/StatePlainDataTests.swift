// Tests/SwiftStateTreeTests/StatePlainDataTests.swift
//
// A land's State is PlainData: `StateNodeProtocol` refines it, and the wrappers that hold a
// field's value are PlainData themselves, so a state node's own check can read through them.

import SwiftStateTreeDeterministicMath
import Testing
@testable import SwiftStateTree

/// Compiles only when `T` is PlainData.
private func plainData<T: PlainData>(_: T.Type) -> Bool { true }

@StateNodeBuilder
private struct StatePlainDataNode: StateNodeProtocol {
    @Sync(.broadcast) var count: Int = 0
    @Internal var cache: [String: Int] = [:]
}

@Suite("State is PlainData")
struct StatePlainDataTests {
    @Test("Sync and Internal are PlainData, and so are a state node and a DeterministicMath value")
    func wrappersAndNodesArePlainData() {
        #expect(plainData(Sync<Int>.self))
        #expect(plainData(Internal<[String: Int]>.self))
        #expect(plainData(StatePlainDataNode.self))
        #expect(plainData(Position2.self))
    }
}
