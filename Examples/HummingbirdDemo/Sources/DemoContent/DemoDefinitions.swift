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

// MARK: - Client Events

/// Chat event sent by a client.
@Payload
public struct ChatEvent: ClientEventPayload {
    public let message: String
    
    public init(message: String) {
        self.message = message
    }
}

/// Ping event sent by a client.
@Payload
public struct PingEvent: ClientEventPayload {
    public init() {}
}

// MARK: - Server Events

/// Welcome event sent to a player when they join.
@Payload
public struct WelcomeEvent: ServerEventPayload {
    public let message: String
    
    public init(message: String) {
        self.message = message
    }
}

/// Chat message event broadcast to all players.
@Payload
public struct ChatMessageEvent: ServerEventPayload {
    public let message: String
    public let from: String
    
    public init(message: String, from: String) {
        self.message = message
        self.from = from
    }
}

/// Pong event sent in response to a ping.
@Payload
public struct PongEvent: ServerEventPayload {
    public init() {}
}


// MARK: - Land Definition

public enum DemoGame {
    public static func makeLand() -> LandDefinition<DemoGameState> {
        Land(
            "demo-game",
            using: DemoGameState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(10)
            }
            
            ClientEvents {
                Register(ChatEvent.self)
                Register(PingEvent.self)
            }
            
            ServerEvents {
                Register(WelcomeEvent.self)
                Register(ChatMessageEvent.self)
                Register(PongEvent.self)
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
                    await ctx.sendEvent(
                        WelcomeEvent(message: "Welcome, Guest!"),
                        to: .session(ctx.sessionID)
                    )
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
                
                
                On(ChatEvent.self) { (state: inout DemoGameState, event: ChatEvent, ctx: LandContext) in
                    state.messageCount += 1
                    let playerName = state.players[ctx.playerID] ?? "Unknown"
                    await ctx.sendEvent(
                        ChatMessageEvent(message: event.message, from: playerName),
                        to: .all
                    )
                }
                
                On(PingEvent.self) { (state: inout DemoGameState, event: PingEvent, ctx: LandContext) in
                    await ctx.sendEvent(PongEvent(), to: .session(ctx.sessionID))
                }
            }
            
            Lifetime { (config: inout LifetimeConfig<DemoGameState>) in
                config.tickInterval = .seconds(1)
                config.tickHandler = { (state: inout DemoGameState, _: LandContext) in
                    // state.ticks += 1
                }
            }
        }
    }
}
