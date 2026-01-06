import SwiftStateTree

// MARK: - Cookie Clicker Demo State

/// Public state for a single player, visible to everyone in the room.
@StateNodeBuilder
public struct CookiePlayerPublicState: StateNodeProtocol {
    /// Display name for this player.
    @Sync(.broadcast)
    var name: String = ""

    /// Current cookie count for this player.
    @Sync(.broadcast)
    var cookies: Int = 0

    /// Passive cookies gained per tick (per second).
    @Sync(.broadcast)
    var cookiesPerSecond: Int = 0

    public init() {}
}

/// Private state for a single player, only visible to that player.
@StateNodeBuilder
public struct CookiePlayerPrivateState: StateNodeProtocol {
    /// Total number of manual clicks performed by this player.
    @Sync(.broadcast)
    var totalClicks: Int = 0

    /// Purchased upgrades and their levels (e.g., "cursor": 3).
    @Sync(.broadcast)
    var upgrades: [String: Int] = [:]

    public init() {}
}

/// Root state for the cookie clicker demo.
@StateNodeBuilder
public struct CookieGameState: StateNodeProtocol {
    /// Online players and their public cookie stats.
    @Sync(.broadcast)
    var players: [PlayerID: CookiePlayerPublicState] = [:]

    /// Per-player private state (only visible to the owning player).
    @Sync(.perPlayerSlice())
    var privateStates: [PlayerID: CookiePlayerPrivateState] = [:]

    /// Total cookies in this room (sum of all players).
    @Sync(.broadcast)
    var totalCookies: Int = 0

    /// Server-side tick counter (increments every second).
    @Sync(.broadcast)
    var ticks: Int = 0

    public init() {}

    // MARK: - Helper Functions

    // MARK: Read-only helpers (can be used in resolvers)

    /// Calculate total cookies from all players (read-only).
    /// This can be used in resolvers or for validation.
    func calculateTotalCookies() -> Int {
        players.values.reduce(0) { $0 + $1.cookies }
    }

    /// Get player state if it exists (read-only).
    /// Returns nil if player doesn't exist.
    func getPlayerState(playerID: PlayerID) -> (publicState: CookiePlayerPublicState, privateState: CookiePlayerPrivateState)? {
        guard let publicState = players[playerID],
              let privateState = privateStates[playerID]
        else {
            return nil
        }
        return (publicState, privateState)
    }

    // MARK: Mutating helpers (only for use in handlers with inout State)

    /// Recompute total cookies from all players and update the state.
    /// This helper ensures the aggregate stays in sync with individual player states.
    mutating func recomputeTotalCookies() {
        totalCookies = calculateTotalCookies()
    }

    /// Ensure player state exists, creating default state if needed.
    /// Returns the public and private state for the player.
    mutating func ensurePlayerState(playerID: PlayerID, defaultName: String? = nil) -> (publicState: CookiePlayerPublicState, privateState: CookiePlayerPrivateState) {
        // Ensure public state exists
        if players[playerID] == nil {
            var publicState = CookiePlayerPublicState()
            publicState.name = defaultName ?? playerID.rawValue
            players[playerID] = publicState
        }

        // Ensure private state exists
        if privateStates[playerID] == nil {
            privateStates[playerID] = CookiePlayerPrivateState()
        }

        return (players[playerID]!, privateStates[playerID]!)
    }
}

// MARK: - Client Events

/// Client event for manually clicking the big cookie.
@Payload
public struct ClickCookieEvent: ClientEventPayload {
    /// Number of cookies to add for this click (default is 1).
    public let amount: Int

    public init(amount: Int = 1) {
        self.amount = amount
    }
}

// (Ping/Pong events removed to keep the demo minimal.)

// MARK: - Actions

/// Buy an upgrade that increases passive cookie generation.
@Payload
public struct BuyUpgradeAction: ActionPayload {
    public typealias Response = BuyUpgradeResponse

    /// Upgrade identifier (e.g., "cursor", "grandma").
    public let upgradeID: String

    public init(upgradeID: String) {
        self.upgradeID = upgradeID
    }
}

@Payload
public struct BuyUpgradeResponse: ResponsePayload {
    public let success: Bool
    public let newCookies: Int
    public let newCookiesPerSecond: Int
    public let upgradeLevel: Int

    public init(
        success: Bool,
        newCookies: Int,
        newCookiesPerSecond: Int,
        upgradeLevel: Int
    ) {
        self.success = success
        self.newCookies = newCookies
        self.newCookiesPerSecond = newCookiesPerSecond
        self.upgradeLevel = upgradeLevel
    }
}

// MARK: - Land Definition

