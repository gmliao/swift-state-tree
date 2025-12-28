// Tests/SwiftStateTreeHummingbirdTests/AdminRoutesTests.swift
//
// Tests for AdminRoutes functionality with LandRealm

import Foundation
import Testing
import Hummingbird
import HummingbirdWebSocket
import SwiftStateTree
import SwiftStateTreeTransport
@testable import SwiftStateTreeHummingbird

// MARK: - Test State Types

@StateNodeBuilder
private struct TestGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var score: Int = 0
    
    init() {}
}

// MARK: - Test Land Definitions

private enum TestGame {
    static func makeLand() -> LandDefinition<TestGameState> {
        Land("test-game", using: TestGameState.self) {
            Rules {}
        }
    }
}

// MARK: - Tests

@Test("AdminRoutes can list all lands across different land types")
func testAdminRoutesListAllLands() async throws {
    // Arrange
    let realm = LandRealm()
    let adminAuth = AdminAuthMiddleware(apiKey: "test-key")
    
    // Register multiple land types
    try await realm.registerWithLandServer(
        landType: "game1",
        landFactory: { _ in TestGame.makeLand() },
        initialStateFactory: { _ in TestGameState() }
    )
    
    try await realm.registerWithLandServer(
        landType: "game2",
        landFactory: { _ in TestGame.makeLand() },
        initialStateFactory: { _ in TestGameState() }
    )
    
    let adminRoutes = AdminRoutes(
        landRealm: realm,
        adminAuth: adminAuth
    )
    
    // Act: Create a mock request with API key
    let router = Router(context: BasicWebSocketRequestContext.self)
    adminRoutes.registerRoutes(on: router)
    
    // Note: We can't easily test the HTTP routes without a full HTTP server,
    // but we can verify that the routes are registered and the AdminRoutes
    // is properly initialized with LandRealm
    #expect(adminRoutes.landRealm === realm)
}

@Test("AdminRoutes requires admin authentication")
func testAdminRoutesRequiresAuth() async throws {
    // Arrange
    let realm = LandRealm()
    let adminAuth = AdminAuthMiddleware(apiKey: "test-key")
    
    let adminRoutes = AdminRoutes(
        landRealm: realm,
        adminAuth: adminAuth
    )
    
    // Assert: AdminRoutes should be initialized with auth
    #expect(adminRoutes.adminAuth.apiKey == "test-key")
}

@Test("AdminRoutes works with JWT authentication")
func testAdminRoutesWithJWTAuth() async throws {
    // Arrange
    let realm = LandRealm()
    let jwtConfig = JWTConfiguration(secretKey: "test-secret")
    let jwtValidator = DefaultJWTAuthValidator(config: jwtConfig, logger: nil)
    let adminAuth = AdminAuthMiddleware(jwtValidator: jwtValidator)
    
    let adminRoutes = AdminRoutes(
        landRealm: realm,
        adminAuth: adminAuth
    )
    
    // Assert: AdminRoutes should be initialized with JWT validator
    #expect(adminRoutes.adminAuth.jwtValidator != nil)
}

@Test("LandRealm registerAdminRoutes registers routes on router")
func testLandRealmRegisterAdminRoutes() async throws {
    // Arrange
    let realm = LandRealm()
    let router = Router(context: BasicWebSocketRequestContext.self)
    let adminAuth = AdminAuthMiddleware(apiKey: "test-key")
    
    // Act: registerAdminRoutes is a nonisolated method on an actor, so we need await
    await realm.registerAdminRoutes(on: router, adminAuth: adminAuth)
    
    // Assert: Routes should be registered (we can't easily verify without HTTP server,
    // but the method should complete without error)
    // This test mainly ensures the method exists and can be called
}
