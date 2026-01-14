import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Client Events

/// Client event to move player to a target position.
@Payload
public struct MoveToEvent: ClientEventPayload {
    public let target: Position2

    public init(target: Position2) {
        self.target = target
    }

    /// Convenience initializer from Float coordinates
    public init(x: Float, y: Float) {
        target = Position2(x: x, y: y)
    }
}

/// Client event to shoot (uses current rotation/aiming direction).
@Payload
public struct ShootEvent: ClientEventPayload {
    public init() {}
}

/// Client event to update player rotation (facing direction).
@Payload
public struct UpdateRotationEvent: ClientEventPayload {
    public let rotation: Angle

    public init(rotation: Angle) {
        self.rotation = rotation
    }

    /// Convenience initializer from radians
    public init(radians: Float) {
        rotation = Angle(radians: radians)
    }
}

/// Client event to place a turret at a position.
@Payload
public struct PlaceTurretEvent: ClientEventPayload {
    public let position: Position2

    public init(position: Position2) {
        self.position = position
    }

    /// Convenience initializer from Float coordinates
    public init(x: Float, y: Float) {
        position = Position2(x: x, y: y)
    }
}

/// Client event to upgrade weapon.
@Payload
public struct UpgradeWeaponEvent: ClientEventPayload {
    public init() {}
}

/// Client event to upgrade a turret.
@Payload
public struct UpgradeTurretEvent: ClientEventPayload {
    public let turretID: Int

    public init(turretID: Int) {
        self.turretID = turretID
    }
}
