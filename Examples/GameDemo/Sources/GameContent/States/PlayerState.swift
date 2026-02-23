import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Player State

/// Player state with position, rotation, movement, weapon, and resources.
@StateNodeBuilder
@SnapshotConvertible
public struct PlayerState: StateNodeProtocol {
    /// Player position in 2D world (fixed-point: 1000 = 1.0)
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0.0, y: 0.0)

    /// Player rotation angle
    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0.0)

    /// Target position for movement (nil when not moving)
    @Sync(.broadcast)
    var targetPosition: Position2? = nil
    
    /// Player health
    @Sync(.broadcast)
    var health: Int = 100
    
    /// Player max health
    @Sync(.broadcast)
    var maxHealth: Int = 100
    
    /// Weapon level (0 = base)
    @Sync(.broadcast)
    var weaponLevel: Int = 0
    
    /// Resources (earned from defeating monsters)
    @Sync(.broadcast)
    var resources: Int = 0
    
    /// Last fire tick (for fire rate limiting)
    @Sync(.serverOnly)
    var lastFireTick: Int64 = 0

    public init() {}
}
