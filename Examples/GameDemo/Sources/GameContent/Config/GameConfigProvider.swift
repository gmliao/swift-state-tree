import Foundation

public protocol GameConfigProvider: Sendable {
    var worldWidth: Float { get }
    var worldHeight: Float { get }
    var baseCenterX: Float { get }
    var baseCenterY: Float { get }
    var baseRadius: Float { get }
    var baseMaxHealth: Int { get }
    var tickIntervalMs: Int { get }
    var monsterSpawnIntervalMinTicks: Int { get }
    var monsterSpawnIntervalMaxTicks: Int { get }
    var monsterSpawnAccelerationTicks: Int64 { get }
    var monsterSpawnCountMin: Int { get }
    var monsterSpawnCountMax: Int { get }
    var monsterMoveSpeed: Float { get }
    var monsterBaseHealth: Int { get }
    var monsterBaseReward: Int { get }
    var weaponBaseDamage: Int { get }
    var weaponBaseRange: Float { get }
    var weaponFireRateTicks: Int { get }
    var turretBaseDamage: Int { get }
    var turretBaseRange: Float { get }
    var turretFireRateTicks: Int { get }
    var turretPlacementDistance: Float { get }
    var weaponUpgradeCost: Int { get }
    var turretUpgradeCost: Int { get }
    var turretPlacementCost: Int { get }
}

public struct GameConfigProviderService: Sendable {
    public let provider: any GameConfigProvider

    public init(provider: any GameConfigProvider) {
        self.provider = provider
    }
}

public struct DefaultGameConfigProvider: GameConfigProvider {
    public init() {}

    public var worldWidth: Float { GameConfig.WORLD_WIDTH }
    public var worldHeight: Float { GameConfig.WORLD_HEIGHT }
    public var baseCenterX: Float { GameConfig.BASE_CENTER_X }
    public var baseCenterY: Float { GameConfig.BASE_CENTER_Y }
    public var baseRadius: Float { GameConfig.BASE_RADIUS }
    public var baseMaxHealth: Int { GameConfig.BASE_MAX_HEALTH }
    public var tickIntervalMs: Int { GameConfig.TICK_INTERVAL_MS }
    public var monsterSpawnIntervalMinTicks: Int { GameConfig.MONSTER_SPAWN_INTERVAL_MIN_TICKS }
    public var monsterSpawnIntervalMaxTicks: Int { GameConfig.MONSTER_SPAWN_INTERVAL_MAX_TICKS }
    public var monsterSpawnAccelerationTicks: Int64 { GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS }
    public var monsterSpawnCountMin: Int { GameConfig.MONSTER_SPAWN_COUNT_MIN }
    public var monsterSpawnCountMax: Int { GameConfig.MONSTER_SPAWN_COUNT_MAX }
    public var monsterMoveSpeed: Float { GameConfig.MONSTER_MOVE_SPEED }
    public var monsterBaseHealth: Int { GameConfig.MONSTER_BASE_HEALTH }
    public var monsterBaseReward: Int { GameConfig.MONSTER_BASE_REWARD }
    public var weaponBaseDamage: Int { GameConfig.WEAPON_BASE_DAMAGE }
    public var weaponBaseRange: Float { GameConfig.WEAPON_BASE_RANGE }
    public var weaponFireRateTicks: Int { GameConfig.WEAPON_FIRE_RATE_TICKS }
    public var turretBaseDamage: Int { GameConfig.TURRET_BASE_DAMAGE }
    public var turretBaseRange: Float { GameConfig.TURRET_BASE_RANGE }
    public var turretFireRateTicks: Int { GameConfig.TURRET_FIRE_RATE_TICKS }
    public var turretPlacementDistance: Float { GameConfig.TURRET_PLACEMENT_DISTANCE }
    public var weaponUpgradeCost: Int { GameConfig.WEAPON_UPGRADE_COST }
    public var turretUpgradeCost: Int { GameConfig.TURRET_UPGRADE_COST }
    public var turretPlacementCost: Int { GameConfig.TURRET_PLACEMENT_COST }
}
