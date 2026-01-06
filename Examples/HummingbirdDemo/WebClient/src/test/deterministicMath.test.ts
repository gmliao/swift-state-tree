// Examples/HummingbirdDemo/WebClient/src/test/deterministicMath.test.ts
//
// Tests for DeterministicMath types in TypeScript client.

import { describe, it, expect } from 'vitest'
import type { IVec2, Position2, Velocity2, Acceleration2, DeterministicMathDemoState } from '../generated/defs'
import {
  FIXED_POINT_SCALE,
  IVec2ToFloat,
  FloatToIVec2,
  Position2ToFloat,
  FloatToPosition2,
  Velocity2ToFloat,
  FloatToVelocity2,
  Acceleration2ToFloat,
  FloatToAcceleration2
} from '../generated/defs'

describe('DeterministicMath Types', () => {
  it('IVec2 type is correctly generated', () => {
    const vec: IVec2 = { x: 1000, y: 2000 }
    expect(vec.x).toBe(1000)
    expect(vec.y).toBe(2000)
  })

  it('Position2 type is correctly generated', () => {
    const pos: Position2 = { v: { x: 1000, y: 2000 } }
    expect(pos.v.x).toBe(1000)
    expect(pos.v.y).toBe(2000)
  })

  it('Velocity2 type is correctly generated', () => {
    const vel: Velocity2 = { v: { x: 100, y: 50 } }
    expect(vel.v.x).toBe(100)
    expect(vel.v.y).toBe(50)
  })

  it('Acceleration2 type is correctly generated', () => {
    const accel: Acceleration2 = { v: { x: 10, y: 5 } }
    expect(accel.v.x).toBe(10)
    expect(accel.v.y).toBe(5)
  })

  it('DeterministicMathDemoState type is correctly generated', () => {
    const state: DeterministicMathDemoState = {
      directVector: { x: 0, y: 0 },
      playerPositions: {
        'player1': { v: { x: 1000, y: 2000 } }
      },
      playerVelocities: {
        'player1': { v: { x: 100, y: 50 } }
      },
      playerAccelerations: {
        'player1': { v: { x: 10, y: 5 } }
      }
    }
    
    expect(state.directVector.x).toBe(0)
    expect(state.directVector.y).toBe(0)
    expect(state.playerPositions['player1']?.v.x).toBe(1000)
    expect(state.playerPositions['player1']?.v.y).toBe(2000)
  })

  it('can convert IVec2 to Float using generated helper', () => {
    // Using auto-generated conversion helper
    const vec: IVec2 = { x: 1500, y: 2300 }
    const float = IVec2ToFloat(vec)
    
    expect(float.x).toBe(1.5)
    expect(float.y).toBe(2.3)
  })

  it('can convert Float to IVec2 using generated helper', () => {
    // Using auto-generated conversion helper
    const vec = FloatToIVec2(1.5, 2.3)
    
    expect(vec.x).toBe(1500)
    expect(vec.y).toBe(2300)
  })

  it('can convert Position2 to Float using generated helper', () => {
    const pos: Position2 = { v: { x: 1000, y: 2000 } }
    const float = Position2ToFloat(pos)
    
    expect(float.x).toBe(1.0)
    expect(float.y).toBe(2.0)
  })

  it('can convert Float to Position2 using generated helper', () => {
    const pos = FloatToPosition2(1.5, 2.3)
    
    expect(pos.v.x).toBe(1500)
    expect(pos.v.y).toBe(2300)
  })

  it('can convert Velocity2 to Float using generated helper', () => {
    const vel: Velocity2 = { v: { x: 100, y: 50 } }
    const float = Velocity2ToFloat(vel)
    
    expect(float.x).toBe(0.1)
    expect(float.y).toBe(0.05)
  })

  it('can convert Acceleration2 to Float using generated helper', () => {
    const accel: Acceleration2 = { v: { x: 10, y: 5 } }
    const float = Acceleration2ToFloat(accel)
    
    expect(float.x).toBe(0.01)
    expect(float.y).toBe(0.005)
  })

  it('can convert Float to Velocity2 using generated helper', () => {
    const vel = FloatToVelocity2(0.1, 0.05)
    
    expect(vel.v.x).toBe(100)
    expect(vel.v.y).toBe(50)
  })

  it('can convert Float to Acceleration2 using generated helper', () => {
    const accel = FloatToAcceleration2(0.01, 0.005)
    
    expect(accel.v.x).toBe(10)
    expect(accel.v.y).toBe(5)
  })

  it('FIXED_POINT_SCALE constant is available', () => {
    expect(FIXED_POINT_SCALE).toBe(1000)
  })
})
