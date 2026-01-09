import Phaser from 'phaser'
import { GameCamera } from '../camera/GameCamera'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { HeroDefenseState } from '../generated/defs'
import type { PlayerManager } from './PlayerManager'

/**
 * Manages camera behavior, including following the current player
 */
export class CameraManager {
  private readonly gameCamera: GameCamera
  private tree: HeroDefenseStateTree | null = null
  private playerManager: PlayerManager | null = null

  constructor(scene: Phaser.Scene) {
    this.gameCamera = new GameCamera(scene).init()
  }

  /**
   * Set the state tree and player manager for camera following logic
   */
  setDependencies(tree: HeroDefenseStateTree, playerManager: PlayerManager): void {
    this.tree = tree
    this.playerManager = playerManager
  }

  /**
   * Setup camera to follow current player
   * Tries to follow player sprite if available, otherwise centers on initial position
   */
  setupFollow(): void {
    if (!this.tree || !this.tree.currentPlayerID) return
    
    // Try to use player sprite if available
    if (this.playerManager) {
      const currentPlayer = this.playerManager.getCurrentPlayer()
      if (currentPlayer) {
        this.gameCamera.startFollow(currentPlayer.container)
        return
      }
    }
    
    // If sprite doesn't exist yet, center on initial position
    const state = this.tree.state as HeroDefenseState
    const playerState = state.players?.[this.tree.currentPlayerID]
    
    if (playerState && playerState.position && playerState.position.v) {
      this.gameCamera.centerOn(playerState.position.v.x, playerState.position.v.y)
    }
  }

  /**
   * Start following a game object
   */
  startFollow(target: Phaser.GameObjects.GameObject): void {
    this.gameCamera.startFollow(target)
  }

  /**
   * Convert screen coordinates to world coordinates
   */
  screenToWorld(screenX: number, screenY: number): { x: number; y: number } {
    return this.gameCamera.screenToWorld(screenX, screenY)
  }

  /**
   * Get the underlying GameCamera instance
   */
  getCamera(): GameCamera {
    return this.gameCamera
  }
}
