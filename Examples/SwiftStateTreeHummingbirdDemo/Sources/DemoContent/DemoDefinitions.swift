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

@GenerateLandEventHandlers
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
                /// CanJoin handler validates and determines the playerID for joining players.
                ///
                /// This handler receives:
                /// - `state`: Read-only current state (to check room capacity, etc.)
                /// - `session`: PlayerSession containing playerID, deviceID, and metadata
                /// - `ctx`: LandContext (temporary, playerID is "_pending" during validation)
                ///
                /// The handler can:
                /// - Return `.allow(playerID: ...)` to allow join with a specific PlayerID
                /// - Return `.deny(reason: ...)` to reject the join
                /// - Throw `JoinError` to reject with a specific error
                ///
                /// The PlayerID returned here will be used throughout the player's session.
                CanJoin { (state: DemoGameState, session: PlayerSession, ctx: LandContext) async throws in
                    // Check if room is full
                    guard state.players.count < 10 else {
                        throw JoinError.roomIsFull
                    }
                    
                    // Use playerID from PlayerSession as the PlayerID
                    // You can customize this logic (e.g., lookup user in database, validate permissions, etc.)
                    let playerID = PlayerID(session.playerID)
                    
                    // Optional: Log metadata for debugging
                    if let deviceID = session.deviceID {
                        print("Player joining: playerID=\(session.playerID), deviceID=\(deviceID)")
                    }
                    
                    return .allow(playerID: playerID)
                }
                
                OnJoin { (state: inout DemoGameState, ctx: LandContext) in
                    // Set initial player name as "Guest"
                    state.players[ctx.playerID] = "Guest"
                    await ctx.sendEvent(DemoServerEvents.welcome("Welcome, Guest!"), to: .session(ctx.sessionID))
                }
                
                OnLeave { (state: inout DemoGameState, ctx: LandContext) in
                    // Remove player from state
                    state.players.removeValue(forKey: ctx.playerID)
                    print("Player \(ctx.playerID) left")
                }
                
                Action(JoinAction.self) { (state: inout DemoGameState, action: JoinAction, ctx: LandContext) in
                    // Update player name
                    state.players[ctx.playerID] = action.name
                    await ctx.syncNow()
                    return JoinResult(playerID: ctx.playerID.rawValue, message: "Joined as \(action.name)")
                }
                
                
                DemoClientEvents.OnChat { (state: inout DemoGameState, message: String, ctx: LandContext) in
                    state.messageCount += 1
                    let playerName = state.players[ctx.playerID] ?? "Unknown"
                    await ctx.sendEvent(
                        DemoServerEvents.chatMessage(message, from: playerName),
                        to: .all
                    )
                }
                
                DemoClientEvents.OnPing { (state: inout DemoGameState, ctx: LandContext) in
                    await ctx.sendEvent(DemoServerEvents.pong, to: .session(ctx.sessionID))
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
