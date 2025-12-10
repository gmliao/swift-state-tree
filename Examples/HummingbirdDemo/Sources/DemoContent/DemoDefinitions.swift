import SwiftStateTree

// MARK: - Nested State Nodes

/// Player settings (nested in PlayerPrivateState)
@StateNodeBuilder
public struct PlayerSettings: StateNodeProtocol {
    @Sync(.broadcast)
    var theme: String = "default"
    
    @Sync(.broadcast)
    var soundEnabled: Bool = true
    
    public init() {}
}

/// Player private state node - per-player state that only the player can see
@StateNodeBuilder
public struct PlayerPrivateState: StateNodeProtocol {
    @Sync(.broadcast)
    var inventory: [String] = []
    
    @Sync(.broadcast)
    var gold: Int = 0
    
    @Sync(.broadcast)
    var experience: Int = 0
    
    @Sync(.broadcast)
    var level: Int = 1
    
    @Sync(.broadcast)
    var settings: PlayerSettings = PlayerSettings()
    
    public init() {}
}

// MARK: - Demo State

@StateNodeBuilder
public struct DemoGameState: StateNodeProtocol {
    @Sync(.broadcast)
    var players: [PlayerID: String] = [:]
    
    @Sync(.broadcast)
    var messageCount: Int = 0
    
    @Sync(.broadcast)
    var ticks: Int = 0
    
    // PerPlayer StateNode: each player can only see their own PlayerPrivateState
    @Sync(.perPlayerSlice())
    var playerPrivateStates: [PlayerID: PlayerPrivateState] = [:]
    
    // PerPlayer simple values: each player can only see their own score
    @Sync(.perPlayerSlice())
    var playerScores: [PlayerID: Int] = [:]
    
    // PerPlayer simple values: each player can only see their own items
    @Sync(.perPlayerSlice())
    var playerItems: [PlayerID: [String]] = [:]

    public init() {}
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

// MARK: - Actions

/// Get my private state action - query own private state
@Payload
public struct GetMyPrivateStateAction: ActionPayload {
    public typealias Response = PlayerPrivateStateResponse
    
    public init() {}
}

@Payload
public struct PlayerPrivateStateResponse: ResponsePayload {
    public let inventory: [String]
    public let gold: Int
    public let experience: Int
    public let level: Int
    public let settings: PlayerSettingsResponse
    
    public init(inventory: [String], gold: Int, experience: Int, level: Int, settings: PlayerSettingsResponse) {
        self.inventory = inventory
        self.gold = gold
        self.experience = experience
        self.level = level
        self.settings = settings
    }
}

@Payload
public struct PlayerSettingsResponse: ResponsePayload {
    public let theme: String
    public let soundEnabled: Bool
    
    public init(theme: String, soundEnabled: Bool) {
        self.theme = theme
        self.soundEnabled = soundEnabled
    }
}

/// Add gold action - add gold (modifies perPlayer StateNode)
@Payload
public struct AddGoldAction: ActionPayload {
    public typealias Response = AddGoldResponse
    
    public let amount: Int
    
    public init(amount: Int) {
        self.amount = amount
    }
}

@Payload
public struct AddGoldResponse: ResponsePayload {
    public let success: Bool
    public let newGold: Int
    public let newLevel: Int
    
    public init(success: Bool, newGold: Int, newLevel: Int) {
        self.success = success
        self.newGold = newGold
        self.newLevel = newLevel
    }
}

/// Update player settings action - update settings (modifies nested StateNode)
@Payload
public struct UpdateSettingsAction: ActionPayload {
    public typealias Response = UpdateSettingsResponse
    
    public let theme: String
    public let soundEnabled: Bool
    public let updateTheme: Bool
    public let updateSoundEnabled: Bool
    
    public init(theme: String = "", soundEnabled: Bool = true, updateTheme: Bool = false, updateSoundEnabled: Bool = false) {
        self.theme = theme
        self.soundEnabled = soundEnabled
        self.updateTheme = updateTheme
        self.updateSoundEnabled = updateSoundEnabled
    }
}

@Payload
public struct UpdateSettingsResponse: ResponsePayload {
    public let success: Bool
    public let settings: PlayerSettingsResponse
    
    public init(success: Bool, settings: PlayerSettingsResponse) {
        self.success = success
        self.settings = settings
    }
}

/// Update score action - update score (modifies perPlayer simple value)
@Payload
public struct UpdateScoreAction: ActionPayload {
    public typealias Response = UpdateScoreResponse
    
    public let points: Int
    
    public init(points: Int) {
        self.points = points
    }
}

@Payload
public struct UpdateScoreResponse: ResponsePayload {
    public let success: Bool
    public let newScore: Int
    public let newLevel: Int
    
    public init(success: Bool, newScore: Int, newLevel: Int) {
        self.success = success
        self.newScore = newScore
        self.newLevel = newLevel
    }
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
                    // Determine player name from JWT metadata (username) or default to "Guest"
                    // JWT payload custom fields (username, schoolid, etc.) are available in ctx.metadata
                    let playerName: String
                    if let username = ctx.metadata["username"], !username.isEmpty {
                        playerName = username
                    } else if ctx.metadata["isGuest"] == "true" {
                        // Guest user (no JWT token provided)
                        playerName = "Guest"
                    } else {
                        // Authenticated user but no username in JWT payload
                        playerName = ctx.playerID.rawValue
                    }
                    
