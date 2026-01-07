/**
 * Unit tests for syncInto function
 * 
 * Tests that syncInto preserves class instances (Position2, IVec2, Angle)
 * and doesn't convert them to plain objects.
 */

import { describe, it, expect } from 'vitest'
import { IVec2, Position2, Angle } from './deterministic-math'

/**
 * Copy of syncInto function from generated code for testing
 */
function isPlainObject(value: any): value is Record<string, any> {
  if (!value || typeof value !== "object") {
    return false
  }
  const proto = Object.getPrototypeOf(value)
  return proto === Object.prototype || proto === null
}

function syncInto(target: any, source: any): void {
  if (source == null || typeof source !== "object") {
    return
  }

  for (const key of Object.keys(target)) {
    if (!(key in source)) {
      delete target[key]
    }
  }

  for (const [key, value] of Object.entries(source)) {
    const src: any = value
    const dst: any = target[key]

    if (Array.isArray(src)) {
      if (!Array.isArray(dst)) {
        target[key] = src.slice()
      } else {
        dst.length = 0
        for (const item of src) {
          dst.push(item)
        }
      }
      continue
    }

    if (src && typeof src === "object") {
      if (!isPlainObject(src)) {
        // Class instance - preserve it
        target[key] = src
        continue
      }
      if (!dst || typeof dst !== "object" || Array.isArray(dst) || !isPlainObject(dst)) {
        target[key] = {}
      }
      syncInto(target[key], src)
      continue
    }

    target[key] = src
  }
}

describe('syncInto - Class Instance Preservation', () => {
  describe('Position2 preservation', () => {
    it('preserves Position2 instance when syncing', () => {
      const target: any = {}
      const ivec2 = new IVec2(64000, 36000, true) // fixed-point
      const position = new Position2(ivec2)
      const source = { position }

      syncInto(target, source)

      expect(target.position).toBeInstanceOf(Position2)
      expect(target.position.v).toBeInstanceOf(IVec2)
      expect(target.position.v.x).toBe(64.0)
      expect(target.position.v.y).toBe(36.0)
    })

    it('preserves Position2 when target already has a plain object', () => {
      const target: any = {
        position: { v: { x: 0, y: 0 } } // plain object
      }
      const ivec2 = new IVec2(64000, 36000, true)
      const position = new Position2(ivec2)
      const source = { position }

      syncInto(target, source)

      expect(target.position).toBeInstanceOf(Position2)
      expect(target.position.v).toBeInstanceOf(IVec2)
      expect(target.position.v.x).toBe(64.0)
      expect(target.position.v.y).toBe(36.0)
    })

    it('preserves nested Position2 in PlayerState', () => {
      const target: any = {}
      const ivec2 = new IVec2(64000, 36000, true)
      const position = new Position2(ivec2)
      const rotation = new Angle(45000, true) // fixed-point
      const source = {
        player: {
          position,
          rotation
        }
      }

      syncInto(target, source)

      expect(target.player.position).toBeInstanceOf(Position2)
      expect(target.player.position.v).toBeInstanceOf(IVec2)
      expect(target.player.position.v.x).toBe(64.0)
      expect(target.player.rotation).toBeInstanceOf(Angle)
      expect(target.player.rotation.degrees).toBe(45.0)
    })
  })

  describe('IVec2 preservation', () => {
    it('preserves IVec2 instance when syncing', () => {
      const target: any = {}
      const ivec2 = new IVec2(64000, 36000, true)
      const source = { vec: ivec2 }

      syncInto(target, source)

      expect(target.vec).toBeInstanceOf(IVec2)
      expect(target.vec.x).toBe(64.0)
      expect(target.vec.y).toBe(36.0)
    })
  })

  describe('Angle preservation', () => {
    it('preserves Angle instance when syncing', () => {
      const target: any = {}
      const angle = new Angle(90000, true) // fixed-point
      const source = { rotation: angle }

      syncInto(target, source)

      expect(target.rotation).toBeInstanceOf(Angle)
      expect(target.rotation.degrees).toBe(90.0)
      expect(target.rotation.rawDegrees).toBe(90000)
    })
  })

  describe('Mixed class instances and plain objects', () => {
    it('preserves class instances while syncing plain objects', () => {
      const target: any = {
        name: 'old name',
        score: 0
      }
      const ivec2 = new IVec2(64000, 36000, true)
      const position = new Position2(ivec2)
      const source = {
        name: 'new name',
        score: 100,
        position
      }

      syncInto(target, source)

      expect(target.name).toBe('new name')
      expect(target.score).toBe(100)
      expect(target.position).toBeInstanceOf(Position2)
      expect(target.position.v).toBeInstanceOf(IVec2)
    })

    it('handles map of players with Position2', () => {
      const target: any = {}
      const player1Pos = new Position2(new IVec2(64000, 36000, true))
      const player2Pos = new Position2(new IVec2(100000, 50000, true))
      const source = {
        players: {
          'player-1': {
            position: player1Pos,
            score: 100
          },
          'player-2': {
            position: player2Pos,
            score: 200
          }
        }
      }

      syncInto(target, source)

      expect(target.players['player-1'].position).toBeInstanceOf(Position2)
      expect(target.players['player-1'].position.v.x).toBe(64.0)
      expect(target.players['player-2'].position).toBeInstanceOf(Position2)
      expect(target.players['player-2'].position.v.x).toBe(100.0)
      expect(target.players['player-1'].score).toBe(100)
      expect(target.players['player-2'].score).toBe(200)
    })
  })

  describe('Update existing state', () => {
    it('replaces plain object with class instance', () => {
      const target: any = {
        position: { v: { x: 0, y: 0 } } // old plain object
      }
      const newIvec2 = new IVec2(65000, 37000, true)
      const newPosition = new Position2(newIvec2)
      const source = { position: newPosition }

      syncInto(target, source)

      expect(target.position).toBeInstanceOf(Position2)
      expect(target.position.v).toBeInstanceOf(IVec2)
      expect(target.position.v.x).toBe(65.0)
      expect(target.position.v.y).toBe(37.0)
    })

    it('updates nested Position2 in existing player state', () => {
      const target: any = {
        player: {
          position: { v: { x: 0, y: 0 } }, // old plain object
          name: 'Player 1'
        }
      }
      const newIvec2 = new IVec2(65000, 37000, true)
      const newPosition = new Position2(newIvec2)
      const source = {
        player: {
          position: newPosition,
          name: 'Player 1' // Include all fields in source (realistic scenario)
        }
      }

      syncInto(target, source)

      expect(target.player.position).toBeInstanceOf(Position2)
      expect(target.player.position.v.x).toBe(65.0)
      expect(target.player.position.v.y).toBe(37.0)
      expect(target.player.name).toBe('Player 1') // preserved
    })
  })
})
