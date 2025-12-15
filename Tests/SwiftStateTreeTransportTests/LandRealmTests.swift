// Tests/SwiftStateTreeTransportTests/LandRealmTests.swift
//
// Core functionality tests for LandRealm (framework-agnostic)

import Foundation
import Testing
import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State Types

@StateNodeBuilder
private struct TestState1: StateNodeProtocol {
    @Sync(.broadcast)
    var value: Int = 0
    
    init() {}
}

@StateNodeBuilder
private struct TestState2: StateNodeProtocol {
    @Sync(.broadcast)
    var name: String = ""
    
    init() {}
}

@StateNodeBuilder
private struct TestState3: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    init() {}
}

// MARK: - Tests

@Test("LandRealm can register different State types")
func testLandRealmRegistersDifferentStateTypes() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act: Register different State types using MockLandServer
    let server1 = MockLandServer(stateType: TestState1.self)
    let server2 = MockLandServer(stateType: TestState2.self)
    let server3 = MockLandServer(stateType: TestState3.self)
    
    try await realm.register(landType: "type1", server: server1)
    try await realm.register(landType: "type2", server: server2)
    try await realm.register(landType: "type3", server: server3)
    
    // Assert: All registrations should succeed
    let healthStatus = await realm.healthCheck()
    #expect(healthStatus.count == 3)
    #expect(healthStatus["type1"] == true)
    #expect(healthStatus["type2"] == true)
    #expect(healthStatus["type3"] == true)
    
    #expect(await realm.isRegistered(landType: "type1") == true)
    #expect(await realm.isRegistered(landType: "type2") == true)
    #expect(await realm.isRegistered(landType: "type3") == true)
    #expect(await realm.registeredLandTypeCount == 3)
}

@Test("LandRealm rejects duplicate landType registration")
func testLandRealmRejectsDuplicateLandType() async throws {
    // Arrange
    let realm = LandRealm()
    let server1 = MockLandServer(stateType: TestState1.self)
    let server2 = MockLandServer(stateType: TestState2.self)
    
    // Act: Register first time
    try await realm.register(landType: "duplicate", server: server1)
    
    // Act & Assert: Try to register duplicate landType
    do {
        try await realm.register(landType: "duplicate", server: server2)
        Issue.record("Expected LandRealmError.duplicateLandType to be thrown")
    } catch LandRealmError.duplicateLandType(let landType) {
        #expect(landType == "duplicate")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("LandRealm validates landType is not empty")
func testLandRealmValidatesLandTypeNotEmpty() async throws {
    // Arrange
    let realm = LandRealm()
    let server = MockLandServer(stateType: TestState1.self)
    
    // Act & Assert: Try to register with empty landType
    do {
        try await realm.register(landType: "", server: server)
        Issue.record("Expected LandRealmError.invalidLandType to be thrown")
    } catch LandRealmError.invalidLandType {
        // Expected
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("LandRealm provides health check for all registered servers")
func testLandRealmHealthCheck() async throws {
    // Arrange
    let realm = LandRealm()
    let healthyServer = MockLandServer(stateType: TestState1.self, healthStatus: true)
    let unhealthyServer = MockLandServer(stateType: TestState2.self, healthStatus: false)
    
    try await realm.register(landType: "healthy", server: healthyServer)
    try await realm.register(landType: "unhealthy", server: unhealthyServer)
    
    // Act
    let healthStatus = await realm.healthCheck()
    
    // Assert
    #expect(healthStatus.count == 2)
    #expect(healthStatus["healthy"] == true)
    #expect(healthStatus["unhealthy"] == false)
}

@Test("LandRealm gracefully shuts down all servers")
func testLandRealmShutdown() async throws {
    // Arrange
    let realm = LandRealm()
    let server1 = MockLandServer(stateType: TestState1.self)
    let server2 = MockLandServer(stateType: TestState2.self)
    
    try await realm.register(landType: "server1", server: server1)
    try await realm.register(landType: "server2", server: server2)
    
    // Act: Shutdown
    try await realm.shutdown()
    
    // Assert: Shutdown should complete without errors
    // Note: We can't verify the actual shutdown state, but we can verify
    // that shutdown was called on the servers
    #expect(server1.shutdownCallCount == 1)
    #expect(server2.shutdownCallCount == 1)
}

@Test("LandRealm handles shutdown when no servers are registered")
func testLandRealmShutdownWithNoServers() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act & Assert: Should not throw
    try await realm.shutdown()
}

@Test("LandRealm handles server failure during run")
func testLandRealmHandlesServerFailureDuringRun() async throws {
    // Arrange
    let realm = LandRealm()
    let failingServer = MockLandServer(
        stateType: TestState1.self,
        shouldFailRun: true,
        runError: MockLandServerError.runFailed
    )
    
    try await realm.register(landType: "failing", server: failingServer)
    
    // Act & Assert: Run should propagate the error
    do {
        try await realm.run()
        Issue.record("Expected error to be thrown")
    } catch LandRealmError.serverFailure(let landType, let underlying) {
        #expect(landType == "failing")
        #expect(underlying is MockLandServerError)
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("LandRealm handles server failure during shutdown gracefully")
func testLandRealmHandlesServerFailureDuringShutdown() async throws {
    // Arrange
    let realm = LandRealm()
    let failingServer = MockLandServer(
        stateType: TestState1.self,
        shouldFailShutdown: true,
        shutdownError: MockLandServerError.shutdownFailed
    )
    let normalServer = MockLandServer(stateType: TestState2.self)
    
    try await realm.register(landType: "failing", server: failingServer)
    try await realm.register(landType: "normal", server: normalServer)
    
    // Act: Shutdown should not throw even if one server fails
    // (errors are logged but don't prevent other servers from shutting down)
    try await realm.shutdown()
    
    // Assert: Both servers should have been called
    #expect(failingServer.shutdownCallCount == 1)
    #expect(normalServer.shutdownCallCount == 1)
}

@Test("LandRealm tracks registered land type count")
func testLandRealmTracksRegisteredCount() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act & Assert
    #expect(await realm.registeredLandTypeCount == 0)
    
    let server1 = MockLandServer(stateType: TestState1.self)
    try await realm.register(landType: "type1", server: server1)
    #expect(await realm.registeredLandTypeCount == 1)
    
    let server2 = MockLandServer(stateType: TestState2.self)
    try await realm.register(landType: "type2", server: server2)
    #expect(await realm.registeredLandTypeCount == 2)
}

@Test("LandRealm checks if land type is registered")
func testLandRealmChecksRegistration() async throws {
    // Arrange
    let realm = LandRealm()
    let server = MockLandServer(stateType: TestState1.self)
    
    // Act & Assert
    #expect(await realm.isRegistered(landType: "test") == false)
    
    try await realm.register(landType: "test", server: server)
    #expect(await realm.isRegistered(landType: "test") == true)
    #expect(await realm.isRegistered(landType: "other") == false)
}
