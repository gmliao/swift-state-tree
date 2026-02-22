import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath
import SwiftStateTreeReevaluationMonitor

@Payload
public struct HeroDefenseReplayTickEvent: ServerEventPayload {
    public let tickId: Int64
    public let isMatch: Bool
    public let expectedHash: String
    public let actualHash: String

    public init(tickId: Int64, isMatch: Bool, expectedHash: String, actualHash: String) {
        self.tickId = tickId
        self.isMatch = isMatch
        self.expectedHash = expectedHash
        self.actualHash = actualHash
    }
}

public enum HeroDefenseReplay {
    public static func makeLand() -> LandDefinition<HeroDefenseState> {
        Land("hero-defense-replay", using: HeroDefenseState.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(64)
            }

            Lifetime {
                Tick(every: .milliseconds(50)) { (state: inout HeroDefenseState, ctx: LandContext) in
                    guard let service = ctx.services.get(ReevaluationRunnerService.self) else {
                        return
                    }

                    let status = service.getStatus()

                    if status.phase == .idle {
                        guard let recordFilePath = resolveReplayRecordPath(from: ctx.landID) else {
                            service.startVerification(
                                landType: "hero-defense",
                                recordFilePath: "__invalid_replay_record_path__"
                            )
                            return
                        }

                        service.startVerification(
                            landType: "hero-defense",
                            recordFilePath: recordFilePath
                        )
                        return
                    }

                    if let result = service.consumeNextResult() {
                        if let projectedFrame = result.projectedFrame {
                            applyProjectedState(projectedFrame.stateObject, to: &state)
                            _ = emitProjectedServerEvents(projectedFrame.serverEvents, ctx: ctx)
                            // Trigger immediate sync so client receives updated state (avoids showing
                            // baseline position 0,0 before first projected frame is applied)
                            ctx.requestSyncBroadcastOnly()
                        }

                        let event = HeroDefenseReplayTickEvent(
                            tickId: result.tickId,
                            isMatch: result.isMatch,
                            expectedHash: result.recordedHash ?? "?",
                            actualHash: result.stateHash
                        )
                        ctx.emitEvent(event, to: .all)
                    }
                }
            }

            ServerEvents {
                Register(HeroDefenseReplayTickEvent.self)
                Register(PlayerShootEvent.self)
                Register(TurretFireEvent.self)
            }
        }
    }
}

@discardableResult
private func emitProjectedServerEvents(_ projectedEvents: [AnyCodable], ctx: LandContext) -> Int {
    let forwardedEvents = buildProjectedServerEvents(
        projectedEvents,
        allowedEventTypes: projectedReplayAllowedEventTypes
    )
    let droppedCount = projectedEvents.count - forwardedEvents.count
    if droppedCount > 0 {
        ctx.logger.warning("Ignored unsupported replay projected events", metadata: [
            "dropped": .string("\(droppedCount)"),
        ])
    }

    for event in forwardedEvents {
        ctx.emitAnyServerEvent(event, to: .all)
    }

    return forwardedEvents.count
}

let projectedReplayAllowedEventTypes: Set<String> = [
    "PlayerShoot",
    "TurretFire",
]

func buildProjectedServerEvents(
    _ projectedEvents: [AnyCodable],
    allowedEventTypes: Set<String>
) -> [AnyServerEvent] {
    projectedEvents.compactMap { rawEvent in
        let envelope = decodeProjectedServerEventEnvelope(rawEvent)
        guard let envelope else {
            return nil
        }

        guard allowedEventTypes.contains(envelope.typeIdentifier) else {
            return nil
        }

        return AnyServerEvent(
            type: envelope.typeIdentifier,
            payload: envelope.payload
        )
    }
}

private struct ProjectedServerEventEnvelope {
    let typeIdentifier: String
    let payload: AnyCodable
}

private func decodeProjectedServerEventEnvelope(_ rawEvent: AnyCodable) -> ProjectedServerEventEnvelope? {
    if let object = rawEvent.base as? [String: Any] {
        let typeIdentifier: String?
        if let rawType = object["typeIdentifier"] as? String {
            typeIdentifier = rawType
        } else if let wrappedType = object["typeIdentifier"] as? AnyCodable {
            typeIdentifier = wrappedType.base as? String
        } else {
            typeIdentifier = nil
        }
        guard let typeIdentifier else {
            return nil
        }
        guard let rawPayload = object["payload"] else {
            return nil
        }

        let payload: AnyCodable
        if let wrappedPayload = rawPayload as? AnyCodable {
            payload = wrappedPayload
        } else {
            payload = AnyCodable(rawPayload)
        }

        return ProjectedServerEventEnvelope(
            typeIdentifier: typeIdentifier,
            payload: payload
        )
    }

    guard let wrappedObject = rawEvent.base as? [String: AnyCodable] else {
        return nil
    }
    guard let typeIdentifier = wrappedObject["typeIdentifier"]?.base as? String else {
        return nil
    }
    guard let payload = wrappedObject["payload"] else {
        return nil
    }

    return ProjectedServerEventEnvelope(
        typeIdentifier: typeIdentifier,
        payload: payload
    )
}