public enum CookieGame {
    public static func makeLand() -> LandDefinition<CookieGameState> {
        // Use "cookie" as land identifier to match server registration.
        Land(
            "cookie",
            using: CookieGameState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(20)
            }

            ClientEvents {
                Register(ClickCookieEvent.self)
            }

            Rules {
                // MARK: - Join / Leave

                CanJoin { (_: CookieGameState, session: PlayerSession, _: LandContext) in
                    // maxPlayers is automatically checked by LandKeeper before this handler is called
                    let playerID = PlayerID(session.playerID)
                    return .allow(playerID: playerID)
                }

                OnJoin { (state: inout CookieGameState, ctx: LandContext) in
                    let playerID = ctx.playerID

                    // Derive a display name from JWT metadata or fall back to PlayerID.
                    let playerName: String
                    if let username = ctx.metadata["username"], !username.isEmpty {
                        playerName = username
                    } else if ctx.isGuest {
                        playerName = "Guest-" + ctx.sessionID.rawValue.prefix(4).lowercased()
                    } else {
                        playerName = playerID.rawValue
                    }

                    // Use helper to ensure player state exists with custom name
                    var (publicState, _) = state.ensurePlayerState(playerID: playerID, defaultName: playerName)
                    publicState.name = playerName
                    publicState.cookies = 0
                    publicState.cookiesPerSecond = 0
                    state.players[playerID] = publicState

                    // Recompute total cookies to keep aggregate in sync.
                    state.recomputeTotalCookies()
                }

                OnLeave { (state: inout CookieGameState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    state.players.removeValue(forKey: playerID)
                    state.privateStates.removeValue(forKey: playerID)

                    // Recompute total cookies after player leaves.
                    state.recomputeTotalCookies()
                }

                // MARK: - Client Events

                HandleEvent(ClickCookieEvent.self) { (state: inout CookieGameState, event: ClickCookieEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    // Ensure player state exists (should normally be true after OnJoin).
                    var (publicState, privateState) = state.ensurePlayerState(playerID: playerID)

                    let delta = max(1, event.amount)
                    publicState.cookies += delta
                    privateState.totalClicks += delta

                    state.players[playerID] = publicState
                    state.privateStates[playerID] = privateState

                    // Recompute total cookies.
                    state.recomputeTotalCookies()
                }

                // MARK: - Actions

                HandleAction(BuyUpgradeAction.self) { (state: inout CookieGameState, action: BuyUpgradeAction, ctx: LandContext) throws -> BuyUpgradeResponse in
                    let playerID = ctx.playerID

                    // Ensure player state exists.
                    var (publicState, privateState) = state.ensurePlayerState(playerID: playerID)

                    let currentLevel = privateState.upgrades[action.upgradeID] ?? 0

                    // Simple pricing and CPS gain model.
                    let baseCost: Int
                    let cpsGain: Int
                    switch action.upgradeID {
                    case "cursor":
                        baseCost = 10
                        cpsGain = 1
                    case "grandma":
                        baseCost = 50
                        cpsGain = 5
                    default:
                        baseCost = 25
                        cpsGain = 2
                    }

                    let cost = baseCost * (currentLevel + 1)
                    guard publicState.cookies >= cost else {
                        return BuyUpgradeResponse(
                            success: false,
                            newCookies: publicState.cookies,
                            newCookiesPerSecond: publicState.cookiesPerSecond,
                            upgradeLevel: currentLevel
                        )
                    }

                    publicState.cookies -= cost
                    publicState.cookiesPerSecond += cpsGain
                    privateState.upgrades[action.upgradeID] = currentLevel + 1

                    state.players[playerID] = publicState
                    state.privateStates[playerID] = privateState

                    // Recompute total cookies after purchase.
                    state.recomputeTotalCookies()

                    return BuyUpgradeResponse(
                        success: true,
                        newCookies: publicState.cookies,
                        newCookiesPerSecond: publicState.cookiesPerSecond,
                        upgradeLevel: currentLevel + 1
                    )
                }
            }

            // MARK: - Lifetime

            Lifetime {
                // Game logic updates (can modify state)
                Tick(every: .milliseconds(300)) { (state: inout CookieGameState, _: LandContext) in
                    state.ticks += 1

                    var total = 0
                    for (playerID, var publicState) in state.players {
                        let delta = publicState.cookiesPerSecond
                        if delta > 0 {
                            publicState.cookies += delta
                        }
                        state.players[playerID] = publicState
                        total += publicState.cookies
                    }

                    state.totalCookies = total
                }

                // Network synchronization (read-only callback will be called during sync)
                StateSync(every: .milliseconds(300)) { (state: CookieGameState, ctx: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
                }

                DestroyWhenEmpty(after: .seconds(5)) { (_: inout CookieGameState, ctx: LandContext) in
                    ctx.logger.info("Cookie land is empty, destroying...")
                }

                OnInitialize { (state: inout CookieGameState, _: LandContext) in
                    print("Cookie land initialized - players: \(state.players.count)")
                }

                OnFinalize { (state: inout CookieGameState, _: LandContext) in
                    print("Cookie land finalizing - players: \(state.players.count), totalCookies: \(state.totalCookies)")
                }

                AfterFinalize { (state: CookieGameState, ctx: LandContext) async in
                    ctx.logger.info(
                        "Cookie land finalized",
                        metadata: [
                            "players": .stringConvertible(state.players.count),
                            "totalCookies": .stringConvertible(state.totalCookies),
                            "ticks": .stringConvertible(state.ticks)
                        ]
                    )
                }
            }
        }
    }
}
