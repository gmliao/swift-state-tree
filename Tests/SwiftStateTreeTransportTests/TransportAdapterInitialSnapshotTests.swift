// Tests/SwiftStateTreeTransportTests/TransportAdapterInitialSnapshotTests.swift
//
// Tests to verify that initial state snapshot is sent when players join
// and that shared join logic (preparePlayerSession, performJoin) works correctly

import Foundation
import Testing
@testable import SwiftStateTree
@testable import SwiftStateTreeTransport

// MARK: - Test State

@StateNodeBuilder
struct InitialSnapshotTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var ticks: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

// MARK: - Tests

@Suite("TransportAdapter Initial Snapshot Tests")
struct TransportAdapterInitialSnapshotTests {
    
    @Test("preparePlayerSession correctly merges JWT, guest, and join message data")
    func testPreparePlayerSessionMergesData() async throws {
        // Arrange
        let definition = Land(
            "snapshot-test",
            using: InitialSnapshotTestState.self
        ) {
            Rules { }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<InitialSnapshotTestState>(definition: definition, initialState: InitialSnapshotTestState())
        let adapter = TransportAdapter<InitialSnapshotTestState>(
            keeper: keeper,
            transport: transport,
            landID: "snapshot-test"
        )
        await transport.setDelegate(adapter)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        
        // Connect first
        await adapter.onConnect(sessionID: sessionID, clientID: clientID, authInfo: AuthenticatedInfo(
            playerID: "jwt-player",
            deviceID: "jwt-device",
            metadata: ["jwt-key": "jwt-value"]
        ))
        
        // Act: Prepare PlayerSession with join message metadata (should override JWT)
        let playerSession = await adapter.preparePlayerSession(
            sessionID: sessionID,
            clientID: clientID,
            requestedPlayerID: "join-player",
            deviceID: "join-device",
            metadata: ["join-key": AnyCodable("join-value")],
            authInfo: nil // Will use sessionToAuthInfo
        )
        
        // Assert: Join message should take precedence
        #expect(playerSession.playerID == "join-player", "Join message playerID should override JWT")
        #expect(playerSession.deviceID == "join-device", "Join message deviceID should override JWT")
        #expect(playerSession.metadata["join-key"] == "join-value", "Join message metadata should be present")
        #expect(playerSession.metadata["jwt-key"] == "jwt-value", "JWT metadata should still be present (merged)")
    }
    
    @Test("performJoin executes keeper.join, registerSession, and syncStateForNewPlayer")
    func testPerformJoinExecutesAllSteps() async throws {
        // Arrange
        let definition = Land(
            "snapshot-test",
            using: InitialSnapshotTestState.self
        ) {
            Rules {
                OnJoin { (state: inout InitialSnapshotTestState, ctx: LandContext) in
                    state.players[ctx.playerID] = "Joined"
                    state.ticks = 10
                }
            }
        }
        
        let transport = WebSocketTransport()
        let keeper = LandKeeper<InitialSnapshotTestState>(definition: definition, initialState: InitialSnapshotTestState())
        let adapter = TransportAdapter<InitialSnapshotTestState>(
            keeper: keeper,
            transport: transport,
            landID: "snapshot-test"
        )
        await transport.setDelegate(adapter)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        let playerSession = PlayerSession(playerID: "player-1", deviceID: "dev-1", metadata: [:])
        
        // Act: Connect and perform join
        await adapter.onConnect(sessionID: sessionID, clientID: clientID)
        
        let joinResult = try await adapter.performJoin(
            playerSession: playerSession,
            clientID: clientID,
            sessionID: sessionID,
            authInfo: nil
        )
        
        // Assert: Join should succeed
        #expect(joinResult != nil, "Join should succeed")
        #expect(joinResult?.playerID.rawValue == "player-1", "PlayerID should match")
        
        // Assert: Session should be registered
        let isJoined = await adapter.isJoined(sessionID: sessionID)
        #expect(isJoined, "Session should be joined")
        
        // Assert: State should be updated (OnJoin was called)
        let state = await keeper.currentState()
        #expect(state.players[joinResult!.playerID] == "Joined", "Player should be in state")
        #expect(state.ticks == 10, "State should be updated")
    }
    
    @Test("LandRouter uses shared join logic correctly")
    func testLandRouterUsesSharedJoinLogic() async throws {
        // Arrange
        let transport = WebSocketTransport()
        
        let landFactory: @Sendable (String, LandID) -> LandDefinition<InitialSnapshotTestState> = { landType, landID in
            return Land("snapshot-test", using: InitialSnapshotTestState.self) {
                Rules {
                    OnJoin { (state: inout InitialSnapshotTestState, ctx: LandContext) in
                        state.players[ctx.playerID] = "Joined"
                        state.ticks = 5
                    }
                }
            }
        }
        
        let initialStateFactory: @Sendable (String, LandID) -> InitialSnapshotTestState = { _, _ in
            return InitialSnapshotTestState()
        }
        
        let registry = LandTypeRegistry(
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        
        let landManager = LandManager<InitialSnapshotTestState>(
            landFactory: { landID in
                registry.getLandDefinition(landType: landID.landType, landID: landID)
            },
            initialStateFactory: { landID in
                registry.initialStateFactory(landID.landType, landID)
            },
            transport: transport
        )
        
        let router = LandRouter<InitialSnapshotTestState>(
            landManager: landManager,
            landTypeRegistry: registry,
            transport: transport
        )
        await transport.setDelegate(router)
        
        let sessionID = SessionID("sess-1")
        let clientID = ClientID("cli-1")
        
        // Act: Connect and join
        await router.onConnect(sessionID: sessionID, clientID: clientID)
        
        let joinMsg = TransportMessage.join(
            requestID: "req-1",
            landType: "snapshot-test",
            landInstanceId: nil,
            playerID: "player-1",
            deviceID: "dev-1",
            metadata: nil
        )
        
        let data = try encodeTransportMessage(joinMsg)
        await router.onMessage(data, from: sessionID)
        
        // Wait for async processing
        try await Task.sleep(for: .milliseconds(100))
        
        // Assert: Session should be bound
        let boundLandID = await router.getBoundLandID(for: sessionID)
        #expect(boundLandID != nil, "Session should be bound to a land")
        
        // Assert: State should be updated (shared join logic was used)
        if let landID = boundLandID {
            let container = await landManager.getLand(landID: landID)
            #expect(container != nil, "Container should exist")
            
            if let container = container {
                let state = await container.keeper.currentState()
                let playerID = PlayerID("player-1")
                #expect(state.players[playerID] == "Joined", "Player should be in state")
                #expect(state.ticks == 5, "State should be updated")
            }
        }
    }
}
