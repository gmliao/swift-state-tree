import Foundation
import Logging
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeReevaluationMonitor

// MARK: - Land Definition

public enum HeroDefense {
    /// - Parameter maxPlayers: Maximum players allowed to join (default 10, the production value).
    public static func makeLand(maxPlayers: Int = 10) -> LandDefinition<HeroDefenseState> {
        Land(
            "hero-defense",
            using: HeroDefenseState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(maxPlayers)
            }

            ClientEvents {
                Register(MoveToEvent.self)
                Register(ShootEvent.self)
                Register(UpdateRotationEvent.self)
                Register(PlaceTurretEvent.self)
                Register(UpgradeWeaponEvent.self)
                Register(UpgradeTurretEvent.self)
            }

            ServerEvents {
                Register(PlayerShootEvent.self)
                Register(TurretFireEvent.self)
            }

            Lifetime {
                Tick(every: .milliseconds(Int64(GameConfig.TICK_INTERVAL_MS))) { (state: inout HeroDefenseState, ctx: LandContext) in
                    guard let tickId = ctx.tickId,
                          let configService = ctx.services.get(GameConfigProviderService.self)
                    else {
                        return
                    }
                    let config = configService.provider
                    // Measurement only (`HeroDefenseStats`): this tick's kills, outside the state.
                    var killedThisTick = 0

                    // Update all player systems (sorted keys: dictionary iteration order is
                    // not deterministic across runs, and firing order affects combat outcomes)
                    for playerID in state.players.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
                        guard var player = state.players[playerID] else { continue }
                        defer { state.players[playerID] = player }

                        // Update movement (this also updates rotation towards movement target)
                        MovementSystem.updatePlayerMovement(&player, ctx)

                        // Auto-shoot: Check if there's a monster in range and fire automatically
                        guard CombatSystem.canPlayerFire(player, ctx) else {
                            continue
                        }

                        guard let result = CombatSystem.processPlayerShoot(
                            player: &player,
                            monsters: &state.monsters,
                            ctx
                        ) else {
                            continue
                        }
                        if result.defeated { killedThisTick += 1 }

                        // Broadcast shoot event to all players (deterministic output)
                        if heroDefenseServerEventsEnabled {
                            ctx.emitEvent(
                                PlayerShootEvent(
                                    playerID: playerID,
                                    from: result.shooterPosition,
                                    to: result.targetPosition
                                ),
                                to: .all
                            )
                        }
                    }

                    // Spawn monsters periodically (spawn speed increases over time)
                    let spawnInterval = MonsterSystem.getMonsterSpawnInterval(ctx)
                    if tickId % Int64(spawnInterval) == 0 {
                        // Spawn random number of monsters (1-4) for more intense combat
                        var spawnCount = ctx.random.nextInt(in: config.monsterSpawnCountMin ... config.monsterSpawnCountMax)
                        // Clamp to the configured monster cap (0 = unlimited)
                        if config.monsterMaxCount > 0 {
                            spawnCount = min(spawnCount, max(0, config.monsterMaxCount - state.monsters.count))
                        }
                        for _ in 0 ..< spawnCount {
                            let monsterID = state.nextMonsterID
                            state.nextMonsterID += 1
                            let monster = MonsterSystem.spawnMonster(nextID: monsterID, ctx)
                            state.monsters[monster.id] = monster
                        }
                    }

                    // Update all monsters (sorted keys for deterministic iteration order)
                    var monstersToRemove: [Int] = []
                    let monsterActiveEvery = max(1, config.monsterActiveEvery)
                    for monsterID in state.monsters.keys.sorted() {
                        // An idle monster is skipped before it is read, so none of its fields is written.
                        if monsterActiveEvery > 1, (monsterID &+ Int(tickId)) % monsterActiveEvery != 0 { continue }
                        guard var monster = state.monsters[monsterID] else { continue }
                        // Update movement
                        MovementSystem.updateMonsterMovement(
                            &monster,
                            basePosition: state.base.position,
                            ctx
                        )
                        state.monsters[monsterID] = monster

                        // Check if reached base
                        if MonsterSystem.checkMonsterReachedBase(
                            monster,
                            base: &state.base,
                            ctx
                        ) {
                            monstersToRemove.append(monsterID)
                        }
                    }

                    // Remove monsters that reached base
                    for monsterID in monstersToRemove {
                        state.monsters.removeValue(forKey: monsterID)
                    }

                    // Update turrets (auto-target and fire)
                    // Sorted keys for deterministic iteration order
                    for turretID in state.turrets.keys.sorted() {
                        guard var turret = state.turrets[turretID] else { continue }
                        defer { state.turrets[turretID] = turret }

                        // Check fire rate
                        guard CombatSystem.canTurretFire(turret, ctx) else {
                            continue
                        }

                        // Try to shoot at nearest monster
                        guard let result = CombatSystem.processTurretShoot(
                            turret: &turret,
                            monsters: &state.monsters,
                            ctx
                        ) else {
                            continue
                        }
                        if result.defeated { killedThisTick += 1 }

                        // Give resources to turret owner if monster was defeated
                        if result.defeated, let ownerID = turret.ownerID {
                            state.players[ownerID]?.resources += result.rewardGained
                        }

                        // Broadcast turret fire event to all players (deterministic output)
                        if heroDefenseServerEventsEnabled {
                            ctx.emitEvent(
                                TurretFireEvent(
                                    turretID: turretID,
                                    from: result.turretPosition,
                                    to: result.targetPosition
                                ),
                                to: .all
                            )
                        }
                    }

                    // Measurement only, outside the state (`HeroDefenseStats`); only live lands
                    // have a recorder (not replay or re-evaluation).
                    ctx.services.get(HeroDefenseStatsRecorder.self)?.note(
                        landID: ctx.landID, tick: tickId, monsters: state.monsters.count,
                        baseHealth: state.base.health, players: state.players.count,
                        spawned: state.nextMonsterID - 1, killedThisTick: killedThisTick,
                        reachedBaseThisTick: monstersToRemove.count
                    )
                }

                StateSync(every: .milliseconds(100)) { (_: HeroDefenseState, _: LandContext) in
                    // Read-only callback - will be called during sync
                    // Do NOT modify state here - use Tick for state mutations
                    // Use for logging, metrics, or other read-only operations
                    // StateSync callback - read-only operations only
                }

                DestroyWhenEmpty(after: .seconds(5)) { (_: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is empty, destroying...")
                }

                OnFinalize { (_: inout HeroDefenseState, ctx: LandContext) in
                    ctx.logger.info("Hero Defense room is finalizing...")
                }

                AfterFinalize { (state: HeroDefenseState, ctx: LandContext) async in
                    ctx.logger.info("Hero Defense room is finalized with final score: \(state.score)")

                    do {
                        try await ReevaluationRecordSaver.saveOnShutdown(
                            ctx: ctx,
                            filenamePrefix: "hero-defense"
                        )
                        ctx.logger.info("✅ Reevaluation record saved successfully")
                    } catch {
                        ctx.logger.error("❌ Failed to save reevaluation record: \(error)")
                    }
                }
            }

            Rules {
                OnJoin(resolvers: UserLevelResolver.self) { (state: inout HeroDefenseState, ctx: LandContext) in
                    guard let configService = ctx.services.get(GameConfigProviderService.self) else {
                        return
                    }
                    let config = configService.provider

                    let playerID = ctx.playerID

                    // Get user level from resolver (deterministic based on PlayerID hash)
                    let userLevel = (ctx.userLevel as UserLevel?)?.level ?? 1

                    // Spawn player near base center
                    var player = PlayerState()
                    player.position = Position2(
                        x: config.baseCenterX + ctx.random.nextFloat(in: -5.0 ..< 5.0),
                        y: config.baseCenterY + ctx.random.nextFloat(in: -5.0 ..< 5.0)
                    )
                    player.position = MovementSystem.clampToWorldBounds(player.position, ctx)
                    player.rotation = Angle(degrees: 0.0)
                    player.targetPosition = nil as Position2?

                    // Set initial health and max health based on user level
                    // Higher level players start with more health
                    let baseHealth = 100
                    let levelBonus = userLevel * 10
                    player.health = baseHealth + levelBonus
                    player.maxHealth = baseHealth + levelBonus

                    // Set initial weapon level based on user level (deterministic from PlayerID hash)
                    // Players start with different weapon levels, but can upgrade further
                    player.weaponLevel = userLevel - 1 // Convert 1-3 to 0-2 for weapon level
                    player.resources = 0
                    state.players[playerID] = player
                    ctx.logger.info("👤 Player joined", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "level": .stringConvertible(userLevel),
                        "health": .stringConvertible(player.health),
                        "totalPlayers": .string("\(state.players.count)"),
                    ])
                }

                OnLeave { (state: inout HeroDefenseState, ctx: LandContext) in
                    let playerID = ctx.playerID
                    state.players.removeValue(forKey: playerID)
                    ctx.logger.info("Player left", metadata: [
                        "playerID": .string(playerID.rawValue),
                    ])
                }

                HandleAction(PlayAction.self) { (state: inout HeroDefenseState, _: PlayAction, _: LandContext) in
                    state.score += 1
                    return PlayResponse(newScore: state.score)
                }

                HandleEvent(MoveToEvent.self) { (state: inout HeroDefenseState, event: MoveToEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    // Update player's target position (clamp to world bounds)
                    if var player = state.players[playerID] {
                        let clampedTarget = MovementSystem.clampToWorldBounds(event.target, ctx)
                        player.targetPosition = clampedTarget
                        state.players[playerID] = player
                        // EncodingBenchmark's input count, once the move changed the state; no
                        // probe is registered elsewhere.
                        ctx.services.get(InputProbe.self)?.noteApplied()
                    } else {
                        ctx.logger.warning("⚠️ MoveToEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                    }
                }

                HandleEvent(ShootEvent.self) { (state: inout HeroDefenseState, _: ShootEvent, ctx: LandContext) in
                    // Manual shoot event (optional - auto-shoot is handled in Tick)
                    // This can be used for manual shooting if needed in the future
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ ShootEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Check fire rate
                    if !CombatSystem.canPlayerFire(player, ctx) {
                        return
                    }

                    // Find nearest monster in range and auto-aim
                    let range = CombatSystem.getWeaponRange(level: player.weaponLevel, ctx)
                    let nearestMonster = CombatSystem.findNearestMonsterInRange(
                        from: player.position,
                        range: range,
                        monsters: state.monsters
                    )

                    if let (monsterID, monster) = nearestMonster {
                        // Rotate player towards monster (auto-aim)
                        let direction = monster.position.v - player.position.v
                        let angleRad = direction.toAngle()
                        player.rotation = Angle(radians: angleRad)

                        // Save positions for event (before mutation)
                        let playerPos = player.position
                        let monsterPos = monster.position

                        // Apply damage
                        var updatedMonster = monster
                        let damage = CombatSystem.getWeaponDamage(level: player.weaponLevel, ctx)
                        if CombatSystem.damageMonster(&updatedMonster, damage: damage) {
                            // Monster defeated, give resources
                            player.resources += updatedMonster.reward
                            state.monsters.removeValue(forKey: monsterID)
                        } else {
                            state.monsters[monsterID] = updatedMonster
                        }

                        // Update fire tick
                        if let tickId = ctx.tickId {
                            player.lastFireTick = tickId
                        }

                        // Broadcast shoot event (deterministic output)
                        if heroDefenseServerEventsEnabled {
                            ctx.emitEvent(
                                PlayerShootEvent(
                                    playerID: playerID,
                                    from: playerPos,
                                    to: monsterPos
                                ),
                                to: .all
                            )
                        }
                    }

                    state.players[playerID] = player
                }

                HandleEvent(UpdateRotationEvent.self) { (state: inout HeroDefenseState, event: UpdateRotationEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ UpdateRotationEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Update player rotation
                    player.rotation = event.rotation
                    state.players[playerID] = player
                }

                HandleEvent(PlaceTurretEvent.self) { (state: inout HeroDefenseState, event: PlaceTurretEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ PlaceTurretEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Check if player has enough resources
                    guard let configService = ctx.services.get(GameConfigProviderService.self) else {
                        return
                    }
                    let config = configService.provider

                    if player.resources < config.turretPlacementCost {
                        ctx.logger.info("⚠️ PlaceTurretEvent: Insufficient resources", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "required": .string("\(config.turretPlacementCost)"),
                            "available": .string("\(player.resources)"),
                        ])
                        return
                    }

                    // Check if position is valid
                    if !TurretSystem.isValidTurretPosition(
                        event.position,
                        basePosition: state.base.position,
                        existingTurrets: state.turrets,
                        ctx
                    ) {
                        ctx.logger.info("⚠️ PlaceTurretEvent: Invalid position", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    // Deduct resources and place turret
                    player.resources -= config.turretPlacementCost
                    let turretID = state.nextTurretID
                    state.nextTurretID += 1
                    var turret = TurretState()
                    turret.id = turretID
                    turret.position = event.position
                    turret.ownerID = playerID
                    turret.level = 0
                    state.turrets[turret.id] = turret
                    state.players[playerID] = player

                    ctx.logger.info("🏰 Turret placed", metadata: [
                        "playerID": .string(playerID.rawValue),
                        "turretID": .string("\(turret.id)"),
                        "cost": .string("\(config.turretPlacementCost)"),
                        "remainingResources": .string("\(player.resources)"),
                    ])
                }

                HandleEvent(UpgradeWeaponEvent.self) { (state: inout HeroDefenseState, _: UpgradeWeaponEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID] else {
                        ctx.logger.warning("⚠️ UpgradeWeaponEvent: Player not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                        ])
                        return
                    }

                    guard let configService = ctx.services.get(GameConfigProviderService.self) else {
                        return
                    }
                    let config = configService.provider

                    // Check if player has enough resources
                    if player.resources >= config.weaponUpgradeCost {
                        player.resources -= config.weaponUpgradeCost
                        player.weaponLevel += 1
                        state.players[playerID] = player

                        ctx.logger.info("🔫 Weapon upgraded", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "level": .string("\(player.weaponLevel)"),
                        ])
                    }
                }

                HandleEvent(UpgradeTurretEvent.self) { (state: inout HeroDefenseState, event: UpgradeTurretEvent, ctx: LandContext) in
                    let playerID = ctx.playerID

                    guard var player = state.players[playerID],
                          var turret = state.turrets[event.turretID]
                    else {
                        ctx.logger.warning("⚠️ UpgradeTurretEvent: Player or turret not found", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                        ])
                        return
                    }

                    // Check ownership
                    guard turret.ownerID == playerID else {
                        ctx.logger.warning("⚠️ UpgradeTurretEvent: Not owner", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                        ])
                        return
                    }

                    guard let configService = ctx.services.get(GameConfigProviderService.self) else {
                        return
                    }
                    let config = configService.provider

                    // Check if player has enough resources
                    if player.resources >= config.turretUpgradeCost {
                        player.resources -= config.turretUpgradeCost
                        turret.level += 1
                        state.players[playerID] = player
                        state.turrets[event.turretID] = turret

                        ctx.logger.info("🏰 Turret upgraded", metadata: [
                            "playerID": .string(playerID.rawValue),
                            "turretID": .string("\(event.turretID)"),
                            "level": .string("\(turret.level)"),
                        ])
                    }
                }
            }
        }
    }
}

/// Hero Defense's environment switches.
public enum HeroDefenseEnvKeys {
    /// Benchmark switch: `HERO_DEFENSE_SERVER_EVENTS=false` stops the land's server events (the
    /// shoot and turret-fire broadcasts); the state is unchanged. On by default.
    public static let serverEvents = "HERO_DEFENSE_SERVER_EVENTS"
    /// Ticks over which the spawn interval falls from its maximum to its minimum
    /// (`monsterSpawnAccelerationTicks`), read by `DefaultGameConfigProvider.fromEnvironment()` in
    /// the processes that run hero-defense lands (GameServer, ReevaluationRunner). 0: every land
    /// spawns at the minimum interval (the final rate) from tick 0. Unset, invalid or negative:
    /// `GameConfig.MONSTER_SPAWN_ACCELERATION_TICKS` (3000).
    ///
    /// A record doesn't carry it: replay a record (ReevaluationRunner, or GameServer's replay
    /// land) with the value its live run had, or the spawns, and every tick after them, differ.
    /// The measurement runs record the value they ran with (network-impairment's run.json
    /// `params.spawnRampTicks`; multiroom-load's run.json and run headers).
    public static let spawnRampTicks = "HERO_DEFENSE_SPAWN_RAMP_TICKS"
}

/// Read once, when the land first emits.
let heroDefenseServerEventsEnabled = EnvHelpers.getEnvBool(key: HeroDefenseEnvKeys.serverEvents, defaultValue: true)
