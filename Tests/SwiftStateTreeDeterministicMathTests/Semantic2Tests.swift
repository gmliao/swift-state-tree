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
