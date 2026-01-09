/**
 * Unit tests for deterministic-math.ts
 * 
 * Tests DeterministicMath classes:
 * - IVec2, IVec3, Angle, Position2, Velocity2, Acceleration2
 * - Automatic fixed-point to float conversion via getters
 * - Serialization (toJSON)
 */

import { describe, it, expect } from 'vitest'
import { IVec2, IVec3, Angle, Position2, Velocity2, Acceleration2, FIXED_POINT_SCALE } from './deterministic-math'

describe('IVec2', () => {
  it('creates from fixed-point integers', () => {
    const vec = new IVec2(64000, 36000, true)
    expect(vec.x).toBe(64.0)
    expect(vec.y).toBe(36.0)
    expect(vec.rawX).toBe(64000)
    expect(vec.rawY).toBe(36000)
  })

  it('creates from float values', () => {
    const vec = new IVec2(64.0, 36.0, false)
    expect(vec.x).toBeCloseTo(64.0, 1)
    expect(vec.y).toBeCloseTo(36.0, 1)
    expect(vec.rawX).toBe(64000)
    expect(vec.rawY).toBe(36000)
  })

  it('converts via getters', () => {
    const vec = new IVec2(1000, 2000, true)
    expect(vec.x).toBe(1.0)
    expect(vec.y).toBe(2.0)
  })

  it('converts via setters', () => {
    const vec = new IVec2(0, 0, true)
    vec.x = 5.5
    vec.y = 10.25
    expect(vec.x).toBeCloseTo(5.5, 1)
    expect(vec.y).toBeCloseTo(10.25, 1)
    expect(vec.rawX).toBe(5500)
    expect(vec.rawY).toBe(10250)
  })

  it('serializes to JSON with fixed-point integers', () => {
    const vec = new IVec2(64000, 36000, true)
    const json = vec.toJSON()
    expect(json).toEqual({ x: 64000, y: 36000 })
  })
})

describe('IVec3', () => {
  it('creates from fixed-point integers', () => {
    const vec = new IVec3(64000, 36000, 10000, true)
    expect(vec.x).toBe(64.0)
    expect(vec.y).toBe(36.0)
    expect(vec.z).toBe(10.0)
  })

  it('converts via getters and setters', () => {
    const vec = new IVec3(0, 0, 0, true)
    vec.x = 1.5
    vec.y = 2.5
    vec.z = 3.5
    expect(vec.x).toBeCloseTo(1.5, 1)
    expect(vec.y).toBeCloseTo(2.5, 1)
    expect(vec.z).toBeCloseTo(3.5, 1)
  })

  it('serializes to JSON', () => {
    const vec = new IVec3(1000, 2000, 3000, true)
    expect(vec.toJSON()).toEqual({ x: 1000, y: 2000, z: 3000 })
  })
})

describe('Angle', () => {
  it('creates from fixed-point integer degrees', () => {
    const angle = new Angle(45000, true) // 45 degrees
    expect(angle.degrees).toBe(45.0)
    expect(angle.rawDegrees).toBe(45000)
  })

  it('creates from float degrees', () => {
    const angle = new Angle(45.0, false)
    expect(angle.degrees).toBeCloseTo(45.0, 1)
    expect(angle.rawDegrees).toBe(45000)
  })

  it('converts to radians', () => {
    const angle = new Angle(90000, true) // 90 degrees
    expect(angle.toRadians()).toBeCloseTo(Math.PI / 2, 5)
  })

  it('converts via setter', () => {
    const angle = new Angle(0, true)
    angle.degrees = 180.0
    expect(angle.degrees).toBeCloseTo(180.0, 1)
    expect(angle.rawDegrees).toBe(180000)
  })

  it('serializes to JSON', () => {
    const angle = new Angle(45000, true)
    expect(angle.toJSON()).toEqual({ degrees: 45000 })
  })
})

describe('Position2', () => {
  it('creates from IVec2 instance', () => {
    const ivec2 = new IVec2(64000, 36000, true)
    const pos = new Position2(ivec2)
    expect(pos.v.x).toBe(64.0)
    expect(pos.v.y).toBe(36.0)
    expect(pos.v).toBeInstanceOf(IVec2)
  })

  it('creates from plain object with fixed-point integers', () => {
    const pos = new Position2({ x: 64000, y: 36000 }, true)
    expect(pos.v.x).toBe(64.0)
    expect(pos.v.y).toBe(36.0)
  })

  it('creates from plain object with float values', () => {
    const pos = new Position2({ x: 64.0, y: 36.0 }, false)
    expect(pos.v.x).toBeCloseTo(64.0, 1)
    expect(pos.v.y).toBeCloseTo(36.0, 1)
  })

  it('serializes to JSON', () => {
    const pos = new Position2({ x: 64000, y: 36000 }, true)
    expect(pos.toJSON()).toEqual({ v: { x: 64000, y: 36000 } })
  })
})

describe('Velocity2 and Acceleration2', () => {
  it('creates Velocity2 from IVec2', () => {
    const ivec2 = new IVec2(1000, 2000, true)
    const vel = new Velocity2(ivec2)
    expect(vel.v.x).toBe(1.0)
    expect(vel.v.y).toBe(2.0)
  })

  it('creates Velocity2 from plain object with float values', () => {
    const vel = new Velocity2({ x: 0.1, y: 0.05 }, false)
    expect(vel.v.x).toBeCloseTo(0.1, 2)
    expect(vel.v.y).toBeCloseTo(0.05, 2)
    expect(vel.v.rawX).toBe(100)
    expect(vel.v.rawY).toBe(50)
  })

  it('creates Acceleration2 from plain object', () => {
    const acc = new Acceleration2({ x: 500, y: 1000 }, true)
    expect(acc.v.x).toBe(0.5)
    expect(acc.v.y).toBe(1.0)
  })

  it('creates Acceleration2 from plain object with float values', () => {
    const acc = new Acceleration2({ x: 0.01, y: 0.005 }, false)
    expect(acc.v.x).toBeCloseTo(0.01, 3)
    expect(acc.v.y).toBeCloseTo(0.005, 3)
    expect(acc.v.rawX).toBe(10)
    expect(acc.v.rawY).toBe(5)
  })
})

describe('FIXED_POINT_SCALE', () => {
  it('has correct value', () => {
    expect(FIXED_POINT_SCALE).toBe(1000)
  })
})
