/**
 * Game Logic Utilities
 * 
 * These functions contain business logic that can be unit tested independently.
 * Extracting logic from components makes it easier to test and maintain.
 */

import type { CookieGameState } from '../generated/defs'

/**
 * Calculates the cost of an upgrade based on its current level.
 * 
 * @param level - Current upgrade level (0-based)
 * @param baseCost - Base cost for the upgrade
 * @returns The cost to purchase the next level
 * 
 * @example
 * calculateUpgradeCost(0, 10) // Returns 10 (10 * (0 + 1))
 * calculateUpgradeCost(2, 10) // Returns 30 (10 * (2 + 1))
 */
export function calculateUpgradeCost(level: number, baseCost: number): number {
  return baseCost * (level + 1)
}

/**
 * Filters out the current player from the players list.
 * 
 * @param players - Map of all players
 * @param currentPlayerID - ID of the current player to exclude
 * @returns Array of other players with their IDs
 * 
 * @example
 * filterOtherPlayers({ 'p1': {...}, 'p2': {...} }, 'p1')
 * // Returns [{ id: 'p2', ...player2Data }]
 */
export function filterOtherPlayers(
  players: CookieGameState['players'],
  currentPlayerID: string | null
): Array<{ id: string } & CookieGameState['players'][string]> {
  if (!currentPlayerID) return []
  
  return Object.entries(players)
    .filter(([id]) => id !== currentPlayerID)
    .map(([id, player]) => ({ id, ...player }))
}

/**
 * Gets the upgrade level for a specific upgrade type.
 * 
 * @param privateState - Player's private state
 * @param upgradeID - ID of the upgrade (e.g., 'cursor', 'grandma')
 * @returns The current level of the upgrade (0 if not found)
 */
export function getUpgradeLevel(
  privateState: CookieGameState['privateStates'][string] | null | undefined,
  upgradeID: string
): number {
  return privateState?.upgrades?.[upgradeID] ?? 0
}

/**
 * Calculates the total cookies across all players in the room.
 * 
 * @param state - Game state
 * @returns Total cookies from all players
 */
export function calculateTotalRoomCookies(state: CookieGameState): number {
  return Object.values(state.players).reduce(
    (total, player) => total + player.cookies,
    0
  )
}

/**
 * Gets the current player's data.
 * 
 * @param state - Game state
 * @param currentPlayerID - ID of the current player
 * @returns Player data or null if not found
 */
export function getCurrentPlayer(
  state: CookieGameState | null | undefined,
  currentPlayerID: string | null
): CookieGameState['players'][string] | null {
  if (!state || !currentPlayerID) return null
  return state.players?.[currentPlayerID] ?? null
}

/**
 * Gets the current player's private state.
 * 
 * @param state - Game state
 * @param currentPlayerID - ID of the current player
 * @returns Private state or null if not found
 */
export function getCurrentPlayerPrivateState(
  state: CookieGameState | null | undefined,
  currentPlayerID: string | null
): CookieGameState['privateStates'][string] | null {
  if (!state || !currentPlayerID) return null
  return state.privateStates?.[currentPlayerID] ?? null
}