func applyProjectedState(
    _ projectedState: [String: AnyCodable],
    to state: inout HeroDefenseState
) {
    let baseline = HeroDefenseState()
    state.players = baseline.players
    state.monsters = baseline.monsters
    state.turrets = baseline.turrets
    state.base = baseline.base
    state.score = baseline.score

    if let playersObject = projectedState["players"]?.base as? [String: Any] {
        state.players = playersObject.reduce(into: [PlayerID: PlayerState]()) { result, entry in
            guard let playerObject = entry.value as? [String: Any] else {
                return
            }

            var player = PlayerState()
            if let position = decodeProjectedField(Position2.self, from: playerObject["position"]) {
                player.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: playerObject["rotation"]) {
                player.rotation = rotation
            }
            if let targetPosition = decodeProjectedField(Position2.self, from: playerObject["targetPosition"]) {
                player.targetPosition = targetPosition
            }
            if let health = playerObject["health"] as? Int {
                player.health = health
            }
            if let maxHealth = playerObject["maxHealth"] as? Int {
                player.maxHealth = maxHealth
            }
            if let weaponLevel = playerObject["weaponLevel"] as? Int {
                player.weaponLevel = weaponLevel
            }
            if let resources = playerObject["resources"] as? Int {
                player.resources = resources
            }

            result[PlayerID(entry.key)] = player
        }
    }

    if let monstersObject = projectedState["monsters"]?.base as? [String: Any] {
        state.monsters = monstersObject.reduce(into: [Int: MonsterState]()) { result, entry in
            guard let id = Int(entry.key) else { return }
            guard let monsterObject = entry.value as? [String: Any] else {
                return
            }

            var monster = MonsterState()
            if let valueID = monsterObject["id"] as? Int {
                monster.id = valueID
            }
            if let position = decodeProjectedField(Position2.self, from: monsterObject["position"]) {
                monster.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: monsterObject["rotation"]) {
                monster.rotation = rotation
            }
            if let health = monsterObject["health"] as? Int {
                monster.health = health
            }
            if let maxHealth = monsterObject["maxHealth"] as? Int {
                monster.maxHealth = maxHealth
            }

            result[id] = monster
        }
    }

    if let turretsObject = projectedState["turrets"]?.base as? [String: Any] {
        state.turrets = turretsObject.reduce(into: [Int: TurretState]()) { result, entry in
            guard let id = Int(entry.key) else { return }
            guard let turretObject = entry.value as? [String: Any] else {
                return
            }

            var turret = TurretState()
            if let valueID = turretObject["id"] as? Int {
                turret.id = valueID
            }
            if let position = decodeProjectedField(Position2.self, from: turretObject["position"]) {
                turret.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: turretObject["rotation"]) {
                turret.rotation = rotation
            }
            if let level = turretObject["level"] as? Int {
                turret.level = level
            }
            if let ownerID = turretObject["ownerID"] as? String {
                turret.ownerID = PlayerID(ownerID)
            } else {
                turret.ownerID = nil
            }

            result[id] = turret
        }
    }

    if let baseObject = projectedState["base"]?.base as? [String: Any] {
        var base = BaseState()
        if let position = decodeProjectedField(Position2.self, from: baseObject["position"]) {
            base.position = position
        }
        if let radius = decodeProjectedField(Float.self, from: baseObject["radius"]) {
            base.radius = radius
        }
        if let health = baseObject["health"] as? Int {
            base.health = health
        }
        if let maxHealth = baseObject["maxHealth"] as? Int {
            base.maxHealth = maxHealth
        }
        state.base = base
    }

    if let score = projectedState["score"]?.base as? Int {
        state.score = score
    }
}

private func decodeProjectedField<T: Decodable>(_ type: T.Type, from rawValue: Any?) -> T? {
    guard let rawValue else {
        return nil
    }

    let boxedValue: [String: Any] = ["value": rawValue]
    guard JSONSerialization.isValidJSONObject(boxedValue),
          let data = try? JSONSerialization.data(withJSONObject: boxedValue),
          let decoded = try? JSONDecoder().decode(ProjectedField<T>.self, from: data)
    else {
        return nil
    }
    return decoded.value
}

private struct ProjectedField<T: Decodable>: Decodable {
    let value: T
}

