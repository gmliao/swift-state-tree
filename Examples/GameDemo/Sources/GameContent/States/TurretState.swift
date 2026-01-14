import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Turret State

/// Turret state with position, level, and targeting.
@StateNodeBuilder
public struct TurretState: StateNodeProtocol {
    /// Unique turret ID
    @Sync(.broadcast)
    var id: Int = 0
    
    /// Turret position in 2D world
    @Sync(.broadcast)
    var position: Position2 = Position2(x: 0.0, y: 0.0)
    
    /// Turret rotation angle (facing direction)
    @Sync(.broadcast)
    var rotation: Angle = Angle(degrees: 0.0)
    
    /// Turret level (0 = base)
    @Sync(.broadcast)
    var level: Int = 0
    
    /// Last fire tick (for fire rate limiting)
    @Sync(.serverOnly)
    var lastFireTick: Int64 = 0
    
    /// Owner player ID (who placed this turret)
    @Sync(.broadcast)
    var ownerID: PlayerID? = nil
    
    public init() {}
}
