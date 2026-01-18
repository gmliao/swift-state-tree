import Foundation
import SwiftStateTree
import SwiftStateTreeDeterministicMath

// MARK: - Turret System

/// System functions for turret placement and validation
public enum TurretSystem {
    /// Check if position is valid for turret placement
    public static func isValidTurretPosition(
        _ position: Position2,
        basePosition: Position2,
        existingTurrets: [Int: TurretState],
        _ ctx: LandContext
    ) -> Bool {
        guard let configService = ctx.services.get(GameConfigProviderService.self) else {
            return false
        }
        let config = configService.provider
        
        // Check distance from base
        let distanceFromBase = position.v.distance(to: basePosition.v)
        if distanceFromBase < config.turretPlacementDistance {
            return false
        }
        
        // Check if too close to existing turrets
        for (_, turret) in existingTurrets {
            let distance = position.v.distance(to: turret.position.v)
            if distance < 3.0 {  // Minimum spacing
                return false
            }
        }
        
        // Check world bounds (convert from fixed-point to Float)
        let posX = Float(position.v.x) / 1000.0
        let posY = Float(position.v.y) / 1000.0
        if posX < 0 || posX > config.worldWidth ||
           posY < 0 || posY > config.worldHeight {
            return false
        }
        
        return true
    }
}
