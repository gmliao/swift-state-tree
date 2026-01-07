import Testing
import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeHummingbird

@StateNodeBuilder
struct MultiRoomTwoPlayerTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var count: Int = 0
    
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Payload
private struct MultiRoomIncrementAction: ActionPayload {
    typealias Response = MultiRoomIncrementResponse
    let amount: Int
}

@Payload
private struct MultiRoomIncrementResponse: ResponsePayload {
    let newCount: Int
}

@Suite("Multi-room Two Player Tests")
struct MultiRoomTwoPlayerTests {
    @Test("Two players join same land instance, receive snapshot, and receive updates")
    func testTwoPlayersJoinSameLandAndReceiveUpdates() async throws {
        // Arrange
        typealias Server = LandServer<MultiRoomTwoPlayerTestState>
        
        let landFactory: @Sendable (LandID) -> LandDefinition<MultiRoomTwoPlayerTestState> = { landID in
            Land(landID.landType, using: MultiRoomTwoPlayerTestState.self) {
                Rules {
                    OnJoin { (state: inout MultiRoomTwoPlayerTestState, ctx: LandContext) in
                        state.players[ctx.playerID] = "Joined"
                    }
                    
                    OnLeave { (state: inout MultiRoomTwoPlayerTestState, ctx: LandContext) in
                        state.players.removeValue(forKey: ctx.playerID)
                    }
                    
                    HandleAction(MultiRoomIncrementAction.self) { (state: inout MultiRoomTwoPlayerTestState, action: MultiRoomIncrementAction, ctx: LandContext) in
                        state.count += action.amount
                        
                        return MultiRoomIncrementResponse(newCount: state.count)
                    }
                }
            }
        }
        
        let initialStateFactory: @Sendable (LandID) -> MultiRoomTwoPlayerTestState = { _ in
            MultiRoomTwoPlayerTestState()
        }
        
        let server = try await Server.create(
            configuration: LandServerConfiguration(
                allowGuestMode: true
            ),
            landFactory: landFactory,
            initialStateFactory: initialStateFactory
        )
        
        let landManager = try #require(server.landManager)
        let transport = try #require(server.transport)
        _ = try #require(server.landRouter)
        
        // Pre-create a deterministic land so both joins target the same room.
        let sharedLandID = LandID(landType: "demo-game", instanceId: "fixed")
        _ = await landManager.getOrCreateLand(
            landID: sharedLandID,
            definition: landFactory(sharedLandID),
            initialState: initialStateFactory(sharedLandID)
        )
        
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let connection1 = RecordingWebSocketConnection()
        let connection2 = RecordingWebSocketConnection()
        let session1 = SessionID("sess-two-player-1")
        let session2 = SessionID("sess-two-player-2")
        
        await transport.handleConnection(sessionID: session1, connection: connection1, authInfo: nil as AuthenticatedInfo?)
        await transport.handleConnection(sessionID: session2, connection: connection2, authInfo: nil as AuthenticatedInfo?)
        
        let join1 = TransportMessage.join(
            requestID: "join-1",
            landType: "demo-game",
            landInstanceId: "fixed",
            playerID: "player-1",
            deviceID: nil,
            metadata: nil
        )
        let join2 = TransportMessage.join(
            requestID: "join-2",
            landType: "demo-game",
            landInstanceId: "fixed",
            playerID: "player-2",
            deviceID: nil,
            metadata: nil
        )
        
        let joinData1 = try encoder.encode(join1)
        let joinData2 = try encoder.encode(join2)
        
        // Act: Join concurrently (simulates near-simultaneous joins).
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await transport.handleIncomingMessage(sessionID: session1, data: joinData1) }
            group.addTask { await transport.handleIncomingMessage(sessionID: session2, data: joinData2) }
        }
        
        // Assert: Both received joinResponse and initial snapshot.
        let messagesAfterJoin1 = await connection1.recordedMessages()
        let messagesAfterJoin2 = await connection2.recordedMessages()
        #expect(
            containsJoinSuccess(messages: messagesAfterJoin1, decoder: decoder, requestID: "join-1"),
            "Expected joinResponse(join-1) for session1; summary: \(summarize(messages: messagesAfterJoin1, decoder: decoder))"
        )
        #expect(
            containsJoinSuccess(messages: messagesAfterJoin2, decoder: decoder, requestID: "join-2"),
            "Expected joinResponse(join-2) for session2; summary: \(summarize(messages: messagesAfterJoin2, decoder: decoder))"
        )
        #expect(
            containsSnapshot(messages: messagesAfterJoin1, decoder: decoder),
            "Expected initial StateSnapshot for session1; summary: \(summarize(messages: messagesAfterJoin1, decoder: decoder))"
        )
        #expect(
            containsSnapshot(messages: messagesAfterJoin2, decoder: decoder),
            "Expected initial StateSnapshot for session2; summary: \(summarize(messages: messagesAfterJoin2, decoder: decoder))"
        )
        
        let sharedContainerAfterJoin = try #require(await landManager.getLand(landID: sharedLandID))
        #expect(await sharedContainerAfterJoin.transportAdapter.isJoined(sessionID: session1), "Expected session1 to be joined")
        #expect(await sharedContainerAfterJoin.transportAdapter.isJoined(sessionID: session2), "Expected session2 to be joined")
        
        // Act: Send an action from player 1.
        let actionPayload = MultiRoomIncrementAction(amount: 3)
        let payloadData = try encoder.encode(actionPayload)
        let actionEnvelope = ActionEnvelope(typeIdentifier: "MultiRoomIncrementAction", payload: payloadData)
        let actionRequest = TransportMessage.action(
            requestID: "action-1",
            action: actionEnvelope
        )
        let actionData = try encoder.encode(actionRequest)
        await transport.handleIncomingMessage(sessionID: session1, data: actionData)
        
        // Sync is not automatic after actions; trigger it explicitly.
        let sharedContainer = sharedContainerAfterJoin
        let stateAfterAction = await sharedContainer.keeper.currentState()
        #expect(stateAfterAction.count == 3, "Expected state.count to be updated by action")
        await sharedContainer.transportAdapter.syncNow()
        
        // Assert: Both connections receive a StateUpdate patch affecting "/count".
        let messagesAfterSync1 = await connection1.recordedMessages()
        let messagesAfterSync2 = await connection2.recordedMessages()
        #expect(
            containsPatch(messages: messagesAfterSync1, decoder: decoder, path: "/count"),
            "Expected StateUpdate patch for /count on session1; summary: \(summarize(messages: messagesAfterSync1, decoder: decoder))"
        )
        #expect(
            containsPatch(messages: messagesAfterSync2, decoder: decoder, path: "/count"),
            "Expected StateUpdate patch for /count on session2; summary: \(summarize(messages: messagesAfterSync2, decoder: decoder))"
        )
        
        // Act: Disconnect player 1.
        await transport.handleDisconnection(sessionID: session1)
        
        // Assert: Remaining player receives a patch removing player-1 from "/players".
        let messagesAfterDisconnect2 = await connection2.recordedMessages()
        #expect(
            containsPatch(messages: messagesAfterDisconnect2, decoder: decoder, path: "/players/player-1")
                || containsPatch(messages: messagesAfterDisconnect2, decoder: decoder, path: "/players"),
            "Expected StateUpdate patch affecting /players on session2; summary: \(summarize(messages: messagesAfterDisconnect2, decoder: decoder))"
        )
    }
}

