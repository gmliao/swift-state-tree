// Tests/SwiftStateTreeDeterministicMathTests/IVec2PrecisionTests.swift
//
// Tests for IVec2 precision issues, especially with small scale factors.
// These tests ensure that scaled(by:) and normalizedVec() work correctly
// even with small values that might cause quantization precision loss.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

// MARK: - scaled(by:) Precision Tests

@Test("IVec2.scaled(by:) handles small scale factors correctly")
func testIVec2ScaledWithSmallFactor() {
    // Test with a small scale factor similar to moveTowards scenario
    let direction = IVec2(x: 10.342, y: 7.066)
    let scale: Float = 0.07983785  // Small scale factor (1.0 / 12.525)
    
    let scaled = direction.scaled(by: scale)
    
    // Expected: (10.342, 7.066) * 0.07983785 ≈ (0.826, 0.564)
    // With quantization: scale = 79 (0.079 * 1000), so result ≈ (817, 558) raw
    // But we need to verify it's close to expected value
    let expectedX: Float = 10.342 * scale
    let expectedY: Float = 7.066 * scale
    
    // Allow some tolerance for quantization
    let tolerance: Float = 0.01
    #expect(abs(scaled.floatX - expectedX) < tolerance)
    #expect(abs(scaled.floatY - expectedY) < tolerance)
}

@Test("IVec2.scaled(by:) handles very small scale factors")
func testIVec2ScaledWithVerySmallFactor() {
    let direction = IVec2(x: 100.0, y: 50.0)
    let scale: Float = 0.001  // Very small scale
    
    let scaled = direction.scaled(by: scale)
    
    // Expected: (100.0, 50.0) * 0.001 = (0.1, 0.05)
    #expect(abs(scaled.floatX - 0.1) < 0.01)
    #expect(abs(scaled.floatY - 0.05) < 0.01)
}

@Test("IVec2.scaled(by:) handles large scale factors")
func testIVec2ScaledWithLargeFactor() {
    let direction = IVec2(x: 1.0, y: 2.0)
    let scale: Float = 10.0  // Large scale
    
    let scaled = direction.scaled(by: scale)
    
    // Expected: (1.0, 2.0) * 10.0 = (10.0, 20.0)
    #expect(abs(scaled.floatX - 10.0) < 0.01)
    #expect(abs(scaled.floatY - 20.0) < 0.01)
}

@Test("IVec2.scaled(by:) precision test with realistic movement scenario")
func testIVec2ScaledPrecisionRealisticScenario() {
    // Simulate realistic movement: direction from (64.0, 36.0) to (74.342, 43.066)
    let direction = IVec2(x: 10.342, y: 7.066)
    let distance: Float = 12.525387
    let moveSpeed: Float = 1.0
    let scale = moveSpeed / distance  // ≈ 0.07983785
    
    let scaled = direction.scaled(by: scale)
    
    // The scaled vector should have magnitude approximately equal to moveSpeed
    let scaledMagnitude = scaled.magnitude()
    #expect(abs(scaledMagnitude - moveSpeed) < 0.1, "Scaled magnitude should be close to moveSpeed")
    
    // The direction should be preserved (normalized vectors should be similar)
    let directionNormalized = direction.normalized()
    let scaledNormalized = scaled.normalized()
    let dotProduct = directionNormalized.x * scaledNormalized.x + directionNormalized.y * scaledNormalized.y
    #expect(dotProduct > 0.99, "Direction should be preserved (dot product close to 1.0)")
}

// MARK: - normalizedVec() Precision Tests

@Test("IVec2.normalizedVec() handles small vectors correctly")
func testIVec2NormalizedVecWithSmallVector() {
    let v = IVec2(x: 0.1, y: 0.1)
    
    let normalized = v.normalizedVec()
    
    // For a small vector, normalizedVec might return zero vector if magnitude < 0.0001
    // This is expected behavior per the implementation
    let magnitude = v.magnitude()
    if magnitude < 0.0001 {
        #expect(normalized.x == 0)
        #expect(normalized.y == 0)
    } else {
        // If normalized, magnitude should be approximately 1.0
        let normalizedMagnitude = normalized.magnitude()
        #expect(abs(normalizedMagnitude - 1.0) < 0.1)
    }
}

@Test("IVec2.normalizedVec() handles normal-sized vectors correctly")
func testIVec2NormalizedVecWithNormalVector() {
    let v = IVec2(x: 3.0, y: 4.0)  // Magnitude = 5.0
    
    let normalized = v.normalizedVec()
    
    // Normalized should be approximately (0.6, 0.8)
    #expect(abs(normalized.floatX - 0.6) < 0.01)
    #expect(abs(normalized.floatY - 0.8) < 0.01)
    
    // Magnitude should be approximately 1.0
    let magnitude = normalized.magnitude()
    #expect(abs(magnitude - 1.0) < 0.01)
}

