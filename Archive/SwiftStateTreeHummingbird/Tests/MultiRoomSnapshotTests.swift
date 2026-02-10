import Testing
import Foundation
import SwiftStateTree
import SwiftStateTreeTransport
import SwiftStateTreeHummingbird

@StateNodeBuilder
struct MultiRoomSnapshotTestState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
}

@Test("Multi-room server sends initial snapshot after join")
func testMultiRoomServerSendsInitialSnapshotAfterJoin() async throws {
    // Arrange
    typealias Server = LandServer<MultiRoomSnapshotTestState>
    
    let server = try await Server.create(
        configuration: LandServerConfiguration(
            allowGuestMode: true,
            allowAutoCreateOnJoin: true,
            // Use JSON format for this test (not opcode array) to decode StateUpdate
            transportEncoding: .json
        ),
        landFactory: { landID in
            Land(landID.landType, using: MultiRoomSnapshotTestState.self) {
                Rules {
                    OnJoin { (state: inout MultiRoomSnapshotTestState, ctx: LandContext) in
                        state.players[ctx.playerID] = "Joined"
                    }
                }
            }
        },
        initialStateFactory: { _ in
            MultiRoomSnapshotTestState()
        }
    )
    
    let transport = try #require(server.transport)
    _ = try #require(server.landRouter)
    
    let connection = RecordingWebSocketConnection()
    let sessionID = SessionID("sess-multiroom-1")
    
    // Act: Connect and send join request
    await transport.handleConnection(sessionID: sessionID, connection: connection, authInfo: nil as AuthenticatedInfo?)
    
    let joinMsg = TransportMessage.join(
        requestID: "req-join-1",
        landType: "demo-game",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let data = try JSONEncoder().encode(joinMsg)
    await transport.handleIncomingMessage(sessionID: sessionID, data: data)
    
    // Wait (with timeout) for async join processing and snapshot send
    let decoder = JSONDecoder()
    
    var sawJoinResponse = false
    var sawSnapshot = false
    let deadline = Date().addingTimeInterval(1.0)
    
    while Date() < deadline, !(sawJoinResponse && sawSnapshot) {
        let messages = await connection.recordedMessages()
        for msg in messages {
            if let transportMsg = try? decoder.decode(TransportMessage.self, from: msg) {
                if transportMsg.kind == .joinResponse {
                    sawJoinResponse = true
                }
                continue
            }
            // Check for StateUpdate (current format) - firstSync type
            if let stateUpdate = try? decoder.decode(StateUpdate.self, from: msg) {
                if case .firstSync = stateUpdate {
                    sawSnapshot = true
                }
            }
        }
        
        if !(sawJoinResponse && sawSnapshot) {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
    
    // Assert
    #expect(sawJoinResponse, "Expected a joinResponse message to be sent")
    #expect(sawSnapshot, "Expected an initial StateSnapshot message to be sent")
}
