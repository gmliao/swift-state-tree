// Tests/SwiftStateTreeTests/StatePlainDataTests.swift
//
// A land's State is PlainData: `StateNodeProtocol` refines it, and the wrappers that hold a
// field's value are PlainData themselves, so a state node's own check can read through them.

import SwiftStateTreeDeterministicMath
import Testing
@testable import SwiftStateTree

/// Compiles only when `T` is PlainData.
private func plainData<T: PlainData>(_: T.Type) -> Bool { true }

/// Compiles only while `StateProtocol` refines `PlainData`.
private func stateIsPlainData<T: StateProtocol>(_: T.Type) -> Bool { plainData(T.self) }

@SnapshotConvertible
private struct StatePlainDataValue: StateProtocol, Equatable {
    var n: Int = 0
}

/// An observed field is stored, so it is marked and synced like any other.
@StateNodeBuilder
private struct StatePlainDataObservedNode: StateNodeProtocol {
    @Sync(.broadcast) var count: Int = 0 {
        didSet {}
    }
}

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
        #expect(stateIsPlainData(StatePlainDataValue.self))
    }

    @Test("An observed @Sync field is synced")
    func observedFieldIsSynced() {
        #expect(StatePlainDataObservedNode().getSyncFields().map(\.name) == ["count"])
    }
}
