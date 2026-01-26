// Examples/GameDemo/Sources/EncodingBenchmark/BenchmarkState.swift
//
// Benchmark state definitions for encoding performance testing.

import Foundation
import SwiftStateTree

// MARK: - Benchmark State

/// A simplified state for benchmarking, similar to the structure in SwiftStateTreeBenchmarks
@StateNodeBuilder
struct BenchmarkPlayerState: StateNodeProtocol {
    @Sync(.broadcast)
    var posX: Double = 0.0
    @Sync(.broadcast)
    var posY: Double = 0.0
    @Sync(.broadcast)
    var health: Int = 100
    @Sync(.broadcast)
    var weaponLevel: Int = 0
    @Sync(.broadcast)
    var resources: Int = 0
    init() {}
}

@StateNodeBuilder
struct BenchmarkState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: BenchmarkPlayerState] = [:]
    @Sync(.broadcast)
    var score: Int = 0
    @Sync(.broadcast)
    var monsterCount: Int = 0
    @Sync(.serverOnly)
    var tickCount: Int = 0
    init() {}
}

// MARK: - Benchmark Action

@Payload
struct BenchmarkMutateAction: ActionPayload {
    typealias Response = BenchmarkMutateResponse
    let iteration: Int
    init(iteration: Int) {
        self.iteration = iteration
    }
}

@Payload
struct BenchmarkMutateResponse: ResponsePayload {
    let applied: Bool
    init(applied: Bool) {
        self.applied = applied
    }
}
