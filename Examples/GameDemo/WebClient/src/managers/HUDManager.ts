import Phaser from 'phaser'
import type { HeroDefenseState } from '../generated/defs'

/**
 * Manages HUD (Heads-Up Display) UI elements.
 * Note: Score and resources are displayed in Vue UI overlay, not in Phaser scene.
 * This manager only handles position overlay text for debugging.
 */
export class HUDManager {
  private readonly scene: Phaser.Scene
  private positionOverlayText: Phaser.GameObjects.Text | null = null

  constructor(scene: Phaser.Scene) {
    this.scene = scene
    this.createHUD()
  }

  /**
   * Update HUD based on game state
   * Note: Score and resources are handled by Vue UI, so this method is kept for future use
   */
  update(_state: HeroDefenseState | null, _currentPlayerID: string | null | undefined): void {
    // Score and resources are displayed in Vue UI overlay, not here
    // This method is kept for potential future use
  }

  /**
   * Update position overlay text (for debugging/display)
   */
  updatePosition(x: number, y: number): void {
    if (this.positionOverlayText) {
      this.positionOverlayText.setText(`(${x.toFixed(1)}, ${y.toFixed(1)})`)
    }
  }

  /**
   * Destroy all HUD elements
   */
  destroy(): void {
    if (this.positionOverlayText) {
      this.positionOverlayText.destroy()
      this.positionOverlayText = null
    }
  }

  private createHUD(): void {
    // Note: Score and resources are displayed in Vue UI overlay, not in Phaser scene
    // Only create position overlay text for debugging
    
    // Create position overlay text at screen center
    const centerX = this.scene.scale.width / 2
    const centerY = this.scene.scale.height / 2
    this.positionOverlayText = this.scene.add.text(centerX, centerY, '(0.0, 0.0)', {
      fontSize: '12px',
      color: '#000000',
      align: 'center',
      strokeThickness: 0,
      fontFamily: 'Arial, sans-serif'
    })
    this.positionOverlayText.setOrigin(0.5, -2)
    this.positionOverlayText.setScrollFactor(0, 0)
    this.positionOverlayText.setDepth(1000)
    this.positionOverlayText.setScale(0.1)

    // Listen for resize events to reposition overlay
    this.scene.scale.on('resize', () => {
      if (this.positionOverlayText) {
        this.positionOverlayText.x = this.scene.scale.width / 2
        this.positionOverlayText.y = this.scene.scale.height / 2
      }
    })
  }

}
