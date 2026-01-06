// Examples/HummingbirdDemo/Sources/DemoContent/DeterministicMathDemoDefinitions.swift
//
// Demo definitions using DeterministicMath types to test codegen.

import SwiftStateTree
import SwiftStateTreeDeterministicMath

/// Demo state using DeterministicMath types for testing codegen.
@StateNodeBuilder
public struct DeterministicMathDemoState: StateNodeProtocol {
    /// Player positions using Position2.
    @Sync(.broadcast)
    var playerPositions: [PlayerID: Position2] = [:]
    
    /// Player velocities using Velocity2.
    @Sync(.broadcast)
    var playerVelocities: [PlayerID: Velocity2] = [:]
    
    /// Player accelerations using Acceleration2.
    @Sync(.broadcast)
    var playerAccelerations: [PlayerID: Acceleration2] = [:]
    
    /// Direct IVec2 usage.
    @Sync(.broadcast)
    var directVector: IVec2 = IVec2(x: 0.0, y: 0.0)
    
    public init() {}
}

/// Demo Land using DeterministicMath types.
public struct DeterministicMathDemo {
    public static func makeLand() -> LandDefinition<DeterministicMathDemoState> {
        Land(
            "deterministic-math-demo",
            using: DeterministicMathDemoState.self
        ) {
            AccessControl {
                AllowPublic(true)
                MaxPlayers(10)
            }
            
            Lifetime {
                // Minimal lifetime for testing codegen
                Tick(every: .milliseconds(1000)) { (_: inout DeterministicMathDemoState, _: LandContext) in
                    // Empty tick handler for testing
                }
            }
        }
    }
}
