import Foundation
import SwiftStateTree

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
    /// Maximum number of live monsters allowed in a room. 0 means unlimited (default behavior).
    var monsterMaxCount: Int { get }
    /// A monster is updated, and so written, only in the ticks where `(id + tick) % monsterActiveEvery == 0`;
    /// an idle monster's fields aren't touched in the other ticks. 1 (the default) updates every
    /// monster every tick. Benchmarks use it for a workload where most monsters stay idle.
    var monsterActiveEvery: Int { get }
}

extension GameConfigProvider {
    /// Default: no cap, preserving the original spawn behavior.
    public var monsterMaxCount: Int { 0 }
    /// Default: every monster is updated every tick.
    public var monsterActiveEvery: Int { 1 }
}

public struct GameConfigProviderService: Sendable {
    public let provider: any GameConfigProvider

    public init(provider: any GameConfigProvider) {
        self.provider = provider
    }
}

public struct DefaultGameConfigProvider: GameConfigProvider {
    /// The spawn ramp's length in ticks; 0 skips it. The default is the game's own.
    public let spawnRampTicks: Int64

    public init(spawnRampTicks: Int64 = GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS) {
        self.spawnRampTicks = max(0, spawnRampTicks)
    }

    /// The default provider with `HERO_DEFENSE_SPAWN_RAMP_TICKS` applied (`HeroDefenseEnvKeys.spawnRampTicks`).
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DefaultGameConfigProvider {
        let fallback = Int(GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS)
        let value = EnvHelpers.getEnvInt(key: HeroDefenseEnvKeys.spawnRampTicks, defaultValue: fallback, environment: environment)
        return DefaultGameConfigProvider(spawnRampTicks: Int64(value >= 0 ? value : fallback))
    }

    public var worldWidth: Float { GameConfig.WORLD_WIDTH }
    public var worldHeight: Float { GameConfig.WORLD_HEIGHT }
    public var baseCenterX: Float { GameConfig.BASE_CENTER_X }
    public var baseCenterY: Float { GameConfig.BASE_CENTER_Y }
    public var baseRadius: Float { GameConfig.BASE_RADIUS }
    public var baseMaxHealth: Int { GameConfig.BASE_MAX_HEALTH }
    public var tickIntervalMs: Int { GameConfig.TICK_INTERVAL_MS }
    public var monsterSpawnIntervalMinTicks: Int { GameConfig.MONSTER_SPAWN_INTERVAL_MIN_TICKS }
    public var monsterSpawnIntervalMaxTicks: Int { GameConfig.MONSTER_SPAWN_INTERVAL_MAX_TICKS }
    public var monsterSpawnAccelerationTicks: Int64 { spawnRampTicks }
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
