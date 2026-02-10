// Mock utilities for testing Vue components with StateTree
// This demonstrates how the architecture makes testing easy

import { ref, computed } from 'vue'
import { vi } from 'vitest'
import type { CookieGameState } from '../../generated/defs'

/**
 * Creates a mock state for testing.
 * This shows how easy it is to create test data with the generated types.
 */
export function createMockState(overrides?: Partial<CookieGameState>): CookieGameState {
  return {
    players: {},
    privateStates: {},
    totalCookies: 0,
    ticks: 0,
    ...overrides
  }
}

/**
 * Creates a mock player state.
 */
export function createMockPlayer(playerID: string, overrides?: Partial<CookieGameState['players'][string]>) {
  return {
    name: `Player ${playerID}`,
    cookies: 0,
    cookiesPerSecond: 0,
    ...overrides
  }
}

/**
 * Creates a mock private state.
 */
export function createMockPrivateState(overrides?: Partial<CookieGameState['privateStates'][string]>) {
  return {
    totalClicks: 0,
    upgrades: {},
    ...overrides
  }
}

/**
 * Mock implementation of useDemoGame for testing.
 * This demonstrates how the architecture allows easy mocking.
 */
export function createMockUseDemoGame(initialState?: CookieGameState) {
  const state = ref<CookieGameState | null>(initialState || createMockState())
  const currentPlayerID = ref<string | null>('test-player-1')
  const isConnecting = ref(false)
  const isConnected = ref(true)
  const isJoined = ref(true)
  const lastError = ref<string | null>(null)

  const clickCookie = vi.fn(async () => {
    // Simulate state update
    if (state.value && currentPlayerID.value) {
      const player = state.value.players[currentPlayerID.value]
      if (player) {
        player.cookies += 1
        const privateState = state.value.privateStates[currentPlayerID.value]
        if (privateState) {
          privateState.totalClicks += 1
        }
      }
    }
  })

  const buyUpgrade = vi.fn(async (payload: { upgradeID: string }) => {
    // Simulate state update
    if (state.value && currentPlayerID.value) {
      const player = state.value.players[currentPlayerID.value]
      const privateState = state.value.privateStates[currentPlayerID.value]
      if (player && privateState) {
        const level = privateState.upgrades[payload.upgradeID] || 0
        const cost = payload.upgradeID === 'cursor' ? 10 * (level + 1) : 50 * (level + 1)
        
        if (player.cookies >= cost) {
          player.cookies -= cost
          player.cookiesPerSecond += payload.upgradeID === 'cursor' ? 1 : 5
          privateState.upgrades[payload.upgradeID] = level + 1
          
          return {
            success: true,
            newCookies: player.cookies,
            newCookiesPerSecond: player.cookiesPerSecond,
            upgradeLevel: level + 1
          }
        }
      }
      
      // Return failure response
      const failPlayer = state.value.players[currentPlayerID.value]
      const failPrivateState = state.value.privateStates[currentPlayerID.value]
      return {
        success: false,
        newCookies: failPlayer?.cookies || 0,
        newCookiesPerSecond: failPlayer?.cookiesPerSecond || 0,
        upgradeLevel: failPrivateState?.upgrades[payload.upgradeID] || 0
      }
    }
    
    return {
      success: false,
      newCookies: 0,
      newCookiesPerSecond: 0,
      upgradeLevel: 0
    }
  })

  const disconnect = vi.fn(async () => {
    isConnected.value = false
    isJoined.value = false
    state.value = null
  })

  return {
    state,
    currentPlayerID,
    isConnecting,
    isConnected,
    isJoined,
    lastError,
    clickCookie,
    buyUpgrade,
    disconnect,
    connect: vi.fn(),
    tree: computed(() => null)
  }
}



