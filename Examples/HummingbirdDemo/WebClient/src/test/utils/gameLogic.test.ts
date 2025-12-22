/**
 * Unit Tests for Game Logic
 * 
 * These tests demonstrate:
 * 1. How to test business logic independently from components
 * 2. How to use codegen-generated test helpers (createMockState) for logic testing
 * 3. The value of extracting logic from components for testability
 */

import { describe, it, expect } from 'vitest'
import {
  calculateUpgradeCost,
  filterOtherPlayers,
  getUpgradeLevel,
  calculateTotalRoomCookies,
  getCurrentPlayer,
  getCurrentPlayerPrivateState
} from '../../utils/gameLogic'
import { createMockState } from '../../generated/demo-game/testHelpers'
import type { CookieGameState } from '../../generated/defs'

describe('gameLogic', () => {
  describe('calculateUpgradeCost', () => {
    it('calculates cost for level 0 correctly', () => {
      expect(calculateUpgradeCost(0, 10)).toBe(10) // 10 * (0 + 1)
      expect(calculateUpgradeCost(0, 50)).toBe(50) // 50 * (0 + 1)
    })

    it('calculates cost for higher levels correctly', () => {
      expect(calculateUpgradeCost(1, 10)).toBe(20) // 10 * (1 + 1)
      expect(calculateUpgradeCost(2, 10)).toBe(30) // 10 * (2 + 1)
      expect(calculateUpgradeCost(5, 50)).toBe(300) // 50 * (5 + 1)
    })

    it('handles zero base cost', () => {
      expect(calculateUpgradeCost(0, 0)).toBe(0)
      expect(calculateUpgradeCost(5, 0)).toBe(0)
    })
  })

  describe('filterOtherPlayers', () => {
    it('filters out current player correctly', () => {
      // Arrange: Use codegen-generated helper to create test state
      const state = createMockState({
        players: {
          'player-1': {
            name: 'Player 1',
            cookies: 100,
            cookiesPerSecond: 5
          },
          'player-2': {
            name: 'Player 2',
            cookies: 200,
            cookiesPerSecond: 10
          },
          'player-3': {
            name: 'Player 3',
            cookies: 300,
            cookiesPerSecond: 15
          }
        }
      })

      // Act
      const others = filterOtherPlayers(state.players, 'player-1')

      // Assert
      expect(others).toHaveLength(2)
      expect(others.find(p => p.id === 'player-1')).toBeUndefined()
      expect(others.find(p => p.id === 'player-2')).toBeDefined()
      expect(others.find(p => p.id === 'player-3')).toBeDefined()
      expect(others[0]?.name).toBe('Player 2')
    })

    it('returns empty array when currentPlayerID is null', () => {
      const state = createMockState({
        players: {
          'player-1': { name: 'Player 1', cookies: 100, cookiesPerSecond: 0 }
        }
      })

      const others = filterOtherPlayers(state.players, null)
      expect(others).toEqual([])
    })

    it('returns empty array when no other players exist', () => {
      const state = createMockState({
        players: {
          'player-1': { name: 'Player 1', cookies: 100, cookiesPerSecond: 0 }
        }
      })

      const others = filterOtherPlayers(state.players, 'player-1')
      expect(others).toEqual([])
    })
  })

  describe('getUpgradeLevel', () => {
    it('returns upgrade level when upgrade exists', () => {
      const privateState: CookieGameState['privateStates'][string] = {
        totalClicks: 50,
        upgrades: {
          cursor: 3,
          grandma: 2
        }
      }

      expect(getUpgradeLevel(privateState, 'cursor')).toBe(3)
      expect(getUpgradeLevel(privateState, 'grandma')).toBe(2)
    })

    it('returns 0 when upgrade does not exist', () => {
      const privateState: CookieGameState['privateStates'][string] = {
        totalClicks: 50,
        upgrades: {
          cursor: 3
        }
      }

      expect(getUpgradeLevel(privateState, 'grandma')).toBe(0)
      expect(getUpgradeLevel(privateState, 'nonexistent')).toBe(0)
    })

    it('returns 0 when privateState is null or undefined', () => {
      expect(getUpgradeLevel(null, 'cursor')).toBe(0)
      expect(getUpgradeLevel(undefined, 'cursor')).toBe(0)
    })

    it('returns 0 when upgrades object is empty', () => {
      const privateState: CookieGameState['privateStates'][string] = {
        totalClicks: 50,
        upgrades: {}
      }

      expect(getUpgradeLevel(privateState, 'cursor')).toBe(0)
    })
  })

  describe('calculateTotalRoomCookies', () => {
    it('calculates total cookies from all players', () => {
      // Arrange: Use codegen-generated helper
      const state = createMockState({
        players: {
          'player-1': { name: 'P1', cookies: 100, cookiesPerSecond: 5 },
          'player-2': { name: 'P2', cookies: 200, cookiesPerSecond: 10 },
          'player-3': { name: 'P3', cookies: 50, cookiesPerSecond: 2 }
        }
      })

      // Act
      const total = calculateTotalRoomCookies(state)

      // Assert
      expect(total).toBe(350) // 100 + 200 + 50
    })

    it('returns 0 when no players exist', () => {
      const state = createMockState({
        players: {}
      })

      expect(calculateTotalRoomCookies(state)).toBe(0)
    })

    it('handles players with zero cookies', () => {
      const state = createMockState({
        players: {
          'player-1': { name: 'P1', cookies: 0, cookiesPerSecond: 0 },
          'player-2': { name: 'P2', cookies: 100, cookiesPerSecond: 5 }
        }
      })

      expect(calculateTotalRoomCookies(state)).toBe(100)
    })
  })

  describe('getCurrentPlayer', () => {
    it('returns player data when player exists', () => {
      // Arrange: Use codegen-generated helper
      const state = createMockState({
        players: {
          'player-1': {
            name: 'Test Player',
            cookies: 100,
            cookiesPerSecond: 5
          }
        }
      })

      // Act
      const player = getCurrentPlayer(state, 'player-1')

      // Assert
      expect(player).not.toBeNull()
      expect(player?.name).toBe('Test Player')
      expect(player?.cookies).toBe(100)
    })

    it('returns null when player does not exist', () => {
      const state = createMockState({
        players: {
          'player-1': { name: 'P1', cookies: 100, cookiesPerSecond: 0 }
        }
      })

      expect(getCurrentPlayer(state, 'player-2')).toBeNull()
    })

    it('returns null when state is null', () => {
      expect(getCurrentPlayer(null, 'player-1')).toBeNull()
    })

    it('returns null when currentPlayerID is null', () => {
      const state = createMockState({
        players: {
          'player-1': { name: 'P1', cookies: 100, cookiesPerSecond: 0 }
        }
      })

      expect(getCurrentPlayer(state, null)).toBeNull()
    })
  })

  describe('getCurrentPlayerPrivateState', () => {
    it('returns private state when it exists', () => {
      // Arrange: Use codegen-generated helper
      const state = createMockState({
        privateStates: {
          'player-1': {
            totalClicks: 50,
            upgrades: { cursor: 2, grandma: 1 }
          }
        }
      })

      // Act
      const privateState = getCurrentPlayerPrivateState(state, 'player-1')

      // Assert
      expect(privateState).not.toBeNull()
      expect(privateState?.totalClicks).toBe(50)
      expect(privateState?.upgrades.cursor).toBe(2)
    })

    it('returns null when private state does not exist', () => {
      const state = createMockState({
        privateStates: {
          'player-1': { totalClicks: 0, upgrades: {} }
        }
      })

      expect(getCurrentPlayerPrivateState(state, 'player-2')).toBeNull()
    })

    it('returns null when state is null', () => {
      expect(getCurrentPlayerPrivateState(null, 'player-1')).toBeNull()
    })

    it('returns null when currentPlayerID is null', () => {
      const state = createMockState({
        privateStates: {
          'player-1': { totalClicks: 0, upgrades: {} }
        }
      })

      expect(getCurrentPlayerPrivateState(state, null)).toBeNull()
    })
  })
})
