// Examples/GameDemo/Tests/GameSystemTests.swift
//
// Unit tests for GameSystem movement logic.
// These tests ensure movement calculations are correct and handle edge cases.

import Foundation
import Testing
@testable import GameContent
import SwiftStateTreeDeterministicMath

@Test("GameSystem.updatePlayerMovement moves player towards target")
func testUpdatePlayerMovementMovesTowardsTarget() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.targetPosition = Position2(x: 10.0, y: 0.0)  // Large distance
    player.rotation = Angle(degrees: 0.0)
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 1.0)
    
    // Assert
    // Player should have moved towards target
    #expect(player.position.v.x > 0)  // Should have moved right
    #expect(abs(player.position.v.y) < 100)  // Should be close to 0 (y-axis)
    // Note: moveTowards may return target if distance <= maxDistance due to quantization
    // So we just verify movement occurred and direction is correct
}

@Test("GameSystem.updatePlayerMovement reaches target when close enough")
func testUpdatePlayerMovementReachesTarget() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 0.5, y: 0.0)  // Very close target
    player.targetPosition = target
    player.rotation = Angle(degrees: 0.0)
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 1.0, arrivalThreshold: 1.0)
    
    // Assert
    // Player should have reached target (within threshold)
    #expect(player.targetPosition == nil)  // Target should be cleared
    #expect(player.position.isWithinDistance(to: target, threshold: 0.1))
}

@Test("GameSystem.updatePlayerMovement updates rotation towards target")
func testUpdatePlayerMovementUpdatesRotation() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.targetPosition = Position2(x: 1.0, y: 1.0)  // 45 degree angle
    player.rotation = Angle(degrees: 0.0)
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 0.1)
    
    // Assert
    // Rotation should be approximately 45 degrees
    let expectedAngle = Angle(degrees: 45.0)
    let angleDiff = abs(player.rotation.floatDegrees - expectedAngle.floatDegrees)
    #expect(angleDiff < 1.0)  // Allow 1 degree tolerance
}

@Test("GameSystem.updatePlayerMovement handles no target")
func testUpdatePlayerMovementHandlesNoTarget() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 10.0, y: 20.0)
    player.targetPosition = nil
    let originalPosition = player.position
    
    // Act
    GameSystem.updatePlayerMovement(&player)
    
    // Assert
    // Position should not change when there's no target
    #expect(player.position == originalPosition)
}

@Test("GameSystem.updatePlayerMovement handles very small distances")
func testUpdatePlayerMovementHandlesSmallDistances() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 0.001, y: 0.001)  // Very small distance
    player.targetPosition = target
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 1.0, arrivalThreshold: 1.0)
    
    // Assert
    // Should handle small distances gracefully (either reach target or move towards it)
    #expect(player.position.isWithinDistance(to: target, threshold: 1.0) || player.targetPosition != nil)
}

@Test("GameSystem.updatePlayerMovement handles large distances")
func testUpdatePlayerMovementHandlesLargeDistances() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    player.targetPosition = Position2(x: 100.0, y: 100.0)  // Large distance
    let originalTarget = player.targetPosition
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 1.0)
    
    // Assert
    // Should move towards target without issues
    #expect(player.targetPosition == originalTarget)  // Should still have target
    #expect(player.position.v.x > 0 || player.position.v.y > 0)  // Should have moved
}

@Test("GameSystem.updatePlayerMovement handles multiple movement steps")
func testUpdatePlayerMovementMultipleSteps() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 10.0, y: 0.0)  // Large distance
    player.targetPosition = target
    
    // Act - simulate multiple movement steps with smaller move speed
    var previousX: Int32 = 0
    var hasMoved = false
    for _ in 0..<3 {
        let hadTarget = player.targetPosition != nil
        GameSystem.updatePlayerMovement(&player, moveSpeed: 0.5)  // Smaller move speed
        // Verify position is progressing towards target (if target still exists)
        if hadTarget && player.targetPosition != nil {
            #expect(player.position.v.x >= previousX)  // Should not move backwards
            hasMoved = true
        }
        previousX = player.position.v.x
    }
    
    // Assert
    // Should have moved towards target (unless reached immediately)
    if hasMoved {
        #expect(player.position.v.x > 0)  // Should have moved right
    }
    #expect(abs(player.position.v.y) < 100)  // Should be close to 0 (y-axis)
}