@Test("IVec2.normalizedVec() handles large vectors correctly")
func testIVec2NormalizedVecWithLargeVector() {
    let v = IVec2(x: 100.0, y: 200.0)
    
    let normalized = v.normalizedVec()
    
    // Magnitude should be approximately 1.0
    let magnitude = normalized.magnitude()
    #expect(abs(magnitude - 1.0) < 0.01)
    
    // Direction should be preserved
    let vNormalized = v.normalized()
    #expect(abs(normalized.floatX - vNormalized.x) < 0.01)
    #expect(abs(normalized.floatY - vNormalized.y) < 0.01)
}

// MARK: - moveTowards Precision Tests

@Test("Position2.moveTowards precision test with small distances")
func testPosition2MoveTowardsSmallDistance() {
    let start = Position2(x: 64.0, y: 36.0)
    let target = Position2(x: 64.1, y: 36.1)  // Very close
    let maxDistance: Float = 1.0
    
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should either reach target or move by maxDistance
    let movedDistance = start.isWithinDistance(to: moved, threshold: maxDistance + 0.1)
    #expect(movedDistance == true, "Moved distance should be within maxDistance")
    
    // Should not overshoot target
    let distanceToTarget = (target.v - moved.v).magnitude()
    let distanceFromStart = (moved.v - start.v).magnitude()
    #expect(distanceToTarget <= (target.v - start.v).magnitude(), "Should not overshoot target")
    #expect(distanceFromStart <= maxDistance + 0.1, "Should not move more than maxDistance")
}

@Test("Position2.moveTowards precision test with medium distances")
func testPosition2MoveTowardsMediumDistance() {
    let start = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 10.0, y: 5.0)
    let maxDistance: Float = 1.0
    
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should move approximately maxDistance towards target
    let movedDistance = (moved.v - start.v).magnitude()
    #expect(abs(movedDistance - maxDistance) < 0.1, "Should move approximately maxDistance")
    
    // Should be closer to target than start
    let distanceToTarget = (target.v - moved.v).magnitude()
    let initialDistance = (target.v - start.v).magnitude()
    #expect(distanceToTarget < initialDistance, "Should be closer to target")
}

@Test("Position2.moveTowards precision test with large distances")
func testPosition2MoveTowardsLargeDistance() {
    let start = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 100.0, y: 100.0)
    let maxDistance: Float = 1.0
    
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should move exactly maxDistance (not overshoot)
    let movedDistance = (moved.v - start.v).magnitude()
    #expect(abs(movedDistance - maxDistance) < 0.1, "Should move exactly maxDistance")
    
    // Should still have target
    let distanceToTarget = (target.v - moved.v).magnitude()
    let initialDistance = (target.v - start.v).magnitude()
    #expect(distanceToTarget < initialDistance, "Should be closer to target")
}

@Test("Position2.moveTowards precision test - multiple steps consistency")
func testPosition2MoveTowardsMultipleStepsConsistency() {
    let start = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 10.0, y: 0.0)
    let maxDistance: Float = 1.0
    
    var current = start
    var previousDistance: Float = (target.v - current.v).magnitude()
    
    // Simulate 5 steps
    for step in 1...5 {
        let moved = current.moveTowards(target: target, maxDistance: maxDistance)
        let currentDistance = (target.v - moved.v).magnitude()
        
        // Each step should move closer (or reach target)
        #expect(currentDistance <= previousDistance, "Step \(step): Should move closer to target")
        
        // Each step should move approximately maxDistance (unless reaching target)
        let stepDistance = (moved.v - current.v).magnitude()
        if currentDistance > maxDistance {
            #expect(abs(stepDistance - maxDistance) < 0.1, "Step \(step): Should move approximately maxDistance")
        }
        
        current = moved
        previousDistance = currentDistance
    }
}

// MARK: - Edge Case Tests

@Test("IVec2.scaled(by:) with zero vector")
func testIVec2ScaledWithZeroVector() {
    let zero = IVec2.zero
    let scaled = zero.scaled(by: 5.0)
    
    #expect(scaled.x == 0)
    #expect(scaled.y == 0)
}

@Test("IVec2.scaled(by:) with zero scale")
func testIVec2ScaledWithZeroScale() {
    let v = IVec2(x: 10.0, y: 20.0)
    let scaled = v.scaled(by: 0.0)
    
    #expect(scaled.x == 0)
    #expect(scaled.y == 0)
}

@Test("IVec2.normalizedVec() with zero vector")
func testIVec2NormalizedVecWithZeroVector() {
    let zero = IVec2.zero
    let normalized = zero.normalizedVec()
    
    // Should return zero vector when magnitude is zero
    #expect(normalized.x == 0)
    #expect(normalized.y == 0)
}