func buildFallbackShootingEvents(
    previousMonsters: [Int: MonsterState],
    previousPlayers: [PlayerID: PlayerState],
    previousTurrets: [Int: TurretState],
    currentState: HeroDefenseState
) -> [FallbackReplayEvent] {
    guard !previousMonsters.isEmpty else {
        return []
    }

    let sortedTurrets: [(Int, TurretState)] = {
        if !currentState.turrets.isEmpty {
            return currentState.turrets.sorted { $0.key < $1.key }
        }
        return previousTurrets.sorted { $0.key < $1.key }
    }()

    let sortedPlayers: [(PlayerID, PlayerState)] = {
        if !currentState.players.isEmpty {
            return currentState.players.sorted { $0.key.rawValue < $1.key.rawValue }
        }
        return previousPlayers.sorted { $0.key.rawValue < $1.key.rawValue }
    }()

    var events: [FallbackReplayEvent] = []

    for (monsterID, previousMonster) in previousMonsters.sorted(by: { $0.key < $1.key }) {
        let currentMonster = currentState.monsters[monsterID]
        let didTakeDamage: Bool
        let targetPosition: Position2

        if let currentMonster {
            didTakeDamage = currentMonster.health < previousMonster.health
            targetPosition = currentMonster.position
        } else {
            didTakeDamage = previousMonster.health > 0
            targetPosition = previousMonster.position
        }

        guard didTakeDamage else {
            continue
        }

        if let (turretID, turretState) = sortedTurrets.first {
            events.append(
                .turretFire(
                    TurretFireEvent(
                        turretID: turretID,
                        from: turretState.position,
                        to: targetPosition
                    )
                )
            )
            continue
        }

        if let (playerID, playerState) = sortedPlayers.first {
            events.append(
                .playerShoot(
                    PlayerShootEvent(
                        playerID: playerID,
                        from: playerState.position,
                        to: targetPosition
                    )
                )
            )
        }
    }

    return events
}

private struct ProjectedServerEventEnvelope: Decodable {
    let typeIdentifier: String
    let payload: AnyCodable
}

private func decodeProjectedServerEventEnvelope(_ rawEvent: AnyCodable) -> ProjectedServerEventEnvelope? {
    if let object = rawEvent.base as? [String: Any] {
        let typeIdentifier: String?
        if let rawType = object["typeIdentifier"] as? String {
            typeIdentifier = rawType
        } else if let wrappedType = object["typeIdentifier"] as? AnyCodable {
            typeIdentifier = wrappedType.base as? String
        } else {
            typeIdentifier = nil
        }
        guard let typeIdentifier else {
            return nil
        }
        guard let rawPayload = object["payload"] else {
            return nil
        }

        let payload: AnyCodable
        if let wrappedPayload = rawPayload as? AnyCodable {
            payload = wrappedPayload
        } else {
            payload = AnyCodable(rawPayload)
        }

        return ProjectedServerEventEnvelope(
            typeIdentifier: typeIdentifier,
            payload: payload
        )
    }

    guard let wrappedObject = rawEvent.base as? [String: AnyCodable] else {
        return nil
    }
    guard let typeIdentifier = wrappedObject["typeIdentifier"]?.base as? String else {
        return nil
    }
    guard let payload = wrappedObject["payload"] else {
        return nil
    }

    return ProjectedServerEventEnvelope(
        typeIdentifier: typeIdentifier,
        payload: payload
    )
}

