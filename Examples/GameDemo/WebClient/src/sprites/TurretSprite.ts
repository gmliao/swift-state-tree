import Phaser from 'phaser'
import type { TurretState } from '../generated/defs'

/**
 * Encapsulates a turret's sprite and update logic
 */
export class TurretSprite {
  public readonly container: Phaser.GameObjects.Container
  public readonly turretID: number
  
  private readonly scene: Phaser.Scene
  
  constructor(scene: Phaser.Scene, turretID: number) {
    this.scene = scene
    this.turretID = turretID
    this.container = this.createSprite()
  }
  
  /**
   * Update turret position and rotation based on server state
   */
  update(turretState: TurretState): void {
    const serverPos = this.readServerPosition(turretState, 'update')
    if (!serverPos) return
    
    // Set position (turrets don't move, but update in case)
    this.container.x = serverPos.x
    this.container.y = serverPos.y
    
    // Update rotation
    if ((turretState.rotation as any)?.toRadians) {
      const rotation = (turretState.rotation as any).toRadians()
      this.container.rotation = Phaser.Math.Angle.Wrap(rotation)
    }
    
    // Update level indicator
    this.updateLevelIndicator(turretState.level)
  }
  
  /**
   * Set initial position immediately
   */
  setInitialPosition(turretState: TurretState): void {
    const pos = this.readServerPosition(turretState, 'setInitialPosition')
    if (!pos) return
    
    this.container.x = pos.x
    this.container.y = pos.y
    
    if ((turretState.rotation as any)?.toRadians) {
      const rotation = (turretState.rotation as any).toRadians()
      this.container.rotation = Phaser.Math.Angle.Wrap(rotation)
    }
    
    this.updateLevelIndicator(turretState.level)
  }
  
  /**
   * Destroy the sprite
   */
  destroy(): void {
    this.container.destroy()
  }
  
  private createSprite(): Phaser.GameObjects.Container {
    const container = this.scene.add.container(0, 0)
    
    // Turret base (gray square)
    const baseSize = 2.0
    const baseColor = 0x666666  // Gray
    const base = this.scene.add.rectangle(0, 0, baseSize, baseSize, baseColor)
    base.setOrigin(0.5, 0.5)
    
    // Turret barrel (rectangle pointing forward)
    const barrelLength = 1.5
    const barrelWidth = 0.4
    const barrelColor = 0x333333  // Dark gray
    const barrel = this.scene.add.rectangle(barrelLength / 2, 0, barrelLength, barrelWidth, barrelColor)
    barrel.setOrigin(0, 0.5)
    
    // Level indicator (small circle)
    const levelIndicator = this.scene.add.circle(baseSize / 2, -baseSize / 2, 0.3, 0xffff00, 1)
    levelIndicator.setOrigin(0.5, 0.5)
    levelIndicator.setData('levelIndicator', true)
    
    container.add([base, barrel, levelIndicator])
    container.setData('turretID', this.turretID)
    
    return container
  }
  
  private updateLevelIndicator(level: number): void {
    const levelIndicator = this.container.list.find((child: any) => 
      child.getData && child.getData('levelIndicator')
    ) as Phaser.GameObjects.Arc | undefined
    
    if (levelIndicator) {
      // Change color based on level
      if (level === 0) {
        levelIndicator.setFillStyle(0xffff00)  // Yellow (base)
      } else if (level === 1) {
        levelIndicator.setFillStyle(0x00ff00)  // Green (level 1)
      } else if (level === 2) {
        levelIndicator.setFillStyle(0x00ffff)  // Cyan (level 2)
      } else {
        levelIndicator.setFillStyle(0xff00ff)  // Magenta (level 3+)
      }
    }
  }
  
  private readServerPosition(
    turretState: TurretState,
    context: string,
    logMissing: boolean = true
  ): { x: number; y: number } | null {
    const v = turretState.position?.v
    if (!v) {
      if (logMissing) {
        console.warn(`⚠️ TurretSprite.${context}: position.v is undefined for turret ${this.turretID}`)
      }
      return null
    }
    return { x: v.x, y: v.y }
  }
}
