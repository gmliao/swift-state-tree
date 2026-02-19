import Testing
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeReevaluationMonitor
@testable import GameContent

@Suite("HeroDefenseReplayStateParityTests")
struct HeroDefenseReplayStateParityTests {
    @Test("Replay land uses HeroDefenseState as the state definition")
    func replayLandUsesLiveStateDefinition() {
        let replayLand = HeroDefenseReplay.makeLand()

        #expect(replayLand.stateType == HeroDefenseState.self)
    }

    @Test("Replay land registers shooting server events for schema/codegen")
    func replayLandRegistersShootingServerEvents() {
        let replayLand = HeroDefenseReplay.makeLand()
        let eventNames = Set(replayLand.serverEventRegistry.registered.map { $0.eventName })

        #expect(eventNames.contains("HeroDefenseReplayTick"))
        #expect(eventNames.contains("PlayerShoot"))
        #expect(eventNames.contains("TurretFire"))
    }

    @Test("Live HeroDefense snapshot shape has no replay wrapper artifacts")
    func liveSnapshotShapeHasNoReplayWrapperArtifacts() throws {
        var replay = HeroDefenseState()
        var player = PlayerState()
        player.position = Position2(x: 10.0, y: 20.0)
        replay.players[PlayerID("p1")] = player

        var monster = MonsterState()
        monster.id = 1
        monster.position = Position2(x: 11.0, y: 22.0)
        replay.monsters[1] = monster

        var turret = TurretState()
        turret.id = 2
        turret.position = Position2(x: 30.0, y: 40.0)
        turret.ownerID = PlayerID("p1")
        replay.turrets[2] = turret

        replay.base.health = 88
        replay.base.maxHealth = 100
        replay.score = 123

        let snapshot = try replay.broadcastSnapshot(dirtyFields: nil)
        let playersValue = snapshot.values["players"]?.objectValue
        let playerP1 = playersValue?["p1"]?.objectValue
        let monstersValue = snapshot.values["monsters"]?.objectValue
        let monster1 = monstersValue?["1"]?.objectValue
        let turretsValue = snapshot.values["turrets"]?.objectValue
        let turret2 = turretsValue?["2"]?.objectValue
        let baseValue = snapshot.values["base"]?.objectValue
        let scoreValue = snapshot.values["score"]

        #expect(playersValue != nil)
        #expect(playerP1?["base"] == nil)
        #expect(playerP1?["position"] != nil)
        #expect(monstersValue != nil)
        #expect(monster1?["position"] != nil)
        #expect(turretsValue != nil)
        #expect(turret2?["position"] != nil)
        #expect(baseValue?["base"] == nil)
        #expect(baseValue?["health"]?.intValue == 88)
        #expect(scoreValue?.intValue == 123)
    }

    @Test("applyProjectedState clears replay-applied fields when projected keys are missing")
    func applyProjectedStateClearsReplayAppliedFieldsWhenKeysMissing() {
        var state = HeroDefenseState()

        var player = PlayerState()
        player.position = Position2(x: 10.0, y: 20.0)
        state.players[PlayerID("p1")] = player

        var monster = MonsterState()
        monster.id = 1
        monster.health = 77
        state.monsters[1] = monster

        var turret = TurretState()
        turret.id = 2
        turret.ownerID = PlayerID("p1")
        state.turrets[2] = turret

        state.base.health = 42
        state.score = 3

        applyProjectedState([
            "score": AnyCodable(9)
        ], to: &state)

        let defaultBase = BaseState()

        #expect(state.players.isEmpty)
        #expect(state.monsters.isEmpty)
        #expect(state.turrets.isEmpty)
        #expect(state.base.position == defaultBase.position)
        #expect(state.base.radius == defaultBase.radius)
        #expect(state.base.health == defaultBase.health)
        #expect(state.base.maxHealth == defaultBase.maxHealth)
        #expect(state.score == 9)
    }

    @Test("applyProjectedState does not mix old frame data when projected payload is invalid")
    func applyProjectedStateInvalidPayloadDoesNotLeakPreviousFrameData() {
        var state = HeroDefenseState()

        var player = PlayerState()
        player.health = 11
        state.players[PlayerID("p1")] = player
        state.base.health = 55
        state.score = 1

        applyProjectedState([
            "players": AnyCodable("not-a-player-map"),
            "base": AnyCodable("not-a-base-object"),
            "score": AnyCodable(99)
        ], to: &state)

        let defaultBase = BaseState()

        #expect(state.players.isEmpty)
        #expect(state.base.position == defaultBase.position)
        #expect(state.base.radius == defaultBase.radius)
        #expect(state.base.health == defaultBase.health)
        #expect(state.base.maxHealth == defaultBase.maxHealth)
        #expect(state.score == 99)
    }

