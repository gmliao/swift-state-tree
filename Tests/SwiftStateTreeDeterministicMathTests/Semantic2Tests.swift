// Tests/SwiftStateTreeDeterministicMathTests/Semantic2Tests.swift
//
// Tests for semantic types (Position2, Velocity2, Acceleration2).

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("Position2 + Velocity2 produces Position2")
func testPositionPlusVelocity() {
    let pos = Position2(x: 1.0, y: 2.0)
    let vel = Velocity2(x: 0.1, y: 0.05)
    let newPos = pos + vel
    
    #expect(newPos.v.x == 1100)  // 1.0 + 0.1 = 1.1 -> 1100
    #expect(newPos.v.y == 2050)  // 2.0 + 0.05 = 2.05 -> 2050
}

@Test("Velocity2 + Acceleration2 produces Velocity2")
func testVelocityPlusAccel() {
    let vel = Velocity2(x: 1.0, y: 2.0)
    let accel = Acceleration2(x: 0.1, y: 0.05)
    let newVel = vel + accel
    
    #expect(newVel.v.x == 1100)  // 1.0 + 0.1 = 1.1 -> 1100
    #expect(newVel.v.y == 2050)  // 2.0 + 0.05 = 2.05 -> 2050
}

@Test("Semantic types are Codable")
func testSemanticTypesCodable() throws {
    let pos = Position2(x: 1.0, y: 2.0)
    let vel = Velocity2(x: 0.1, y: 0.05)
    let accel = Acceleration2(x: 0.01, y: 0.005)
    
    let encoder = JSONEncoder()
    let posData = try encoder.encode(pos)
    let velData = try encoder.encode(vel)
    let accelData = try encoder.encode(accel)
    
    let decoder = JSONDecoder()
    let decodedPos = try decoder.decode(Position2.self, from: posData)
    let decodedVel = try decoder.decode(Velocity2.self, from: velData)
    let decodedAccel = try decoder.decode(Acceleration2.self, from: accelData)
    
    #expect(decodedPos == pos)
    #expect(decodedVel == vel)
    #expect(decodedAccel == accel)
}

@Test("Position2 isWithinDistance works correctly")
func testPosition2IsWithinDistance() {
    let pos1 = Position2(x: 0.0, y: 0.0)
    let pos2 = Position2(x: 0.5, y: 0.5)
    
    // Should be within 1.0 unit
    #expect(pos1.isWithinDistance(to: pos2, threshold: 1.0) == true)
    
    // Should not be within 0.1 unit
    #expect(pos1.isWithinDistance(to: pos2, threshold: 0.1) == false)
}

@Test("Position2 distanceSquared works correctly")
func testPosition2DistanceSquared() {
    let pos1 = Position2(x: 0.0, y: 0.0)
    let pos2 = Position2(x: 3.0, y: 4.0)
    
    let distSq = pos1.distanceSquared(to: pos2)
    
    // Should be 3000^2 + 4000^2 = 25,000,000
    #expect(distSq == 25_000_000)
}

@Test("Position2 moveTowards moves towards target")
func testPosition2MoveTowards() {
    let start = Position2(x: 0.0, y: 0.0)
    let target = Position2(x: 5.0, y: 0.0)
    
    // Move 2.0 units towards target
    let moved = start.moveTowards(target: target, maxDistance: 2.0)
    
    // Verify it moved in the right direction (towards target)
    // Note: moveTowards now uses Int64 intermediate calculation for precision
    let movedDistance = start.distanceSquared(to: moved)
    let targetDistance = start.distanceSquared(to: target)
    
    // Moved position should be closer to start than target is
    #expect(movedDistance <= targetDistance)
    #expect(moved.v.x >= start.v.x)  // Moved right (towards target)
    #expect(abs(moved.v.y) < 1000)  // Should be close to 0 (y-axis), allow some tolerance
    
    // Verify moved distance is approximately 2.0 units
    let actualDistance = (moved.v - start.v).magnitude()
    #expect(abs(actualDistance - 2.0) < 0.1, "Should move approximately 2.0 units")
    
    // Move more than distance to target - should reach target
    let moved2 = start.moveTowards(target: target, maxDistance: 10.0)
    
    // Should be at target (5.0, 0.0) - within threshold
    #expect(moved2.isWithinDistance(to: target, threshold: 0.1))
}

@Test("Position2 moveTowards precision test with small scale factors")
func testPosition2MoveTowardsSmallScale() {
    // Test with realistic scenario: small movement towards distant target
    let start = Position2(x: 64.0, y: 36.0)
    let target = Position2(x: 74.342, y: 43.066)
    let maxDistance: Float = 1.0
    
    let moved = start.moveTowards(target: target, maxDistance: maxDistance)
    
    // Should move approximately maxDistance
    let movedDistance = (moved.v - start.v).magnitude()
    #expect(abs(movedDistance - maxDistance) < 0.1, "Should move approximately maxDistance")
    
    // Should be closer to target
    let distanceToTarget = (target.v - moved.v).magnitude()
    let initialDistance = (target.v - start.v).magnitude()
    #expect(distanceToTarget < initialDistance, "Should be closer to target")
}
