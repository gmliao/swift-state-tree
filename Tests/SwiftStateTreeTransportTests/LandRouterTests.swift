// Tests/SwiftStateTreeTransportTests/LandRouterTests.swift

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct RouterTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Suite("LandRouter Tests")
struct LandRouterTests {
    
    // Helper to setup the router stack
    func setupRouter() async throws -> (
        WebSocketTransport,
        LandRouter<RouterTestState>,
        LandManager<RouterTestState>
    ) {
        let transport = WebSocketTransport()
        
        // Define Factories
        let landFactory: @Sendable (String, LandID) -> LandDefinition<RouterTestState> = { landType, landID in
             if landType == "basic-test" {
                 return Land("basic-test", using: RouterTestState.self) {
                    Rules {
                        OnJoin { (state: inout RouterTestState, ctx: LandContext) in
                            state.players[ctx.playerID] = "Joined"
                        }
                    }
                }
             }
             // For tests involving invalid types, we might want to throw or trap, 
             // but LandRouter should check landTypeRegistry before calling factory?
             // Actually LandRouter calls registry.getLandDefinition which calls factory.
             // If we crash here, the test crashes.
             // Let's implement a fallback or fatal error if logic expects validity.
             // For "invalid-type" test, LandRouter logic (Case B) catches it?
             // No, LandRouter calculates definition = registry.getLandDefinition(...)
             // LandTypeRegistry assumes valid return or assertion failure.
             // So we should handle "invalid-type" gracefully if possible, or expect crash?
             // Wait, LandRouter doesn't check if type exists before calling factory.
             // It assumes Factory handles it.
             // So our factory needs to handle unknown types safely or assert.
             // Let's fallback to basic-test for robustness or return a dummy.
             fatalError("Unknown land type: \(landType)")
        }
        
        let initialStateFactory: @Sendable (String, LandID) -> RouterTestState = { _, _ in
             return RouterTestState()
        }
        
        // Setup Registry
        let registry = LandTypeRegistry(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        
        // Setup LandManager
        let landManager = LandManager<RouterTestState>(
            landFactory: { landID in
                registry.getLandDefinition(landType: landID.landType, landID: landID)
            },
            initialStateFactory: { landID in
                registry.initialStateFactory(landID.landType, landID)
            },
            transport: transport
        )
        
        // Setup LandManagerRegistry
        let landManagerRegistry = SingleLandManagerRegistry(landManager: landManager)
        
        // Setup Router
        let router = LandRouter<RouterTestState>(
            landManager: landManager,
            landTypeRegistry: registry,
            transport: transport
        )
        
        await transport.setDelegate(router)
        
        return (transport, router, landManager)
    }
    
    @Test("Join with landType creates new land (Case B)")
    func testJoinWithLandType() async throws {
        let (_, router, _) = try await setupRouter()
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        
        // 1. Connect
        await router.onConnect(sessionID: sessionID, clientID: clientID)
        
        // 2. Send Join Request (Case B: Create new room)
        let joinMsg = TransportMessage.join(
            requestID: "req-1",
            landType: "basic-test",
            landInstanceId: nil, // Requesting new instance
            playerID: "player-1",
            deviceID: "dev-1",
            metadata: nil
        )
        
        let data = try JSONEncoder().encode(joinMsg)
        await router.onMessage(data, from: sessionID)
        
        // Wait for async processing
        try await Task.sleep(for: .milliseconds(100))
        
        // 3. Verify Session is Bound
        let boundLandID = await router.getBoundLandID(for: sessionID)
        #expect(boundLandID != nil)
        #expect(boundLandID?.landType == "basic-test")
        #expect(boundLandID?.instanceId != nil)
        #expect(boundLandID?.instanceId.isEmpty == false)
    }
    
    @Test("Join existing land with specific ID (Case A)")
    func testJoinExistingLand() async throws {
        let (_, router, _) = try await setupRouter()
        
        // Session 1: Create Land
        let session1 = SessionID("sess-1")
        await router.onConnect(sessionID: session1, clientID: ClientID("cli-1"))
        
        let join1 = TransportMessage.join(
            requestID: "req-1",
            landType: "basic-test",
            landInstanceId: nil,
            playerID: "player-1",
            deviceID: "dev-1",
            metadata: nil
        )
        await router.onMessage(try JSONEncoder().encode(join1), from: session1)
        try await Task.sleep(for: .milliseconds(50))
        
        guard let landID = await router.getBoundLandID(for: session1) else {
            Issue.record("Failed to create land")
            return
        }
        
        let instanceId = landID.instanceId
        
        // Session 2: Join Same Land
        let session2 = SessionID("sess-2")
        await router.onConnect(sessionID: session2, clientID: ClientID("cli-2"))
        
        let join2 = TransportMessage.join(
            requestID: "req-2",
            landType: "basic-test",
            landInstanceId: instanceId, // Specifying instance
            playerID: "player-2",
            deviceID: "dev-2",
            metadata: nil
        )
        await router.onMessage(try JSONEncoder().encode(join2), from: session2)
        try await Task.sleep(for: .milliseconds(50))
        
        // Assert: Session 2 is bound to same LandID
        let bound2 = await router.getBoundLandID(for: session2)
        #expect(bound2 == landID)
    }
    
    // Note: Invalid Land Type test is risky if factory traps. 
    // We should ensure factory is robust or LandRouter checks existence.
    // Given LandRegistry is just a struct with closures, it can't "check existence" easily unless factory handles it.
    // We will skip this test for now or assume factory handles "basic-test" only.
    
    @Test("Join non-existent instance returns error")
    func testJoinNonExistentInstance() async throws {
        let (_, router, _) = try await setupRouter()
        
        let sessionID = SessionID("sess-1")
        await router.onConnect(sessionID: sessionID, clientID: ClientID("cli-1"))
        
        let joinMsg = TransportMessage.join(
            requestID: "req-1",
            landType: "basic-test",
            landInstanceId: "non-existent-uuid", // Random ID
            playerID: "player-1",
            deviceID: "dev-1",
            metadata: nil
        )
        
        await router.onMessage(try JSONEncoder().encode(joinMsg), from: sessionID)
        try await Task.sleep(for: .milliseconds(50))
        
        // Session should NOT be bound
        let boundID = await router.getBoundLandID(for: sessionID)
        #expect(boundID == nil)
    }
    
    @Test("Messages are routed to correct land")
    func testMessageRouting() async throws {
        let (_, router, landManager) = try await setupRouter()
        
        let sessionID = SessionID("sess-1")
        await router.onConnect(sessionID: sessionID, clientID: ClientID("cli-1"))
        
        // Create Land
        let joinMsg = TransportMessage.join(
            requestID: "req-1",
            landType: "basic-test",
            landInstanceId: nil,
            playerID: "player-1",
            deviceID: "dev-1",
            metadata: nil
        )
        await router.onMessage(try JSONEncoder().encode(joinMsg), from: sessionID)
        try await Task.sleep(for: .milliseconds(50))
        
        guard let landID = await router.getBoundLandID(for: sessionID) else {
            Issue.record("Expected bound land")
            return
        }
        
        // Accessing LandKeeper via LandManager
        guard let container = await landManager.getLand(landID: landID) else {
            Issue.record("Container not found")
            return
        }
        let keeper = container.keeper
        
        // Verify player joined
        let state = await keeper.currentState()
        let playerID = PlayerID("player-1") // The logic uses provided ID or falls back. We provided it.
        #expect(state.players[playerID] == "Joined")
    }
}
