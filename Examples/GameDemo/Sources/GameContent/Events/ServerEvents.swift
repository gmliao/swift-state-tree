import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Server Events

/// Server event broadcasted when a player shoots.
@Payload
public struct PlayerShootEvent: ServerEventPayload {
    public let playerID: PlayerID
    public let from: Position2
    public let to: Position2

    public init(playerID: PlayerID, from: Position2, to: Position2) {
        self.playerID = playerID
        self.from = from
        self.to = to
    }
}

/// Server event broadcasted when a turret fires.
@Payload
public struct TurretFireEvent: ServerEventPayload {
    public let turretID: Int
    public let from: Position2
    public let to: Position2

    public init(turretID: Int, from: Position2, to: Position2) {
        self.turretID = turretID
        self.from = from
        self.to = to
    }
}
