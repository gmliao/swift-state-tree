// Tests/SwiftStateTreeDeterministicMathTests/MoveTowardsOverflowTests.swift
//
// Tests for Position2.moveTowards to verify it handles large distances without overflow.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("Position2.moveTowards handles large distances near WORLD_MAX_COORDINATE")
func testMoveTowardsLargeDistanceNearWorldMax() {
    // Test with positions near WORLD_MAX_COORDINATE
    // WORLD_MAX_COORDINATE ≈ ±1,073,741.823 Float units
    let maxCoord = FixedPoint.WORLD_MAX_COORDINATE
    let nearMaxCoord = Int32((Int64(maxCoord) * 9) / 10)
    
    let start = Position2(v: IVec2(fixedPointX: -nearMaxCoord, fixedPointY: -nearMaxCoord))
    let target = Position2(v: IVec2(fixedPointX: nearMaxCoord, fixedPointY: nearMaxCoord))
    let maxDistance: Float = 1.0
    
    // This should not crash or overflow
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should move towards target
    let movedDistance = (moved.v - start.v).magnitude()
    #expect(movedDistance <= maxDistance + 0.1, 
        "Should move approximately maxDistance, got \(movedDistance)")
    
    // Should be closer to target
    let distanceToTarget = (target.v - moved.v).magnitude()
    let initialDistance = (target.v - start.v).magnitude()
    #expect(distanceToTarget < initialDistance, 
        "Should be closer to target after movement")
}

@Test("Position2.moveTowards handles distances exceeding maxSafeValue")
func testMoveTowardsDistanceExceedingMaxSafeValue() {
    // Create a distance that exceeds FixedPoint.maxSafeValue
    // maxSafeValue ≈ 2,147,483.647
    // Diagonal distance from (-max, -max) to (max, max) would be:
    // sqrt(2) * 2 * max ≈ 3,037,000 which exceeds maxSafeValue
    
    let maxCoord = FixedPoint.WORLD_MAX_COORDINATE
    let start = Position2(v: IVec2(fixedPointX: -maxCoord, fixedPointY: -maxCoord))
    let target = Position2(v: IVec2(fixedPointX: maxCoord, fixedPointY: maxCoord))
    let maxDistance: Float = 1.0
    
    // Calculate expected distance
    let maxCoordFloat = FixedPoint.dequantize(maxCoord)
    let expectedDistance = sqrt(2.0) * 2.0 * maxCoordFloat
    print("Expected distance: \(expectedDistance)")
    print("maxSafeValue: \(FixedPoint.maxSafeValue)")
    
    // This should not crash - distance quantization should be handled safely
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should still work correctly
    let movedDistance = (moved.v - start.v).magnitude()
    #expect(movedDistance <= maxDistance + 0.1)
}
