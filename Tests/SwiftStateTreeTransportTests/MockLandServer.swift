// Tests/SwiftStateTreeTransportTests/MockLandServer.swift
//
// Mock implementation of LandServer for testing LandRealm

import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import Atomics

/// Mock implementation of LandServerProtocol for testing purposes.
///
/// This mock allows testing LandRealm's core functionality without depending on
/// any specific HTTP framework implementation (e.g., Hummingbird).
///
/// Note: This is a class to allow mutable state tracking (call counts).
/// The state is protected by actor isolation when used with LandRealm.
final class MockLandServer<State: StateNodeProtocol>: @unchecked Sendable, LandServerProtocol {
    let stateType: State.Type
    var shouldFailRun: Bool = false
    var shouldFailShutdown: Bool = false
    var healthStatus: Bool = true
    var mockLands: [LandID] = []
    var mockLandStats: [LandID: LandStats] = [:]
    private let _runCallCount = ManagedAtomic<Int>(0)
    private let _shutdownCallCount = ManagedAtomic<Int>(0)
    private let _healthCheckCallCount = ManagedAtomic<Int>(0)
    private let _listLandsCallCount = ManagedAtomic<Int>(0)
    private let _getLandStatsCallCount = ManagedAtomic<Int>(0)
    private let _removeLandCallCount = ManagedAtomic<Int>(0)
    
    /// Error to throw when run fails
    var runError: Error?
    
    /// Error to throw when shutdown fails
    var shutdownError: Error?
    
    var runCallCount: Int {
        _runCallCount.load(ordering: .relaxed)
    }
    
    var shutdownCallCount: Int {
        _shutdownCallCount.load(ordering: .relaxed)
    }
    
    var healthCheckCallCount: Int {
        _healthCheckCallCount.load(ordering: .relaxed)
    }
    
    var listLandsCallCount: Int {
        _listLandsCallCount.load(ordering: .relaxed)
    }
    
    var getLandStatsCallCount: Int {
        _getLandStatsCallCount.load(ordering: .relaxed)
    }
    
    var removeLandCallCount: Int {
        _removeLandCallCount.load(ordering: .relaxed)
    }
    
    init(
        stateType: State.Type,
        shouldFailRun: Bool = false,
        shouldFailShutdown: Bool = false,
        healthStatus: Bool = true,
        runError: Error? = nil,
        shutdownError: Error? = nil
    ) {
        self.stateType = stateType
        self.shouldFailRun = shouldFailRun
        self.shouldFailShutdown = shouldFailShutdown
        self.healthStatus = healthStatus
        self.runError = runError
        self.shutdownError = shutdownError
    }
    
    func run() async throws {
        _runCallCount.wrappingIncrement(ordering: .relaxed)
        if shouldFailRun {
            throw runError ?? MockLandServerError.runFailed
        }
        // Simulate server running
        try await Task.sleep(nanoseconds: 1_000_000) // 1ms
    }
    
    func shutdown() async throws {
        _shutdownCallCount.wrappingIncrement(ordering: .relaxed)
        if shouldFailShutdown {
            throw shutdownError ?? MockLandServerError.shutdownFailed
        }
        // Simulate graceful shutdown
        try await Task.sleep(nanoseconds: 500_000) // 0.5ms
    }
    
    func healthCheck() async -> Bool {
        _healthCheckCallCount.wrappingIncrement(ordering: .relaxed)
        return healthStatus
    }
    
    func listLands() async -> [LandID] {
        _listLandsCallCount.wrappingIncrement(ordering: .relaxed)
        return mockLands
    }
    
    func getLandStats(landID: LandID) async -> LandStats? {
        _getLandStatsCallCount.wrappingIncrement(ordering: .relaxed)
        return mockLandStats[landID]
    }
    
    func removeLand(landID: LandID) async {
        _removeLandCallCount.wrappingIncrement(ordering: .relaxed)
        mockLands.removeAll { $0 == landID }
        mockLandStats.removeValue(forKey: landID)
    }
}

/// Errors that can be thrown by MockLandServer
enum MockLandServerError: Error, Sendable {
    case runFailed
    case shutdownFailed
}