    @Test("fallback shooting events prefer turret fire when turret exists")
    func fallbackShootingEventsPreferTurretFireWhenTurretExists() {
        let playerID = PlayerID("p1")

        var previousMonsters: [Int: MonsterState] = [:]
        var previousMonster = MonsterState()
        previousMonster.id = 10
        previousMonster.health = 10
        previousMonster.position = Position2(x: 70.0, y: 36.0)
        previousMonsters[10] = previousMonster

        var currentState = HeroDefenseState()
        var currentMonster = previousMonster
        currentMonster.health = 8
        currentState.monsters[10] = currentMonster

        var player = PlayerState()
        player.position = Position2(x: 64.0, y: 36.0)
        currentState.players[playerID] = player

        var turret = TurretState()
        turret.id = 2
        turret.position = Position2(x: 68.0, y: 36.0)
        turret.ownerID = playerID
        currentState.turrets[2] = turret

        let events = buildFallbackShootingEvents(
            previousMonsters: previousMonsters,
            previousPlayers: [playerID: player],
            previousTurrets: currentState.turrets,
            currentState: currentState
        )

        #expect(events.contains(where: { event in
            if case .turretFire = event { return true }
            return false
        }))
    }

    @Test("projected replay events are forwarded as type-erased server events")
    func projectedReplayEventsAreForwardedAsTypeErasedServerEvents() {
        let projectedEvents: [AnyCodable] = [
            AnyCodable([
                "typeIdentifier": "PlayerShoot",
                "payload": [
                    "playerID": ["rawValue": "p1"],
                    "from": ["v": ["x": 1000, "y": 2000]],
                    "to": ["v": ["x": 3000, "y": 4000]],
                ],
            ]),
            AnyCodable([
                "typeIdentifier": "TurretFire",
                "payload": [
                    "turretID": 2,
                    "from": ["v": ["x": 5000, "y": 6000]],
                    "to": ["v": ["x": 7000, "y": 8000]],
                ],
            ]),
        ]

        let forwarded = buildProjectedServerEvents(
            projectedEvents,
            allowedEventTypes: ["PlayerShoot", "TurretFire"]
        )

        #expect(forwarded.count == 2)
        #expect(forwarded[0].type == "PlayerShoot")
        #expect(forwarded[1].type == "TurretFire")
    }

    @Test("projected replay events ignore unknown event types safely")
    func projectedReplayEventsIgnoreUnknownEventTypesSafely() {
        let projectedEvents: [AnyCodable] = [
            AnyCodable([
                "typeIdentifier": "UnknownEffect",
                "payload": [
                    "value": 1,
                ],
            ]),
            AnyCodable([
                "typeIdentifier": "PlayerShoot",
                "payload": [
                    "playerID": ["rawValue": "p1"],
                    "from": ["v": ["x": 1000, "y": 2000]],
                    "to": ["v": ["x": 3000, "y": 4000]],
                ],
            ]),
        ]

        let forwarded = buildProjectedServerEvents(
            projectedEvents,
            allowedEventTypes: ["PlayerShoot", "TurretFire"]
        )

        #expect(forwarded.count == 1)
        #expect(forwarded[0].type == "PlayerShoot")
    }

    @Test("replay event policy defaults to projectedOnly when service is absent")
    func replayEventPolicyDefaultsToProjectedOnlyWhenServiceAbsent() {
        let services = LandServices()
        let policy = resolveReplayEventPolicy(from: services)
        #expect(policy == .projectedOnly)
        #expect(shouldEmitFallbackShootingEvents(projectedEventCount: 0, eventPolicy: policy) == false)
    }

    @Test("replay event policy supports projectedWithFallback compatibility mode")
    func replayEventPolicySupportsProjectedWithFallbackCompatibilityMode() {
        var services = LandServices()
        services.register(
            ReevaluationReplayPolicyService(eventPolicy: .projectedWithFallback),
            as: ReevaluationReplayPolicyService.self
        )

        let policy = resolveReplayEventPolicy(from: services)
        #expect(policy == .projectedWithFallback)
        #expect(shouldEmitFallbackShootingEvents(projectedEventCount: 0, eventPolicy: policy))
        #expect(shouldEmitFallbackShootingEvents(projectedEventCount: 1, eventPolicy: policy) == false)
    }
}
