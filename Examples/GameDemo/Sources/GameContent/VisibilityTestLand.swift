// Examples/GameDemo/Sources/GameContent/VisibilityTestLand.swift
//
// A test land for per-player projection that changes every tick (#65). Entities move; each one
// is synced only to the viewers within a fixed radius of it, so entities keep entering and
// leaving each player's view. Hero Defense syncs only broadcast fields, so this is the land
// that exercises per-player filtering under movement, at load and under replay.

import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Layout

public enum VisibilityTestConfig {
    public static let landType = "visibility-test"
    public static let tickIntervalMs: Int64 = 50
    /// Entities in the land by default; ids `e0` ... `e39` (`VISIBILITY_TEST_ENTITY_COUNT`).
    public static let entityCount = 40
    /// By default a viewer sees an entity within this distance, world units
    /// (`VISIBILITY_TEST_VIEW_RADIUS`).
    public static let viewRadius: Float = 15
    /// The arena is `[0, arenaSize]` on both axes; entities bounce off its edges.
    public static let arenaSize: Float = 100
    /// Viewer positions of the first join slots. A player takes the lowest free slot; past the
    /// table, slots take `gridSlots`.
    public static let viewerSlots: [Position2] = [
        Position2(x: 20, y: 20),
        Position2(x: 80, y: 20),
        Position2(x: 20, y: 80),
        Position2(x: 80, y: 80),
    ]
    /// Slots past `viewerSlots`: a 4 × 4 grid at 25-unit spacing, row by row, wrapping after 16,
    /// so up to `maxPlayers` viewers don't share a position.
    public static let gridSlots = 16
    /// Where `ParkEntitiesAction` puts every entity: out of the first four slots' view at the
    /// default radius.
    public static let parkPosition = Position2(x: 50, y: 50)

    public static let maxPlayers = 16

    /// The viewer position of join slot `slot`.
    public static func viewerPosition(slot: Int) -> Position2 {
        if slot < viewerSlots.count { return viewerSlots[slot] }
        let cell = (slot - viewerSlots.count) % gridSlots
        return Position2(x: 12.5 + 25 * Float(cell % 4), y: 12.5 + 25 * Float(cell / 4))
    }
}

/// Environment keys of the land's layout, read once per process (`VisibilityTestSettings.current`).
/// Re-evaluation must run with the same values as the recorded run.
public enum VisibilityTestEnvKeys {
    /// Entities in the land. Default 40, 1...4096 (start positions stay distinct); outside that
    /// range the settings throw.
    public static let entityCount = "VISIBILITY_TEST_ENTITY_COUNT"
    /// The view radius, world units. Default 15, 1...200; outside that range the settings throw.
    public static let viewRadius = "VISIBILITY_TEST_VIEW_RADIUS"
    /// `radius` (default): each player receives the entities within its view. `all`: each
    /// player receives every entity, through the same per-player policy; visibility is still
    /// computed everywhere, so state, counters and tick work don't change.
    public static let filter = "VISIBILITY_TEST_FILTER"

    public static let all = [entityCount, viewRadius, filter]
}

/// Which entities the per-player policy sends (`VISIBILITY_TEST_FILTER`).
public enum VisibilityFilter: String, Sendable, CaseIterable {
    case radius
    case all
}

public struct VisibilityTestSettingsError: Error, CustomStringConvertible {
    public let description: String
}

/// The land's layout knobs.
public struct VisibilityTestSettings: Sendable, Equatable {
    public var entityCount: Int
    public var viewRadius: Float
    public var filter: VisibilityFilter

    public init(
        entityCount: Int = VisibilityTestConfig.entityCount,
        viewRadius: Float = VisibilityTestConfig.viewRadius,
        filter: VisibilityFilter = .radius
    ) {
        self.entityCount = min(4096, max(1, entityCount))
        self.viewRadius = min(200, max(1, viewRadius))
        self.filter = filter
    }

