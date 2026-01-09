import Phaser from 'phaser'
import type { BaseState } from '../generated/defs'

/**
 * Encapsulates the base/fortress sprite and update logic
 */
export class BaseSprite {
  public readonly container: Phaser.GameObjects.Container
  
  private readonly scene: Phaser.Scene
  
  constructor(scene: Phaser.Scene) {
    this.scene = scene
    this.container = this.createSprite()
  }
  
  /**
   * Update base position and health based on server state
   */
  update(baseState: BaseState): void {
    const serverPos = this.readServerPosition(baseState, 'update')
    if (!serverPos) return
    
    // Set position (base doesn't move, but update in case)
    this.container.x = serverPos.x
    this.container.y = serverPos.y
    
    // Update health bar
    this.updateHealthBar(baseState.health, baseState.maxHealth)
  }
  
  /**
   * Set initial position immediately
   */
  setInitialPosition(baseState: BaseState): void {
    const pos = this.readServerPosition(baseState, 'setInitialPosition')
    if (!pos) return
    
    this.container.x = pos.x
    this.container.y = pos.y
    
    this.updateHealthBar(baseState.health, baseState.maxHealth)
  }
  
  /**
   * Destroy the sprite
   */
  destroy(): void {
    this.container.destroy()
  }
  
  private createSprite(): Phaser.GameObjects.Container {
    const container = this.scene.add.container(0, 0)
    
    // Base outer circle (blue)
    const outerRadius = 3.0
    const outerColor = 0x0066ff  // Blue
    const outerCircle = this.scene.add.circle(0, 0, outerRadius, outerColor, 0.8)
    outerCircle.setOrigin(0.5, 0.5)
    
    // Base inner circle (darker blue)
    const innerRadius = 2.0
    const innerColor = 0x0044cc  // Darker blue
    const innerCircle = this.scene.add.circle(0, 0, innerRadius, innerColor, 1.0)
    innerCircle.setOrigin(0.5, 0.5)
    
    // Health bar background
    const healthBarBg = this.scene.add.rectangle(0, -outerRadius - 1, outerRadius * 2, 0.3, 0x000000, 0.7)
    healthBarBg.setOrigin(0.5, 0.5)
    
    // Health bar foreground (will be updated)
    const healthBar = this.scene.add.rectangle(0, -outerRadius - 1, outerRadius * 2, 0.3, 0x00ff00, 1)
    healthBar.setOrigin(0.5, 0.5)
    healthBar.setData('healthBar', true)
    
    container.add([outerCircle, innerCircle, healthBarBg, healthBar])
    container.setData('base', true)
    
    return container
  }
  
  private updateHealthBar(currentHealth: number, maxHealth: number): void {
    const healthBar = this.container.list.find((child: any) => 
      child.getData && child.getData('healthBar')
    ) as Phaser.GameObjects.Rectangle | undefined
    
    if (healthBar && maxHealth > 0) {
      const healthRatio = currentHealth / maxHealth
      const barWidth = 6.0 * healthRatio  // outerRadius * 2
      healthBar.width = barWidth
      
      // Change color based on health
      if (healthRatio > 0.6) {
        healthBar.setFillStyle(0x00ff00)  // Green
      } else if (healthRatio > 0.3) {
        healthBar.setFillStyle(0xffff00)  // Yellow
      } else {
        healthBar.setFillStyle(0xff0000)  // Red
      }
    }
  }
  
  private readServerPosition(
    baseState: BaseState,
    context: string,
    logMissing: boolean = true
  ): { x: number; y: number } | null {
    const v = baseState.position?.v
    if (!v) {
      if (logMissing) {
        console.warn(`⚠️ BaseSprite.${context}: position.v is undefined`)
      }
      return null
    }
    return { x: v.x, y: v.y }
  }
}