// MARK: - Helpers

private func containsJoinSuccess(messages: [Data], decoder: JSONDecoder, requestID: String) -> Bool {
    for msg in messages {
        guard let transportMsg = try? decoder.decode(TransportMessage.self, from: msg) else { continue }
        guard transportMsg.kind == .joinResponse else { continue }
        guard case .joinResponse(let payload) = transportMsg.payload else { continue }
        if payload.requestID == requestID && payload.success == true {
            return true
        }
    }
    return false
}

private func containsSnapshot(messages: [Data], decoder: JSONDecoder) -> Bool {
    for msg in messages {
        if (try? decoder.decode(StateSnapshot.self, from: msg)) != nil {
            return true
        }
    }
    return false
}

private func containsPatch(messages: [Data], decoder: JSONDecoder, path: String) -> Bool {
    for msg in messages {
        guard let update = try? decoder.decode(StateUpdate.self, from: msg) else { continue }
        let patches: [StatePatch]
        switch update {
        case .noChange:
            continue
        case .firstSync(let p), .diff(let p):
            patches = p
        }
        if patches.contains(where: { $0.path == path || $0.path.hasPrefix(path + "/") }) {
            return true
        }
    }
    return false
}

private func summarize(messages: [Data], decoder: JSONDecoder) -> String {
    var joinResponses = 0
    var actionResponses = 0
    var errors = 0
    var snapshots = 0
    var stateUpdates = 0
    var patchPaths: Set<String> = []
    
    for msg in messages {
        if let transportMsg = try? decoder.decode(TransportMessage.self, from: msg) {
            switch transportMsg.kind {
            case .joinResponse:
                joinResponses += 1
            case .actionResponse:
                actionResponses += 1
            case .error:
                errors += 1
            default:
                break
            }
            continue
        }
        
        if let _ = try? decoder.decode(StateSnapshot.self, from: msg) {
            snapshots += 1
            continue
        }
        
        if let update = try? decoder.decode(StateUpdate.self, from: msg) {
            stateUpdates += 1
            switch update {
            case .noChange:
                break
            case .firstSync(let patches), .diff(let patches):
                for patch in patches {
                    patchPaths.insert(patch.path)
                }
            }
        }
    }
    
    let paths = patchPaths.sorted().joined(separator: ",")
    return "joinResponses=\(joinResponses), actionResponses=\(actionResponses), errors=\(errors), snapshots=\(snapshots), stateUpdates=\(stateUpdates), patchPaths=[\(paths)]"
}
