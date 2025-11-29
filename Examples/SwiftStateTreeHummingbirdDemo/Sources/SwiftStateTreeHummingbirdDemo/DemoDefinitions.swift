import SwiftStateTree

// MARK: - Demo State

@StateNodeBuilder
public struct DemoGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var messageCount: Int = 0
    
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}
}

// MARK: - Demo Actions

@Payload
public struct JoinAction: ActionPayload {
    public typealias Response = JoinResult
    public let name: String

    public init(name: String) {
        self.name = name
    }
}

public struct JoinResult: Codable, Sendable {
    public let playerID: String
    public let message: String

    public init(playerID: String, message: String) {
        self.playerID = playerID
        self.message = message
    }
}

// MARK: - Demo Events

public enum DemoClientEvents: ClientEventPayload, Hashable {
    case chat(String)
    case ping
}

public enum DemoServerEvents: ServerEventPayload {
    case welcome(String)
    case chatMessage(String, from: String)
    case pong
}

// MARK: - Land Definition

public enum DemoGame {
    public static func makeLand() -> LandDefinition<DemoGameState, DemoClientEvents, DemoServerEvents> {
        Land(
            "demo-game",
            using: DemoGameState.self,
            clientEvents: DemoClientEvents.self,
            serverEvents: DemoServerEvents.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(10)
            }
            
            Rules {
                OnJoin { (state: inout DemoGameState, ctx: LandContext) in
                    let playerName = state.players[ctx.playerID] ?? "Guest"
                    await ctx.sendEvent(DemoServerEvents.welcome("Welcome, \(playerName)!"), to: .session(ctx.sessionID))
                }
                
                OnLeave { (state: inout DemoGameState, ctx: LandContext) in
                    print("Player \(ctx.playerID) left")
                }
                
                Action(JoinAction.self) { (state: inout DemoGameState, action: JoinAction, ctx: LandContext) in
                    state.players[ctx.playerID] = action.name
                    await ctx.syncNow()
                    return JoinResult(playerID: ctx.playerID.rawValue, message: "Joined as \(action.name)")
                }
                
                On(DemoClientEvents.self) { (state: inout DemoGameState, event: DemoClientEvents, ctx: LandContext) in
                    switch event {
                    case .chat(let message):
                        state.messageCount += 1
                        let playerName = state.players[ctx.playerID] ?? "Unknown"
                        await ctx.sendEvent(
                            DemoServerEvents.chatMessage(message, from: playerName),
                            to: .all
                        )
                    case .ping:
                        await ctx.sendEvent(DemoServerEvents.pong, to: .session(ctx.sessionID))
                    }
                }
            }
            
            Lifetime { (config: inout LifetimeConfig<DemoGameState>) in
                config.tickInterval = .seconds(1)
                config.tickHandler = { (state: inout DemoGameState, _: LandContext) in
                    state.ticks += 1
                }
            }
        }
    }
}