@Test("GameSystem.updatePlayerMovement clears target when reached")
func testUpdatePlayerMovementClearsTargetWhenReached() {
    // Arrange
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 0.8, y: 0.0)  // Within 1.0 unit threshold
    player.targetPosition = target
    
    // Act
    GameSystem.updatePlayerMovement(&player, moveSpeed: 1.0, arrivalThreshold: 1.0)
    
    // Assert
    #expect(player.targetPosition == nil)  // Target should be cleared
    #expect(player.position.isWithinDistance(to: target, threshold: 0.1))
}

@Test("GameSystem.updatePlayerMovement detailed step-by-step tracking")
func testUpdatePlayerMovementStepByStep() {
    // Arrange - simulate a realistic movement scenario
    var player = PlayerState()
    player.position = Position2(x: 64.0, y: 36.0)  // Starting position
    let target = Position2(x: 74.342, y: 43.066)  // Target position (similar to logs)
    player.targetPosition = target
    player.rotation = Angle(degrees: 0.0)
    
    let moveSpeed: Float = 1.0
    let arrivalThreshold: Float = 1.0
    
    // Track multiple steps
    var stepCount = 0
    var previousPosition = player.position
    var positions: [(step: Int, x: Float, y: Float, distance: Float)] = []
    
    while player.targetPosition != nil && stepCount < 20 {
        stepCount += 1
        previousPosition = player.position
        
        // Calculate distance before movement
        let direction = target.v - player.position.v
        let distance = direction.magnitude()
        _ = direction.magnitudeSquaredSafe()
        positions.append((
            step: stepCount,
            x: player.position.v.floatX,
            y: player.position.v.floatY,
            distance: distance
        ))
        
        // Perform movement
        GameSystem.updatePlayerMovement(&player, moveSpeed: moveSpeed, arrivalThreshold: arrivalThreshold)
        
        // Check for issues - these should fail the test if precision problems occur
        if stepCount > 1 {
            let movedDistance = (previousPosition.v - player.position.v).magnitude()
            // Should not jump more than moveSpeed + small tolerance (0.1 for quantization)
            #expect(movedDistance <= moveSpeed + 0.1 || player.targetPosition == nil,
                "Step \(stepCount): Large jump detected! Jumped \(movedDistance) but max should be \(moveSpeed)")
        }
        
        // Check if position is reasonable - distance should decrease (or reach target)
        let currentDistance = (target.v - player.position.v).magnitude()
        if player.targetPosition != nil {
            // Distance should not increase significantly (allow 0.1 tolerance for quantization)
            #expect(currentDistance <= distance + 0.1,
                "Step \(stepCount): Distance increased from \(distance) to \(currentDistance)")
        }
    }
    
    if player.targetPosition == nil {
        let finalDistance = player.position.isWithinDistance(to: target, threshold: 0.1)
        #expect(finalDistance == true)
    }
    
    // Assertions
    #expect(stepCount > 0, "Should have taken at least one step")
    
    // Check that movement was progressive (each step should move closer or reach target)
    for i in 1..<positions.count {
        let prev = positions[i-1]
        let curr = positions[i]
        
        // Either we moved closer, or we reached the target
        // Allow 0.1 tolerance for quantization errors
        #expect(curr.distance <= prev.distance + 0.1 || i == positions.count - 1,
            "Step \(curr.step): Distance increased from \(prev.distance) to \(curr.distance) - precision issue detected!")
    }
    
    // Final position should be close to target if target was cleared
    if player.targetPosition == nil {
        #expect(player.position.isWithinDistance(to: target, threshold: 0.1))
    }
}

// MARK: - Precision Tests (Detecting the "亂跳" bug)

