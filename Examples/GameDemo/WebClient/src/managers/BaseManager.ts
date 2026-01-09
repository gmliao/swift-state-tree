import Phaser from 'phaser'
import { BaseSprite } from '../sprites/BaseSprite'
import type { BaseState } from '../generated/defs'

/**
 * Manages the base/fortress sprite and UI updates.
 * Handles creation, updates, and destruction of the base sprite.
 */
export class BaseManager {
  private readonly scene: Phaser.Scene
  private baseSprite: BaseSprite | null = null
  private baseHealthText: Phaser.GameObjects.Text | null = null

  constructor(scene: Phaser.Scene) {
    this.scene = scene
    this.createHealthText()
  }

  /**
   * Update base sprite and UI based on server state
   */
  update(baseState: BaseState | null | undefined): void {
    if (!baseState) {
      // Base doesn't exist, destroy sprite if it exists
      if (this.baseSprite) {
        this.baseSprite.destroy()
        this.baseSprite = null
      }
      if (this.baseHealthText) {
        this.baseHealthText.setText('Base Health: N/A')
      }
      return
    }

    // Create sprite if it doesn't exist
    if (!this.baseSprite) {
      this.baseSprite = new BaseSprite(this.scene)
      this.baseSprite.setInitialPosition(baseState)
    } else {
      this.baseSprite.update(baseState)
    }

    // Update health text
    this.updateHealthText(baseState.health, baseState.maxHealth)
  }

  /**
   * Get the base sprite (for external access)
   */
  getSprite(): BaseSprite | null {
    return this.baseSprite
  }

  /**
   * Destroy all base-related objects
   */
  destroy(): void {
    if (this.baseSprite) {
      this.baseSprite.destroy()
      this.baseSprite = null
    }
    if (this.baseHealthText) {
      this.baseHealthText.destroy()
      this.baseHealthText = null
    }
  }

  private createHealthText(): void {
    this.baseHealthText = this.scene.add.text(10, 70, 'Base Health: 100/100', {
      fontSize: '20px',
      color: '#000000',
      fontFamily: 'Arial'
    })
    this.baseHealthText.setScrollFactor(0)
  }

  private updateHealthText(health: number, maxHealth: number): void {
    if (this.baseHealthText) {
      this.baseHealthText.setText(`Base Health: ${health}/${maxHealth}`)
    }
  }
}
