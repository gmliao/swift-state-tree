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
    /// Entities in the land; ids `e0` ... `e39`.
    public static let entityCount = 40
    /// A viewer sees an entity within this distance (world units).
    public static let viewRadius: Float = 15
    /// The arena is `[0, arenaSize]` on both axes; entities bounce off its edges.
    public static let arenaSize: Float = 100
    /// Viewer positions by join slot. A player takes the lowest free slot; past the table the
    /// slots wrap around.
    public static let viewerSlots: [Position2] = [
        Position2(x: 20, y: 20),
        Position2(x: 80, y: 20),
        Position2(x: 20, y: 80),
        Position2(x: 80, y: 80),
    ]
    /// Where `ParkEntitiesAction` puts every entity: out of every slot's view.
    public static let parkPosition = Position2(x: 50, y: 50)

    public static let maxPlayers = 16
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
        entities.filter { $0.value.visibleTo.contains(playerID) }
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
    public static func makeLand() -> LandDefinition<VisibilityTestState> {
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
                    spawnEntitiesIfNeeded(&state)
                    let taken = Set(state.viewers.values.map(\.slot))
                    let slot = (0...).first { !taken.contains($0) } ?? 0
                    let slots = VisibilityTestConfig.viewerSlots
                    state.viewers[ctx.playerID] = Viewer(slot: slot, position: slots[slot % slots.count])
                    updateVisibility(&state)
                }

                OnLeave { (state: inout VisibilityTestState, ctx: LandContext) in
                    state.viewers.removeValue(forKey: ctx.playerID)
                    updateVisibility(&state)
                }

                HandleAction(SetMotionAction.self) { (state: inout VisibilityTestState, action: SetMotionAction, _: LandContext) in
                    state.motion = action.enabled
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleAction(ParkEntitiesAction.self) { (state: inout VisibilityTestState, _: ParkEntitiesAction, _: LandContext) in
                    spawnEntitiesIfNeeded(&state)
                    for id in state.entities.keys {
                        state.entities[id]?.position = VisibilityTestConfig.parkPosition
                    }
                    updateVisibility(&state)
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleAction(PlaceEntityAction.self) { (state: inout VisibilityTestState, action: PlaceEntityAction, _: LandContext) in
                    spawnEntitiesIfNeeded(&state)
                    guard state.entities[action.id] != nil else {
                        throw VisibilityTestError.unknownEntity(action.id)
                    }
                    for position in action.positions {
                        state.entities[action.id]?.position = position
                        updateVisibility(&state)
                    }
                    return VisibilityTestResponse(viewEntries: state.viewEntries, viewExits: state.viewExits)
                }

                HandleEvent(MoveViewerEvent.self) { (state: inout VisibilityTestState, event: MoveViewerEvent, ctx: LandContext) in
                    guard state.viewers[ctx.playerID] != nil else { return }
                    state.viewers[ctx.playerID]?.position = event.position
                    updateVisibility(&state)
                }
            }

            Lifetime {
                Tick(every: .milliseconds(VisibilityTestConfig.tickIntervalMs)) { (state: inout VisibilityTestState, ctx: LandContext) in
                    state.tickCount = ctx.tickId ?? state.tickCount + 1
                    spawnEntitiesIfNeeded(&state)
                    guard state.motion else { return }
                    for id in state.entities.keys.sorted() {
                        guard var entity = state.entities[id] else { continue }
                        moveWithBounce(&entity)
                        state.entities[id] = entity
                    }
                    updateVisibility(&state)
                }
            }
        }
    }

    /// Creates the entities on first use, at deterministic positions and steps.
    static func spawnEntitiesIfNeeded(_ state: inout VisibilityTestState) {
        guard state.entities.isEmpty else { return }
        let size = VisibilityTestConfig.arenaSize
        for index in 0..<VisibilityTestConfig.entityCount {
            var entity = VisibleEntity()
            entity.id = "e\(index)"
            // Spread over the arena with two coprime strides; steps of 0.3 to 1.2 units per tick
            // in all four diagonal directions.
            entity.position = Position2(
                x: Float((index * 37) % Int(size)),
                y: Float((index * 61) % Int(size))
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
    static func updateVisibility(_ state: inout VisibilityTestState) {
        let viewers = state.viewers.sorted { $0.key.rawValue < $1.key.rawValue }
        for id in state.entities.keys.sorted() {
            guard var entity = state.entities[id] else { continue }
            let visibleTo = viewers
                .filter { $0.value.position.isWithinDistance(to: entity.position, threshold: VisibilityTestConfig.viewRadius) }
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