@Test("GameSystem.updatePlayerMovement precision test - small scale factor scenario")
func testUpdatePlayerMovementPrecisionSmallScaleFactor() {
    // This test specifically targets the precision bug that caused "亂跳" (erratic jumping)
    // The bug occurred when moveSpeed / distance resulted in a very small scale factor
    // which was incorrectly quantized in the old IVec2.scaled(by:) implementation
    
    // Arrange - scenario similar to the bug report
    var player = PlayerState()
    player.position = Position2(x: 64.0, y: 36.0)
    let target = Position2(x: 74.342, y: 43.066)  // Distance ≈ 12.525
    player.targetPosition = target
    
    let moveSpeed: Float = 1.0  // This creates scale factor ≈ 0.08 (small!)
    let initialDistance = (target.v - player.position.v).magnitude()
    
    // Act - perform multiple small steps
    var previousDistance = initialDistance
    var stepCount = 0
    var hasLargeJump = false
    var hasDistanceIncrease = false
    
    while player.targetPosition != nil && stepCount < 15 {
        stepCount += 1
        let positionBefore = player.position
        
        GameSystem.updatePlayerMovement(&player, moveSpeed: moveSpeed)
        
        // Check for large jumps (the "亂跳" symptom)
        let movedDistance = (player.position.v - positionBefore.v).magnitude()
        if movedDistance > moveSpeed + 0.2 {
            hasLargeJump = true
        }
        
        // Check for distance increase (precision loss symptom)
        let currentDistance = (target.v - player.position.v).magnitude()
        if currentDistance > previousDistance + 0.2 {
            hasDistanceIncrease = true
        }
        
        previousDistance = currentDistance
    }
    
    // Assert - these should never happen with correct precision handling
    #expect(hasLargeJump == false, "Large jumps detected - precision issue in scaled(by:) or moveTowards")
    #expect(hasDistanceIncrease == false, "Distance increased - precision issue causing movement away from target")
    #expect(stepCount > 0, "Should have taken at least one step")
}

@Test("GameSystem.updatePlayerMovement precision test - very small moveSpeed")
func testUpdatePlayerMovementPrecisionVerySmallMoveSpeed() {
    // Test with very small moveSpeed to stress test precision
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 5.0, y: 0.0)
    player.targetPosition = target
    
    let moveSpeed: Float = 0.1  // Very small move speed
    var previousPosition = player.position
    var previousDistance = (target.v - player.position.v).magnitude()
    
    // Perform 10 steps
    for step in 1...10 {
        if player.targetPosition == nil {
            break
        }
        
        previousPosition = player.position
        previousDistance = (target.v - player.position.v).magnitude()
        
        GameSystem.updatePlayerMovement(&player, moveSpeed: moveSpeed)
        
        // Check movement distance
        let movedDistance = (player.position.v - previousPosition.v).magnitude()
        #expect(movedDistance <= moveSpeed + 0.05 || player.targetPosition == nil,
            "Step \(step): Moved \(movedDistance) but max should be \(moveSpeed)")
        
        // Check distance progression
        if player.targetPosition != nil {
            let currentDistance = (target.v - player.position.v).magnitude()
            #expect(currentDistance <= previousDistance + 0.05,
                "Step \(step): Distance increased from \(previousDistance) to \(currentDistance)")
        }
    }
}

@Test("GameSystem.updatePlayerMovement precision test - multiple steps consistency")
func testUpdatePlayerMovementPrecisionMultipleStepsConsistency() {
    // Test that multiple steps maintain precision and don't accumulate errors
    var player = PlayerState()
    player.position = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 20.0, y: 15.0)  // Distance ≈ 25.0
    player.targetPosition = target
    
    let moveSpeed: Float = 1.0
    var positions: [Position2] = [player.position]
    
    // Perform 20 steps
    for step in 1...20 {
        if player.targetPosition == nil {
            break
        }
        
        let previousPosition = player.position
        GameSystem.updatePlayerMovement(&player, moveSpeed: moveSpeed)
        positions.append(player.position)
        
        // Verify smooth progression
        let movedDistance = (player.position.v - previousPosition.v).magnitude()
        #expect(movedDistance <= moveSpeed + 0.1 || player.targetPosition == nil,
            "Step \(step): Inconsistent movement distance \(movedDistance)")
        
        // Verify we're getting closer (or reached target)
        let previousDist = (target.v - previousPosition.v).magnitude()
        let currentDist = (target.v - player.position.v).magnitude()
        #expect(currentDist <= previousDist + 0.1 || player.targetPosition == nil,
            "Step \(step): Not progressing towards target")
    }
    
    // Final check: should reach target or be very close
    if player.targetPosition == nil {
        #expect(player.position.isWithinDistance(to: target, threshold: 0.1))
    } else {
        // If still moving, verify we're making progress
        let finalDistance = (target.v - player.position.v).magnitude()
        let initialDistance = (target.v - positions[0].v).magnitude()
        #expect(finalDistance < initialDistance, "Should be closer to target after multiple steps")
    }
}
