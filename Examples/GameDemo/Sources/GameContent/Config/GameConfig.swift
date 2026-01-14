import Foundation

// MARK: - Game Constants

/// Game world configuration constants
public enum GameConfig {
    /// World size limits (in Float units)
    public static let WORLD_WIDTH: Float = 128.0
    public static let WORLD_HEIGHT: Float = 72.0
    
    /// Base position (center of world)
    public static let BASE_CENTER_X: Float = WORLD_WIDTH / 2.0
    public static let BASE_CENTER_Y: Float = WORLD_HEIGHT / 2.0
    public static let BASE_RADIUS: Float = 3.0
    
    /// Base health
    public static let BASE_MAX_HEALTH: Int = 100
    
    /// Game tick configuration
    public static let TICK_INTERVAL_MS: Int = 50  // Game tick interval in milliseconds
    
    /// Monster spawn configuration
    public static let MONSTER_SPAWN_INTERVAL_TICKS: Int = 30  // Initial spawn interval in ticks (faster start)
    public static let MONSTER_SPAWN_INTERVAL_MIN_TICKS: Int = 3  // Fastest spawn interval in ticks (upper limit, more intense)
    public static let MONSTER_SPAWN_INTERVAL_MAX_TICKS: Int = 30  // Slowest spawn interval in ticks (initial)
    public static let MONSTER_SPAWN_ACCELERATION_TICKS: Int64 = 3000  // Ticks to reach max speed (faster acceleration, ~2.5 minutes at 50ms/tick)
    /// Monster spawn count per wave
    /// Note: For consistent performance testing, set both MIN and MAX to 1
    /// For gameplay, use range (e.g., MIN=1, MAX=4) for varied intensity
    public static let MONSTER_SPAWN_COUNT_MIN: Int = 1  // Minimum monsters spawned per wave
    public static let MONSTER_SPAWN_COUNT_MAX: Int = 1  // Maximum monsters spawned per wave (set to 1 for consistent testing)
    public static let MONSTER_MOVE_SPEED: Float = 0.5
    public static let MONSTER_BASE_HEALTH: Int = 10
    public static let MONSTER_BASE_REWARD: Int = 10  // Increased reward for faster progression
    
    /// Weapon configuration
    public static let WEAPON_BASE_DAMAGE: Int = 5
    public static let WEAPON_BASE_RANGE: Float = 20.0
    public static let WEAPON_FIRE_RATE_TICKS: Int = 10  // Fire rate interval in ticks
    
    /// Turret configuration
    public static let TURRET_BASE_DAMAGE: Int = 3
    public static let TURRET_BASE_RANGE: Float = 15.0
    public static let TURRET_FIRE_RATE_TICKS: Int = 20  // Fire rate interval in ticks
    public static let TURRET_PLACEMENT_DISTANCE: Float = 8.0  // Distance from base center
    
    /// Upgrade costs
    public static let WEAPON_UPGRADE_COST: Int = 5
    public static let TURRET_UPGRADE_COST: Int = 10
    public static let TURRET_PLACEMENT_COST: Int = 15
}
