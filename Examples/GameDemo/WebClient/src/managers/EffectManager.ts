import Phaser from 'phaser'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { Unsubscribe } from '../generated/hero-defense/bindings'
import { ShootEffect } from '../effects/ShootEffect'

/**
 * Manages visual effects triggered by server events.
 * Handles subscriptions to server events and displays corresponding visual effects.
 */
export class EffectManager {
  private readonly scene: Phaser.Scene
  private unsubscribeEvents: Unsubscribe[] = []

  constructor(scene: Phaser.Scene) {
    this.scene = scene
  }

  /**
   * Subscribe to server events for visual effects
   */
  subscribeToTree(tree: HeroDefenseStateTree): void {
    // Unsubscribe from previous events if any
    this.unsubscribeEvents.forEach(unsubscribe => unsubscribe())
    this.unsubscribeEvents = []

    // Subscribe to player shoot events
    this.subscribeToPlayerShootEvents(tree)

    // Subscribe to turret fire events
    this.subscribeToTurretFireEvents(tree)
  }

  /**
   * Subscribe to player shoot events and display visual effects
   */
  private subscribeToPlayerShootEvents(tree: HeroDefenseStateTree): void {
    const unsubPlayerShoot = tree.playerShoot.subscribe((event) => {
      // Check if this is the current player's shot
      const currentPlayerID = tree.currentPlayerID
      const isCurrentPlayer =
        currentPlayerID !== undefined &&
        event.playerID.rawValue === currentPlayerID

      // Show shoot effect for all players (including current player)
      // Auto-shoot is server-side, so we show effects from server events
      // SDK now automatically converts event payloads (Position2, Angle, etc.) to instances
      if (event.from?.v && event.to?.v) {
        // event.from and event.to are now Position2 instances (auto-converted by SDK)
        // Position2.v.x and v.y getters automatically convert fixed-point to Float
        const fromX = event.from.v.x
        const fromY = event.from.v.y
        const toX = event.to.v.x
        const toY = event.to.v.y

        console.log('📢 Showing shoot effect', {
          playerID: event.playerID.rawValue,
          isCurrentPlayer,
          from: { x: fromX, y: fromY },
          to: { x: toX, y: toY }
        })
        ShootEffect.createBulletTrail(
          this.scene,
          fromX,
          fromY,
          toX,
          toY,
          0xffff00, // Yellow for player shots
          150
        )
      } else {
        console.warn('⚠️ PlayerShootEvent missing position data', event)
      }
    })
    this.unsubscribeEvents.push(unsubPlayerShoot)
  }

  /**
   * Subscribe to turret fire events and display visual effects
   */
  private subscribeToTurretFireEvents(tree: HeroDefenseStateTree): void {
    const unsubTurretFire = tree.turretFire.subscribe((event) => {
      // Show turret fire effect
      if (event.from?.v && event.to?.v) {
        ShootEffect.createTurretFire(
          this.scene,
          event.from.v.x,
          event.from.v.y,
          event.to.v.x,
          event.to.v.y,
          0x00ffff, // Cyan for turret shots
          200
        )
      }
    })
    this.unsubscribeEvents.push(unsubTurretFire)
  }

  /**
   * Destroy all subscriptions
   */
  destroy(): void {
    this.unsubscribeEvents.forEach(unsubscribe => unsubscribe())
    this.unsubscribeEvents = []
  }
}
