import Phaser from 'phaser'
import type { MonsterState } from '../generated/defs'

/**
 * Encapsulates a monster's sprite and update logic
 */
export class MonsterSprite {
  public readonly container: Phaser.GameObjects.Container
  public readonly monsterID: number
  
  private readonly scene: Phaser.Scene
  private readonly lerpFactor: number = 0.1
  
  constructor(scene: Phaser.Scene, monsterID: number) {
    this.scene = scene
    this.monsterID = monsterID
    this.container = this.createSprite()
  }
  
  /**
   * Update monster position and rotation based on server state
   */
  update(monsterState: MonsterState): void {
    const serverPos = this.readServerPosition(monsterState, 'update')
    if (!serverPos) return
    
    // Extract rotation in radians
    const serverRotation = this.extractRotation(monsterState.rotation)
    
    // Get current visual position (lerped)
    const currentX = this.container.x
    const currentY = this.container.y
    const targetX = serverPos.x
    const targetY = serverPos.y
    
    // Smooth position interpolation (lerp)
    this.container.x = currentX + (targetX - currentX) * this.lerpFactor
    this.container.y = currentY + (targetY - currentY) * this.lerpFactor
    
    // Smooth rotation interpolation
    const currentRotation = this.container.rotation
    let targetRotation = Phaser.Math.Angle.Wrap(serverRotation)
    
    // Normalize rotation difference
    let rotationDiff = targetRotation - currentRotation
    if (rotationDiff > Math.PI) rotationDiff -= 2 * Math.PI
    if (rotationDiff < -Math.PI) rotationDiff += 2 * Math.PI
    
    this.container.rotation = currentRotation + rotationDiff * this.lerpFactor
    
    // Update health bar
    this.updateHealthBar(monsterState.health, monsterState.maxHealth)
  }
  
  /**
   * Set initial position immediately (no lerp)
   */
  setInitialPosition(monsterState: MonsterState): void {
    const pos = this.readServerPosition(monsterState, 'setInitialPosition')
    if (!pos) return
    
    // Extract rotation in radians
    const rotation = this.extractRotation(monsterState.rotation)
    this.container.rotation = Phaser.Math.Angle.Wrap(rotation)
    
    this.container.x = pos.x
    this.container.y = pos.y
    
    this.updateHealthBar(monsterState.health, monsterState.maxHealth)
  }
  
  /**
   * Destroy the sprite
   */
  destroy(): void {
    this.container.destroy()
  }
  
  private createSprite(): Phaser.GameObjects.Container {
    const container = this.scene.add.container(0, 0)
    
    // Monster body (red square)
    const bodySize = 1.5
    const bodyColor = 0xff0000  // Red
    const body = this.scene.add.rectangle(0, 0, bodySize, bodySize, bodyColor)
    body.setOrigin(0.5, 0.5)
    
    // Direction indicator (small triangle)
    const arrowSize = 0.8
    const arrow = this.scene.add.triangle(
      0, 0,
      arrowSize, 0,  // Tip
      -arrowSize * 0.5, -arrowSize * 0.3,
      -arrowSize * 0.5, arrowSize * 0.3,
      0xcc0000, 1
    )
    arrow.setOrigin(0, 0)
    
    // Health bar background
    const healthBarBg = this.scene.add.rectangle(0, -bodySize - 0.5, bodySize * 1.2, 0.2, 0x000000, 0.5)
    healthBarBg.setOrigin(0.5, 0.5)
    
    // Health bar foreground (will be updated)
    const healthBar = this.scene.add.rectangle(0, -bodySize - 0.5, bodySize * 1.2, 0.2, 0x00ff00, 1)
    healthBar.setOrigin(0.5, 0.5)
    healthBar.setData('healthBar', true)
    
    container.add([body, arrow, healthBarBg, healthBar])
    container.setData('monsterID', this.monsterID)
    
    return container
  }
  
  private updateHealthBar(currentHealth: number, maxHealth: number): void {
    const healthBar = this.container.list.find((child: any) => 
      child.getData && child.getData('healthBar')
    ) as Phaser.GameObjects.Rectangle | undefined
    
    if (healthBar && maxHealth > 0) {
      const healthRatio = currentHealth / maxHealth
      const barWidth = 1.8 * healthRatio  // bodySize * 1.2
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
    monsterState: MonsterState,
    context: string,
    logMissing: boolean = true
  ): { x: number; y: number } | null {
    const v = monsterState.position?.v
    if (!v) {
      if (logMissing) {
        console.warn(`⚠️ MonsterSprite.${context}: position.v is undefined for monster ${this.monsterID}`)
      }
      return null
    }
    return { x: v.x, y: v.y }
  }
  
  /**
   * Extract rotation value in radians from various formats
   * Handles: Angle objects, plain {degrees} objects, and raw numbers
   */
  private extractRotation(rotation: any): number {
    if (!rotation) return 0
    
    // Angle object with toRadians method
    if (typeof rotation.toRadians === 'function') {
      return rotation.toRadians()
    }
    
    // Plain object with degrees field (from PathHash nested updates)
    if (typeof rotation.degrees === 'number') {
      return rotation.degrees * (Math.PI / 180)
    }
    
    // Direct number (radians)
    if (typeof rotation === 'number') {
      return rotation
    }
    
    return 0
  }
}
