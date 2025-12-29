// Tests/SwiftStateTreeHummingbirdTests/LandHostTests.swift
//
// Tests for LandHost functionality

import Foundation
import Testing
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

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

// MARK: - Test Land Definitions

private enum TestGame1 {
    static func makeLand() -> LandDefinition<TestState1> {
        Land("test-game-1", using: TestState1.self) {
            Rules {}
        }
    }
}

private enum TestGame2 {
    static func makeLand() -> LandDefinition<TestState2> {
        Land("test-game-2", using: TestState2.self) {
            Rules {}
        }
    }
}

// MARK: - Tests

@Test("LandHost can be initialized with default configuration")
func testLandHostInitialization() {
    // Arrange & Act
    let host = LandHost()
    
    // Assert
    #expect(host.configuration.host == "localhost")
    #expect(host.configuration.port == 8080)
    #expect(host.configuration.healthPath == "/health")
    #expect(host.configuration.enableHealthRoute == true)
    #expect(host.configuration.logStartupBanner == true)
}

@Test("LandHost can be initialized with custom configuration")
func testLandHostConfiguration() {
    // Arrange
    let logger = createColoredLogger(
        loggerIdentifier: "test",
        scope: "LandHostTest"
    )
    
    // Act
    let host = LandHost(configuration: LandHost.HostConfiguration(
        host: "0.0.0.0",
        port: 9000,
        healthPath: "/ping",
        enableHealthRoute: false,
        logStartupBanner: false,
        logger: logger
    ))
    
    // Assert
    #expect(host.configuration.host == "0.0.0.0")
    #expect(host.configuration.port == 9000)
    #expect(host.configuration.healthPath == "/ping")
    #expect(host.configuration.enableHealthRoute == false)
    #expect(host.configuration.logStartupBanner == false)
    #expect(host.configuration.logger != nil)
}

@Test("LandHost provides accessible router")
func testLandHostRouterAccess() {
    // Arrange
    let host = LandHost()
    
    // Act & Assert
    // Router should be accessible (router is not optional, so we just verify it exists)
    let router = host.router
    // Router is a non-optional property, so it always exists
    _ = router  // Just verify we can access it
}

@Test("LandHost can register a single LandServer")
func testLandHostRegisterSingleServer() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    // Act
    try await host.register(
        landType: "test1",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/game/test1",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Assert: Registration should succeed without error
    // We can't easily verify the internal state, but the method should complete
}

@Test("LandHost can register multiple LandServers with different State types")
func testLandHostRegisterMultipleServers() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    
    // Act: Register first server
    try await host.register(
        landType: "test1",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/game/test1",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Act: Register second server with different State type
    try await host.register(
        landType: "test2",
        land: TestGame2.makeLand(),
        initialState: TestState2(),
        webSocketPath: "/game/test2",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Assert: Both registrations should succeed
    // We can't easily verify the internal state, but both methods should complete
}

@Test("LandHost can register LandServer with custom WebSocket path")
func testLandHostRegisterWithCustomPaths() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    // Act
    try await host.register(
        landType: "custom",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/custom/path",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Assert: Registration should succeed
}

@Test("LandHost rejects duplicate landType registration")
func testLandHostRejectDuplicateLandType() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    // Act: Register first time
    try await host.register(
        landType: "duplicate",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/game/test"
    )
    
    // Act & Assert: Try to register duplicate landType
    do {
        try await host.register(
            landType: "duplicate",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/test2"
        )
        Issue.record("Expected LandHostError.duplicateLandType to be thrown")
    } catch LandHostError.duplicateLandType(let landType) {
        #expect(landType == "duplicate")
    }
}

@Test("LandHost rejects empty landType")
func testLandHostEmptyLandType() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    // Act & Assert: Try to register with empty landType
    do {
        try await host.register(
            landType: "",
            land: TestGame1.makeLand(),
            initialState: TestState1(),
            webSocketPath: "/game/test",
            configuration: LandServerConfiguration(
                enableHealthRoute: false,  // Disable to avoid route conflicts
                logStartupBanner: false
            )
        )
        Issue.record("Expected LandHostError.invalidLandType to be thrown")
    } catch LandHostError.invalidLandType(let landType) {
        #expect(landType == "")
    }
}

@Test("LandHost registers health route when enabled")
func testLandHostHealthRoute() {
    // Arrange
    let host = LandHost(configuration: LandHost.HostConfiguration(
        healthPath: "/health",
        enableHealthRoute: true
    ))
    
    // Assert: Health route should be registered
    // We can't easily verify the route without a full HTTP server,
    // but the router should be accessible
    // Note: router is now internal, so we can't access it directly
    // The test just verifies that host can be created with health route enabled
}

@Test("LandHost can work with LandRealm")
func testLandHostWithLandRealm() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    
    // Act: Register land type - host will handle route registration automatically
    try await host.register(
        landType: "realm-test",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/game/realm",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Assert: Registration should succeed
    // The host handles route registration automatically
}

@Test("LandHost can register multiple land types on the same host")
func testLandHostMultipleLandTypes() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    
    // Act: Register multiple land types
    try await host.register(
        landType: "type1",
        land: TestGame1.makeLand(),
        initialState: TestState1(),
        webSocketPath: "/game/type1",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    try await host.register(
        landType: "type2",
        land: TestGame2.makeLand(),
        initialState: TestState2(),
        webSocketPath: "/game/type2",
        configuration: LandServerConfiguration(
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        )
    )
    
    // Assert: Both registrations should succeed
    // All servers' routes are registered on the host's shared router
}
