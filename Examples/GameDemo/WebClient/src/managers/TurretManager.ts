import Phaser from 'phaser'
import type { TurretState } from '../generated/defs'
import { TurretSprite } from '../sprites/TurretSprite'

/**
 * Manages turret sprites, creating, updating, and removing them as needed
 */
export class TurretManager {
  private readonly scene: Phaser.Scene
  private readonly turrets: Map<string, TurretSprite> = new Map()
  
  constructor(scene: Phaser.Scene) {
    this.scene = scene
  }
  
  /**
   * Update turrets from server state
   */
  update(turrets: Record<string, TurretState> | undefined): void {
    if (!turrets) {
      // Remove all turrets if state is undefined
      this.removeAll()
      return
    }
    
    const currentIDs = new Set(Object.keys(turrets))
    const spriteIDs = new Set(this.turrets.keys())
    
    // Remove turrets that no longer exist
    for (const id of spriteIDs) {
      if (!currentIDs.has(id)) {
        this.remove(id)
      }
    }
    
    // Add or update existing turrets
    for (const [id, turretState] of Object.entries(turrets)) {
      if (!this.turrets.has(id)) {
        this.add(id, turretState)
      } else {
        this.updateTurret(id, turretState)
      }
    }
  }
  
  /**
   * Add a new turret
   */
  private add(id: string, turretState: TurretState): void {
    const sprite = new TurretSprite(this.scene, id)
    sprite.setInitialPosition(turretState)
    this.turrets.set(id, sprite)
  }
  
  /**
   * Update an existing turret
   */
  private updateTurret(id: string, turretState: TurretState): void {
    const sprite = this.turrets.get(id)
    if (sprite) {
      sprite.update(turretState)
    }
  }
  
  /**
   * Remove a turret
   */
  private remove(id: string): void {
    const sprite = this.turrets.get(id)
    if (sprite) {
      sprite.destroy()
      this.turrets.delete(id)
    }
  }
  
  /**
   * Remove all turrets
   */
  private removeAll(): void {
    for (const sprite of this.turrets.values()) {
      sprite.destroy()
    }
    this.turrets.clear()
  }
  
  /**
   * Get a turret sprite by ID
   */
  getTurret(id: string): TurretSprite | undefined {
    return this.turrets.get(id)
  }
  
  /**
   * Get all turret sprites
   */
  getAllTurrets(): TurretSprite[] {
    return Array.from(this.turrets.values())
  }
}
