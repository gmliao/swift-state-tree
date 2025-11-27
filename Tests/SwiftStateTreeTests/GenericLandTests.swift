import Foundation
import Testing
@testable import SwiftStateTree

// MARK: - Test Types

// We use TestLandState from LandDSLTests.swift

private enum MyClientEvents: ClientEventPayload {
    case playerReady(PlayerID)
    case heartbeat(Date)
}

private enum MyServerEvents: ServerEventPayload {
    case stateUpdate(StateSnapshot)
    case gameEvent(String)
}

private enum GameActionResponse: Codable, Sendable {
    case joinResult(JoinResponse)
    case pong
}

private enum GameAction: ActionPayload {
    typealias Response = GameActionResponse
    case join(playerID: PlayerID)
    case ping
}

// MARK: - Tests

@Test("Generic Land definition builds expected nodes")
func testGenericLandDefinition() async {
    let land = Land(
        "test-land",
        using: TestLandState.self,
        clientEvents: MyClientEvents.self,
        serverEvents: MyServerEvents.self,
        actions: GameAction.self
    ) {
        Config {
            // Empty config or components
            MaxPlayers(10)
        }

        AllowedClientEvents {
            MyClientEvents.self
        }

        Action(GameAction.self) { (state: inout TestLandState, action: GameAction, ctx: LandContext) in
            switch action {
            case .join(playerID: _):
                return .joinResult(JoinResponse(landID: ctx.landID))
            case .ping:
                return .pong
            }
        }

        On(MyClientEvents.self) { (state: inout TestLandState, event: MyClientEvents, ctx: LandContext) in
            switch event {
            case .playerReady(let id):
                print("Player ready: \(id)")
            case .heartbeat(let date):
                print("Heartbeat: \(date)")
            }
        }
    }

    #expect(land.id == "test-land")
    #expect(land.stateType == TestLandState.self)
    #expect(land.clientEventType == MyClientEvents.self)
    #expect(land.serverEventType == MyServerEvents.self)
    #expect(land.actionType == GameAction.self)

    // Verify nodes are created
    #expect(!land.nodes.isEmpty)

    var hasConfig = false
    var hasAction = false
    var hasEvent = false
    var hasAllowedEvents = false

    for node in land.nodes {
        if node is ConfigNode { hasConfig = true }
        if node is ActionHandlerNode<TestLandState, GameAction> { hasAction = true }
        if node is OnEventNode<TestLandState, MyClientEvents> { hasEvent = true }
        if node is AllowedClientEventsNode { hasAllowedEvents = true }
    }

    #expect(hasConfig)
    #expect(hasAction)
    #expect(hasEvent)
    #expect(hasAllowedEvents)
}