func applyProjectedState(
    _ projectedState: [String: AnyCodable],
    to state: inout HeroDefenseState
) {
    let baseline = HeroDefenseState()
    state.players = baseline.players
    state.monsters = baseline.monsters
    state.turrets = baseline.turrets
    state.base = baseline.base
    state.score = baseline.score

    if let playersObject = projectedState["players"]?.base as? [String: Any] {
        state.players = playersObject.reduce(into: [PlayerID: PlayerState]()) { result, entry in
            guard let playerObject = entry.value as? [String: Any] else {
                return
            }

            var player = PlayerState()
            if let position = decodeProjectedField(Position2.self, from: playerObject["position"]) {
                player.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: playerObject["rotation"]) {
                player.rotation = rotation
            }
            if let targetPosition = decodeProjectedField(Position2.self, from: playerObject["targetPosition"]) {
                player.targetPosition = targetPosition
            }
            if let health = playerObject["health"] as? Int {
                player.health = health
            }
            if let maxHealth = playerObject["maxHealth"] as? Int {
                player.maxHealth = maxHealth
            }
            if let weaponLevel = playerObject["weaponLevel"] as? Int {
                player.weaponLevel = weaponLevel
            }
            if let resources = playerObject["resources"] as? Int {
                player.resources = resources
            }

            result[PlayerID(entry.key)] = player
        }
    }

    if let monstersObject = projectedState["monsters"]?.base as? [String: Any] {
        state.monsters = monstersObject.reduce(into: [Int: MonsterState]()) { result, entry in
            guard let id = Int(entry.key) else { return }
            guard let monsterObject = entry.value as? [String: Any] else {
                return
            }

            var monster = MonsterState()
            if let valueID = monsterObject["id"] as? Int {
                monster.id = valueID
            }
            if let position = decodeProjectedField(Position2.self, from: monsterObject["position"]) {
                monster.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: monsterObject["rotation"]) {
                monster.rotation = rotation
            }
            if let health = monsterObject["health"] as? Int {
                monster.health = health
            }
            if let maxHealth = monsterObject["maxHealth"] as? Int {
                monster.maxHealth = maxHealth
            }

            result[id] = monster
        }
    }

    if let turretsObject = projectedState["turrets"]?.base as? [String: Any] {
        state.turrets = turretsObject.reduce(into: [Int: TurretState]()) { result, entry in
            guard let id = Int(entry.key) else { return }
            guard let turretObject = entry.value as? [String: Any] else {
                return
            }

            var turret = TurretState()
            if let valueID = turretObject["id"] as? Int {
                turret.id = valueID
            }
            if let position = decodeProjectedField(Position2.self, from: turretObject["position"]) {
                turret.position = position
            }
            if let rotation = decodeProjectedField(Angle.self, from: turretObject["rotation"]) {
                turret.rotation = rotation
            }
            if let level = turretObject["level"] as? Int {
                turret.level = level
            }
            if let ownerID = turretObject["ownerID"] as? String {
                turret.ownerID = PlayerID(ownerID)
            } else {
                turret.ownerID = nil
            }

            result[id] = turret
        }
    }

    if let baseObject = projectedState["base"]?.base as? [String: Any] {
        var base = BaseState()
        if let position = decodeProjectedField(Position2.self, from: baseObject["position"]) {
            base.position = position
        }
        if let radius = decodeProjectedField(Float.self, from: baseObject["radius"]) {
            base.radius = radius
        }
        if let health = baseObject["health"] as? Int {
            base.health = health
        }
        if let maxHealth = baseObject["maxHealth"] as? Int {
            base.maxHealth = maxHealth
        }
        state.base = base
    }

    if let score = projectedState["score"]?.base as? Int {
        state.score = score
    }
}

private func decodeProjectedField<T: Decodable>(_ type: T.Type, from rawValue: Any?) -> T? {
    guard let rawValue else {
        return nil
    }

    let boxedValue: [String: Any] = ["value": rawValue]
    guard JSONSerialization.isValidJSONObject(boxedValue),
          let data = try? JSONSerialization.data(withJSONObject: boxedValue),
          let decoded = try? JSONDecoder().decode(ProjectedField<T>.self, from: data)
    else {
        return nil
    }
    return decoded.value
}

private struct ProjectedField<T: Decodable>: Decodable {
    let value: T
}

private func resolveReplayRecordPath(from landIDString: String) -> String? {
    let landID = LandID(landIDString)
    let parts = landID.instanceId.split(separator: ".", maxSplits: 1)
    guard parts.count == 2 else {
        return nil
    }

    let token = String(parts[1])
    guard let rawPathData = decodeBase64URL(token),
          let rawPath = String(data: rawPathData, encoding: .utf8)
    else {
        return nil
    }

    let currentDirURL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let recordsDir = ReevaluationEnvConfig.fromEnvironment().recordsDir
    let recordsDirURL = URL(fileURLWithPath: recordsDir, relativeTo: currentDirURL).standardizedFileURL
    let candidateURL = URL(fileURLWithPath: rawPath).standardizedFileURL

    guard isWithinDirectory(candidateURL, directoryURL: recordsDirURL) else {
        return nil
    }

    guard FileManager.default.fileExists(atPath: candidateURL.path) else {
        return nil
    }

    return candidateURL.path
}

private func decodeBase64URL(_ token: String) -> Data? {
    var base64 = token
        .replacingOccurrences(of: "-", with: "+")
        .replacingOccurrences(of: "_", with: "/")

    let remainder = base64.count % 4
    if remainder != 0 {
        base64 += String(repeating: "=", count: 4 - remainder)
    }

    return Data(base64Encoded: base64)
}

private func isWithinDirectory(_ fileURL: URL, directoryURL: URL) -> Bool {
    if fileURL.path == directoryURL.path {
        return true
    }

    let directoryPath = directoryURL.path.hasSuffix("/") ? directoryURL.path : "\(directoryURL.path)/"
    return fileURL.path.hasPrefix(directoryPath)
}
