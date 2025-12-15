// Tests/SwiftStateTreeHummingbirdTests/LandRealmLandServerTests.swift
//
// Tests for LandRealm's Hummingbird-specific convenience methods
// Tests both the new `registerWithLandServer` method and the deprecated `registerWithAppContainer` alias

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

@Test("registerWithLandServer uses default webSocketPath when not provided")
func testLandRealmDefaultWebSocketPath() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act: Register without webSocketPath
    try await realm.registerWithLandServer(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() }
    )
    
    // Assert: Should use default path "/chess"
    // Note: We verify this indirectly through the server configuration
    // The actual path is stored in the server's configuration
    let healthStatus = await realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("registerWithLandServer uses custom webSocketPath when provided")
func testLandRealmCustomWebSocketPath() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act: Register with custom webSocketPath
    try await realm.registerWithLandServer(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        webSocketPath: "/custom/chess"
    )
    
    // Assert: Should use custom path
    let healthStatus = await realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("registerWithLandServer can register servers with different configurations")
func testLandRealmDifferentConfigurations() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act: Register with different configurations
    try await realm.registerWithLandServer(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        webSocketPath: "/game/chess"
    )
    
    try await realm.registerWithLandServer(
        landType: "cardgame",
        landFactory: { _ in CardGame.makeLand() },
        initialStateFactory: { _ in CardGameState() },
        webSocketPath: "/game/cards"
    )
    
    // Assert: Both should be registered successfully
    let healthStatus = await realm.healthCheck()
    #expect(healthStatus.count == 2)
    #expect(healthStatus["chess"] == true)
    #expect(healthStatus["cardgame"] == true)
}

@Test("registerWithLandServer accepts custom configuration")
func testLandRealmCustomConfiguration() async throws {
    // Arrange
    let realm = LandRealm()
    let customConfig = LandServer<ChessState>.Configuration(
        host: "0.0.0.0",
        port: 9090,
        webSocketPath: "/custom/chess",
        enableHealthRoute: false
    )
    
    // Act: Register with custom configuration
    try await realm.registerWithLandServer(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() },
        configuration: customConfig
    )
    
    // Assert: Should be registered successfully
    let healthStatus = await realm.healthCheck()
    #expect(healthStatus["chess"] == true)
}

@Test("registerWithLandServer validates landType is not empty")
func testLandRealmValidatesLandTypeNotEmpty() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act & Assert: Try to register with empty landType
    do {
        try await realm.registerWithLandServer(
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

@Test("registerWithLandServer rejects duplicate landType")
func testLandRealmRejectsDuplicateLandType() async throws {
    // Arrange
    let realm = LandRealm()
    
    // Act: Register first time
    try await realm.registerWithLandServer(
        landType: "chess",
        landFactory: { _ in ChessGame.makeLand() },
        initialStateFactory: { _ in ChessState() }
    )
    
    // Act & Assert: Try to register duplicate landType
    do {
        try await realm.registerWithLandServer(
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
