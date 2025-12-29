// Tests/SwiftStateTreeHummingbirdTests/LandHostRegistrationTests.swift
//
// Tests for LandHost registration functionality.
// Tests use LandHost.register() to register land types with different configurations.

import Foundation
import Testing
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

// MARK: - Test State Types

@StateNodeBuilder
private struct ChessState: StateNodeProtocol {
    @Sync(.broadcast)
    var board: [[String]] = Array(repeating: Array(repeating: "", count: 8), count: 8)
    
    init() {}
}

@StateNodeBuilder
private struct CardGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var deck: [String] = []
    
    @Sync(.broadcast)
    var players: [PlayerID: [String]] = [:]
    
    init() {}
}

// MARK: - Test Land Definitions

private enum ChessGame {
    static func makeLand() -> LandDefinition<ChessState> {
        Land("chess", using: ChessState.self) {
            Rules {}
        }
    }
}

private enum CardGame {
    static func makeLand() -> LandDefinition<CardGameState> {
        Land("cardgame", using: CardGameState.self) {
            Rules {}
        }
    }
}

// MARK: - Tests

@Test("LandHost uses default webSocketPath when not provided")
func testLandHostDefaultWebSocketPath() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    
    // Act: Register without webSocketPath
    try await host.register(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() }
    )
    
    // Assert: Should be registered successfully
    let healthStatus = await host.realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("LandHost uses custom webSocketPath when provided")
func testLandHostCustomWebSocketPath() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    
    // Act: Register with custom webSocketPath
    try await host.register(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        webSocketPath: "/custom/chess"
    )
    
    // Assert: Should be registered successfully
    let healthStatus = await host.realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("LandHost can register servers with different configurations")
func testLandHostDifferentConfigurations() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    
    // Act: Register with different configurations
    try await host.register(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        webSocketPath: "/game/chess"
    )
    
    try await host.register(
        landType: "cardgame",
        landFactory: { _ in CardGame.makeLand() },
        initialStateFactory: { _ in CardGameState() },
        webSocketPath: "/game/cards"
    )
    
    // Assert: Both should be registered successfully
    let healthStatus = await host.realm.healthCheck()
    #expect(healthStatus.count == 2)
    #expect(healthStatus["chess"] == true)
    #expect(healthStatus["cardgame"] == true)
}

@Test("LandHost accepts custom configuration")
func testLandHostCustomConfiguration() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    let customConfig = LandServerConfiguration()
    
    // Act: Register with custom configuration
    try await host.register(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        configuration: customConfig
    )
    
    // Assert: Should be registered successfully
    let healthStatus = await host.realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("LandHost validates landType is not empty")
func testLandHostValidatesLandTypeNotEmpty() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    
    // Act & Assert: Try to register with empty landType
    do {
        try await host.register(
            landType: "",
            landFactory: { _ in ChessGame.makeLand() },
            initialStateFactory: { _ in ChessState() }
        )
        Issue.record("Expected LandRealmError.invalidLandType to be thrown")
    } catch LandRealmError.invalidLandType {
        // Expected
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}

@Test("LandHost rejects duplicate landType")
func testLandHostRejectsDuplicateLandType() async throws {
    // Arrange
    var host = LandHost(configuration: LandHost.HostConfiguration(
        enableHealthRoute: false,
        logStartupBanner: false
    ))
    
    // Act: Register first time
    try await host.register(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() }
    )
    
    // Act & Assert: Try to register duplicate landType
    do {
        try await host.register(
            landType: "chess",
            landFactory: { _ in ChessGame.makeLand() },
            initialStateFactory: { _ in ChessState() }
        )
        Issue.record("Expected LandRealmError.duplicateLandType to be thrown")
    } catch LandRealmError.duplicateLandType(let landType) {
        #expect(landType == "chess")
    } catch {
        Issue.record("Unexpected error type: \(error)")
    }
}
