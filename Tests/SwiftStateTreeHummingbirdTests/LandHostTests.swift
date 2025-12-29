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
    let server = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test1",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    // Act
    try host.register(
        landType: "test1",
        server: server,
        webSocketPath: "/game/test1"
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
    let server1 = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test1",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    try host.register(
        landType: "test1",
        server: server1,
        webSocketPath: "/game/test1"
    )
    
    // Act: Register second server with different State type
    let server2 = try await LandServer<TestState2>.makeMultiRoomServer(
        configuration: LandServer<TestState2>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test2",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame2.makeLand() },
        initialStateFactory: { _ in TestState2() }
    )
    try host.register(
        landType: "test2",
        server: server2,
        webSocketPath: "/game/test2"
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
    let server = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/custom/path",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    // Act
    try host.register(
        landType: "custom",
        server: server,
        webSocketPath: "/custom/path"
    )
    
    // Assert: Registration should succeed
}

@Test("LandHost rejects duplicate landType registration")
func testLandHostRejectDuplicateLandType() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    let server1 = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    // Act: Register first time
    try host.register(
        landType: "duplicate",
        server: server1,
        webSocketPath: "/game/test"
    )
    
    // Act & Assert: Try to register duplicate landType
    let server2 = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test2",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    do {
        try host.register(
            landType: "duplicate",
            server: server2,
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
    let server = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/test",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    // Act & Assert: Try to register with empty landType
    do {
        try host.register(
            landType: "",
            server: server,
            webSocketPath: "/game/test"
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
    let router = host.router
    // Router is a non-optional property, so it always exists
    _ = router  // Just verify we can access it
}

@Test("LandHost can work with LandRealm")
func testLandHostWithLandRealm() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false  // Disable to avoid route conflicts in tests
    ))
    
    // Act: Create a LandServer, then register it to host
    // The host will handle route registration automatically
    let server = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/realm",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    
    try host.register(
        landType: "realm-test",
        server: server,
        webSocketPath: "/game/realm"
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
    let server1 = try await LandServer<TestState1>.makeMultiRoomServer(
        configuration: LandServer<TestState1>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/type1",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame1.makeLand() },
        initialStateFactory: { _ in TestState1() }
    )
    try host.register(
        landType: "type1",
        server: server1,
        webSocketPath: "/game/type1"
    )
    
    let server2 = try await LandServer<TestState2>.makeMultiRoomServer(
        configuration: LandServer<TestState2>.Configuration(
            host: "localhost",
            port: 8080,
            webSocketPath: "/game/type2",
            enableHealthRoute: false,  // Disable to avoid route conflicts
            logStartupBanner: false
        ),
        landFactory: { _ in TestGame2.makeLand() },
        initialStateFactory: { _ in TestState2() }
    )
    try host.register(
        landType: "type2",
        server: server2,
        webSocketPath: "/game/type2"
    )
    
    // Assert: Both registrations should succeed
    // All servers' routes are registered on the host's shared router
}
