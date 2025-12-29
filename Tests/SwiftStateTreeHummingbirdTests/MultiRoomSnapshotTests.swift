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
    
    let server = try await Server.makeMultiRoomServer(
        configuration: .init(
            host: "localhost",
            port: 0,
            webSocketPath: "/game",
            enableHealthRoute: false,
            logStartupBanner: false,
            jwtConfig: nil,
            jwtValidator: nil,
            allowGuestMode: true
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
    await transport.handleConnection(sessionID: sessionID, connection: connection, authInfo: nil)
    
    let joinMsg = TransportMessage.join(
        requestID: "req-join-1",
        landType: "demo-game",
        landInstanceId: nil,
        playerID: nil,
        deviceID: nil,
        metadata: nil
    )
    let data = try encodeHummingbirdTransportMessage(joinMsg)
    await transport.handleIncomingMessage(sessionID: sessionID, data: data)
    
    // Wait (with timeout) for async join processing and snapshot send
    var sawJoinResponse = false
    var sawSnapshot = false
    let deadline = Date().addingTimeInterval(1.0)
    
    while Date() < deadline, !(sawJoinResponse && sawSnapshot) {
        let messages = await connection.recordedMessages()
        for msg in messages {
            if let transportMsg = try? decodeHummingbirdTransportMessage(TransportMessage.self, from: msg) {
                if transportMsg.kind == .joinResponse {
                    sawJoinResponse = true
                }
                continue
            }
            if (try? decodeHummingbirdTransportMessage(StateSnapshot.self, from: msg)) != nil {
                sawSnapshot = true
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