    /// Throws on a value that is malformed or out of range, or a `VISIBILITY_TEST_FILTER` that is
    /// neither `radius` nor `all`, so a typo or a clamp can't run another cell than the one asked.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) throws -> VisibilityTestSettings {
        let filterName = EnvHelpers.getEnvString(key: VisibilityTestEnvKeys.filter, defaultValue: VisibilityFilter.radius.rawValue, environment: environment)
        guard let filter = VisibilityFilter(rawValue: filterName) else {
            throw VisibilityTestSettingsError(description: "\(VisibilityTestEnvKeys.filter)=\(filterName): expected one of \(VisibilityFilter.allCases.map(\.rawValue))")
        }
        var entityCount = VisibilityTestConfig.entityCount
        if let raw = environment[VisibilityTestEnvKeys.entityCount] {
            guard let value = Int(raw), entityCountRange.contains(value) else {
                throw VisibilityTestSettingsError(description: "\(VisibilityTestEnvKeys.entityCount)=\(raw): expected an integer in \(entityCountRange)")
            }
            entityCount = value
        }
        var viewRadius = VisibilityTestConfig.viewRadius
        if let raw = environment[VisibilityTestEnvKeys.viewRadius] {
            guard let value = Float(raw), viewRadiusRange.contains(value) else {
                throw VisibilityTestSettingsError(description: "\(VisibilityTestEnvKeys.viewRadius)=\(raw): expected a number in \(viewRadiusRange)")
            }
            viewRadius = value
        }
        return VisibilityTestSettings(entityCount: entityCount, viewRadius: viewRadius, filter: filter)
    }

    public static let entityCountRange = 1...4096
    public static let viewRadiusRange: ClosedRange<Float> = 1...200

    /// The settings as a re-evaluation record's metadata carries them.
    public var recordMetadata: [String: String] {
        [
            VisibilityTestEnvKeys.entityCount: "\(entityCount)",
            VisibilityTestEnvKeys.viewRadius: "\(viewRadius)",
            VisibilityTestEnvKeys.filter: filter.rawValue,
        ]
    }

    /// Why a record made with `metadata` can't be replayed with these settings, or nil.
    ///
    /// Only the benchmark's records carry the settings. A record without them (a live server's,
    /// or one made before they were recorded) can't say what it was made with, so it is replayed
    /// only with the default settings, which every such record was made with unless its server
    /// ran with `VISIBILITY_TEST_*` set.
    public func recordMismatch(_ metadata: [String: String]) -> String? {
        let keys = recordMetadata.keys.sorted()
        if keys.allSatisfy({ metadata[$0] == nil }) {
            guard self != VisibilityTestSettings() else { return nil }
            return "the record doesn't carry its settings, so it replays only with the defaults (\(VisibilityTestSettings().recordMetadata.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: ", ")))"
        }
        let differing = keys.compactMap { key -> String? in
            let recorded = metadata[key] ?? "(none)"
            guard recorded != recordMetadata[key] else { return nil }
            return "\(key): recorded \(recorded), now \(recordMetadata[key] ?? "")"
        }
        return differing.isEmpty ? nil : differing.joined(separator: "; ")
    }

    /// This process's settings, read once. The per-player policy reads `filter` from here, since
    /// a sync policy is declared on the state type, not per land.
    public static let current: VisibilityTestSettings = {
        do {
            return try fromEnvironment()
        } catch {
            fatalError("\(error)")
        }
    }()
}

// MARK: - State

/// One moving entity. Only its id and position are synced; its step and who sees it stay on the
/// server. The E2E schema conformance check fails if `step` or `visibleTo` reach a client (#175).
@StateNodeBuilder
@SnapshotConvertible
public struct VisibleEntity: StateNodeProtocol {
    @Sync(.broadcast)
    var id: String = ""

    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0, y: 0)

    /// Per-tick step; its sign flips at the arena edges.
    @Sync(.serverOnly)
    var step: IVec2 = IVec2(x: 0, y: 0)

    /// Viewers within `viewRadius`, sorted by id.
    @Sync(.serverOnly)
    var visibleTo: [PlayerID] = []

    public init() {}
}

@SnapshotConvertible
public struct Viewer: StateProtocol {
    public var slot: Int
    public var position: Position2

    public init(slot: Int, position: Position2) {
        self.slot = slot
        self.position = position
    }

    public init() {
        self.init(slot: 0, position: Position2(x: 0, y: 0))
    }
}

@StateNodeBuilder
public struct VisibilityTestState: StateNodeProtocol, StateFromSnapshotDecodable {
    /// Each player receives only the entities whose `visibleTo` contains them.
    @Sync(.perPlayer({ (entities: [String: VisibleEntity], playerID: PlayerID) in
        VisibilityTest.entities(entities, sentTo: playerID, filter: VisibilityTestSettings.current.filter)
    }))
    public var entities: [String: VisibleEntity] = [:]