                    state.players[ctx.playerID] = playerName
                    
                    // Initialize perPlayer StateNode
                    state.playerPrivateStates[ctx.playerID] = PlayerPrivateState()
                    
                    // Initialize perPlayer simple values
                    state.playerScores[ctx.playerID] = 0
                    state.playerItems[ctx.playerID] = []
                }
                
                OnLeave { (state: inout DemoGameState, ctx: LandContext) in
                    // Remove player from all state dictionaries
                    state.players.removeValue(forKey: ctx.playerID)
                    state.playerPrivateStates.removeValue(forKey: ctx.playerID)
                    state.playerScores.removeValue(forKey: ctx.playerID)
                    state.playerItems.removeValue(forKey: ctx.playerID)
                    print("Player \(ctx.playerID) left - cleaned up all state")
                }
                
                HandleEvent(ChatEvent.self) { (state: inout DemoGameState, event: ChatEvent, ctx: LandContext) in
                    state.messageCount += 1
                    let playerName = state.players[ctx.playerID] ?? "Unknown"
                    await ctx.sendEvent(
                        ChatMessageEvent(message: event.message, from: playerName),
                        to: .all
                    )
                }
                
                HandleEvent(PingEvent.self) { (state: inout DemoGameState, event: PingEvent, ctx: LandContext) in
                    await ctx.sendEvent(PongEvent(), to: .session(ctx.sessionID))
                }
                
                // MARK: - Action Handlers
                
                /// GetMyPrivateState action handler
                HandleAction(GetMyPrivateStateAction.self) { (state: inout DemoGameState, action: GetMyPrivateStateAction, ctx: LandContext) async throws -> PlayerPrivateStateResponse in
                    // Ensure private state exists
                    if state.playerPrivateStates[ctx.playerID] == nil {
                        state.playerPrivateStates[ctx.playerID] = PlayerPrivateState()
                    }
                    
                    let privateState = state.playerPrivateStates[ctx.playerID]!
                    return PlayerPrivateStateResponse(
                        inventory: privateState.inventory,
                        gold: privateState.gold,
                        experience: privateState.experience,
                        level: privateState.level,
                        settings: PlayerSettingsResponse(
                            theme: privateState.settings.theme,
                            soundEnabled: privateState.settings.soundEnabled
                        )
                    )
                }
                
                /// AddGold action handler - modifies perPlayer StateNode
                HandleAction(AddGoldAction.self) { (state: inout DemoGameState, action: AddGoldAction, ctx: LandContext) async throws -> AddGoldResponse in
                    // Ensure private state exists
                    if state.playerPrivateStates[ctx.playerID] == nil {
                        state.playerPrivateStates[ctx.playerID] = PlayerPrivateState()
                    }
                    
                    // Modify nested StateNode - this will trigger perPlayer StateNode sync
                    var privateState = state.playerPrivateStates[ctx.playerID]!
                    privateState.gold += action.amount
                    
                    // Calculate level (level up every 100 gold)
                    let newLevel = (privateState.gold / 100) + 1
                    privateState.level = newLevel
                    
                    // Update back to state
                    state.playerPrivateStates[ctx.playerID] = privateState
                    
                    return AddGoldResponse(
                        success: true,
                        newGold: privateState.gold,
                        newLevel: privateState.level
                    )
                }
                
                /// UpdateSettings action handler - modifies nested nested StateNode
                HandleAction(UpdateSettingsAction.self) { (state: inout DemoGameState, action: UpdateSettingsAction, ctx: LandContext) async throws -> UpdateSettingsResponse in
                    // Ensure private state exists
                    if state.playerPrivateStates[ctx.playerID] == nil {
                        state.playerPrivateStates[ctx.playerID] = PlayerPrivateState()
                    }
                    
                    // Modify nested StateNode within nested StateNode
                    var privateState = state.playerPrivateStates[ctx.playerID]!
                    
                    if action.updateTheme {
                        privateState.settings.theme = action.theme
                    }
                    if action.updateSoundEnabled {
                        privateState.settings.soundEnabled = action.soundEnabled
                    }
                    
                    // Update back to state
                    state.playerPrivateStates[ctx.playerID] = privateState
                    
                    return UpdateSettingsResponse(
                        success: true,
                        settings: PlayerSettingsResponse(
                            theme: privateState.settings.theme,
                            soundEnabled: privateState.settings.soundEnabled
                        )
                    )
                }
                
                /// UpdateScore action handler - modifies perPlayer simple value
                HandleAction(UpdateScoreAction.self) { (state: inout DemoGameState, action: UpdateScoreAction, ctx: LandContext) async throws -> UpdateScoreResponse in
                    // Modify perPlayer simple value
                    let currentScore = state.playerScores[ctx.playerID] ?? 0
                    state.playerScores[ctx.playerID] = currentScore + action.points
                    
                    let newScore = state.playerScores[ctx.playerID]!
                    let newLevel = (newScore / 100) + 1
                    
                    return UpdateScoreResponse(
                        success: true,
                        newScore: newScore,
                        newLevel: newLevel
                    )
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