    @Sync(.broadcast)
    public var viewers: [PlayerID: Viewer] = [:]

    /// Whether entities move on each tick (`SetMotionAction`).
    @Sync(.broadcast)
    public var motion: Bool = true

    /// (entity, viewer) pairs that became visible / stopped being visible, cumulative. They
    /// mark the windows with many view changes in load-test output.
    @Sync(.broadcast)
    public var viewEntries: Int = 0

    @Sync(.broadcast)
    public var viewExits: Int = 0

    @Sync(.broadcast)
    public var tickCount: Int64 = 0

    public init() {}
}

// MARK: - Actions

/// Stops or restarts entity movement, so a scenario can place entities by hand.
@Payload
public struct SetMotionAction: ActionPayload {
    public typealias Response = VisibilityTestResponse
    public let enabled: Bool

    public init(enabled: Bool) {
        self.enabled = enabled
    }
}

/// Puts every entity at `VisibilityTestConfig.parkPosition`, out of every viewer slot's view.
@Payload
public struct ParkEntitiesAction: ActionPayload {
    public typealias Response = VisibilityTestResponse

    public init() {}
}

/// Moves one entity through `positions`, in order, within one input. Visibility is recomputed
/// after each move, so an exit and re-entry in one input counts both.
@Payload
public struct PlaceEntityAction: ActionPayload {
    public typealias Response = VisibilityTestResponse
    public let id: String
    public let positions: [Position2]

    public init(id: String, positions: [Position2]) {
        self.id = id
        self.positions = positions
    }
}

@Payload
public struct VisibilityTestResponse: ResponsePayload {
    public let viewEntries: Int
    public let viewExits: Int

    public init(viewEntries: Int, viewExits: Int) {
        self.viewEntries = viewEntries
        self.viewExits = viewExits
    }
}

/// Moves the calling player's viewer.
@Payload
public struct MoveViewerEvent: ClientEventPayload {
    public let position: Position2

    public init(position: Position2) {
        self.position = position
    }
}

// MARK: - Land

public enum VisibilityTest {
    /// The entities the per-player policy sends to `playerID`.
    public static func entities(_ entities: [String: VisibleEntity], sentTo playerID: PlayerID, filter: VisibilityFilter) -> [String: VisibleEntity] {
        switch filter {
        case .radius: return entities.filter { $0.value.visibleTo.contains(playerID) }
        case .all: return entities
        }
    }

    /// `settings`' entity count and radius apply to this land; its filter is the process's
    /// (`VisibilityTestSettings.current`), as the policy is declared on the state type.
    public static func makeLand(settings: VisibilityTestSettings = .current) -> LandDefinition<VisibilityTestState> {
        Land(VisibilityTestConfig.landType, using: VisibilityTestState.self) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(VisibilityTestConfig.maxPlayers)
            }

            ClientEvents {
                Register(MoveViewerEvent.self)
            }

            Rules {
                OnJoin { (state: inout VisibilityTestState, ctx: LandContext) in
                    spawnEntitiesIfNeeded(&state, settings: settings)
                    let taken = Set(state.viewers.values.map(\.slot))
                    let slot = (0...).first { !taken.contains($0) } ?? 0
                    state.viewers[ctx.playerID] = Viewer(slot: slot, position: VisibilityTestConfig.viewerPosition(slot: slot))
                    updateVisibility(&state, settings: settings)
                }

                OnLeave { (state: inout VisibilityTestState, ctx: LandContext) in
                    state.viewers.removeValue(forKey: ctx.playerID)
                    updateVisibility(&state, settings: settings)
                }

                HandleAction(SetMotionAction.self) { (state: inout VisibilityTestState, action: SetMotionAction, _: LandContext) in
                    state.motion = action.enabled
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleAction(ParkEntitiesAction.self) { (state: inout VisibilityTestState, _: ParkEntitiesAction, _: LandContext) in
                    spawnEntitiesIfNeeded(&state, settings: settings)
                    for id in state.entities.keys {
                        state.entities[id]?.position = VisibilityTestConfig.parkPosition
                    }
                    updateVisibility(&state, settings: settings)
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleAction(PlaceEntityAction.self) { (state: inout VisibilityTestState, action: PlaceEntityAction, _: LandContext) in
                    spawnEntitiesIfNeeded(&state, settings: settings)
                    guard state.entities[action.id] != nil else {
                        throw VisibilityTestError.unknownEntity(action.id)
                    }
                    for position in action.positions {
                        state.entities[action.id]?.position = position
                        updateVisibility(&state, settings: settings)
                    }
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleEvent(MoveViewerEvent.self) { (state: inout VisibilityTestState, event: MoveViewerEvent, ctx: LandContext) in
                    guard state.viewers[ctx.playerID] != nil else { return }
                    state.viewers[ctx.playerID]?.position = event.position
                    updateVisibility(&state, settings: settings)
                }
            }

            Lifetime {
                Tick(every: .milliseconds(VisibilityTestConfig.tickIntervalMs)) { (state: inout VisibilityTestState, ctx: LandContext) in
                    state.tickCount = ctx.tickId ?? state.tickCount + 1
                    spawnEntitiesIfNeeded(&state, settings: settings)
                    guard state.motion else { return }
                    for id in state.entities.keys.sorted() {
                        guard var entity = state.entities[id] else { continue }
                        moveWithBounce(&entity)
                        state.entities[id] = entity
                    }
                    updateVisibility(&state, settings: settings)
                }
            }
        }
    }

    /// Creates the entities on first use, at deterministic positions and steps.
    static func spawnEntitiesIfNeeded(_ state: inout VisibilityTestState, settings: VisibilityTestSettings) {
        guard state.entities.isEmpty else { return }
        let size = VisibilityTestConfig.arenaSize
        for index in 0..<settings.entityCount {
            var entity = VisibleEntity()
            entity.id = "e\(index)"
            // Spread over the arena with two coprime strides; steps of 0.3 to 1.2 units per tick
            // in all four diagonal directions. Within a hundred, x is unique (37 is coprime with
            // 100); each further hundred is offset by its own fraction (0.01 × its number, below
            // 1 up to 100 hundreds), so no two entities start at the same x. The first 100 are
            // unchanged.
            let offset = Float(index / 100) / 100
            entity.position = Position2(
                x: Float((index * 37) % Int(size)) + offset,
                y: Float((index * 61) % Int(size)) + offset
            )
            let speedX = Float(3 + (index % 10)) / 10
            let speedY = Float(3 + ((index * 7) % 10)) / 10
            entity.step = IVec2(x: index % 2 == 0 ? speedX : -speedX, y: index % 4 < 2 ? speedY : -speedY)
            state.entities[entity.id] = entity
        }
    }

    /// One step, reflecting the step's sign at the arena edges.
    static func moveWithBounce(_ entity: inout VisibleEntity) {
        let bounds = IVec2(x: VisibilityTestConfig.arenaSize, y: VisibilityTestConfig.arenaSize)
        var next = entity.position.v + entity.step
        var step = entity.step
        if next.x < 0 || next.x > bounds.x {
            step = IVec2(x: -step.floatX, y: step.floatY)
            next = entity.position.v + step
        }
        if next.y < 0 || next.y > bounds.y {
            step = IVec2(x: step.floatX, y: -step.floatY)
            next = entity.position.v + step
        }
        entity.step = step
        entity.position = Position2(v: next)
    }

    /// Recomputes every entity's viewers and counts the changes.
    static func updateVisibility(_ state: inout VisibilityTestState, settings: VisibilityTestSettings) {
        let viewers = state.viewers.sorted { $0.key.rawValue < $1.key.rawValue }
        for id in state.entities.keys.sorted() {
            guard var entity = state.entities[id] else { continue }
            let visibleTo = viewers
                .filter { $0.value.position.isWithinDistance(to: entity.position, threshold: settings.viewRadius) }
                .map(\.key)
            guard visibleTo != entity.visibleTo else { continue }
            let before = Set(entity.visibleTo)
            let after = Set(visibleTo)
            state.viewEntries += after.subtracting(before).count
            state.viewExits += before.subtracting(after).count
            entity.visibleTo = visibleTo
            state.entities[id] = entity
        }
    }
}

public enum VisibilityTestError: Error, Equatable {
    case unknownEntity(String)
}
