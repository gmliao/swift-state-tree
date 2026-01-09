import Phaser from 'phaser'
import type { MonsterState } from '../generated/defs'
import { MonsterSprite } from '../sprites/MonsterSprite'
import { ShootEffect } from '../effects/ShootEffect'

/**
 * Manages monster sprites, creating, updating, and removing them as needed
 */
export class MonsterManager {
  private readonly scene: Phaser.Scene
  private readonly monsters: Map<string, MonsterSprite> = new Map()
  private readonly previousMonsterPositions: Map<string, { x: number; y: number }> = new Map()
  
  constructor(scene: Phaser.Scene) {
    this.scene = scene
  }
  
  /**
   * Update monsters from server state
   */
  update(monsters: Record<string, MonsterState> | undefined): void {
    if (!monsters) {
      // Remove all monsters if state is undefined
      this.removeAll()
      return
    }
    
    const currentIDs = new Set(Object.keys(monsters))
    const spriteIDs = new Set(this.monsters.keys())
    
    // Remove monsters that no longer exist (show hit effect)
    for (const id of spriteIDs) {
      if (!currentIDs.has(id)) {
        // Show hit effect at last known position before removing
        const lastPos = this.previousMonsterPositions.get(id)
        if (lastPos) {
          ShootEffect.createHitEffect(this.scene, lastPos.x, lastPos.y, 0xff0000, 300)
        }
        this.remove(id)
      }
    }
    
    // Add or update existing monsters
    for (const [id, monsterState] of Object.entries(monsters)) {
      if (!this.monsters.has(id)) {
        this.add(id, monsterState)
      } else {
        this.updateMonster(id, monsterState)
      }
    }
  }
  
  /**
   * Add a new monster
   */
  private add(id: string, monsterState: MonsterState): void {
    const sprite = new MonsterSprite(this.scene, id)
    sprite.setInitialPosition(monsterState)
    this.monsters.set(id, sprite)
    
    // Store initial position
    if (monsterState.position?.v) {
      this.previousMonsterPositions.set(id, {
        x: monsterState.position.v.x,
        y: monsterState.position.v.y
      })
    }
  }
  
  /**
   * Update an existing monster
   */
  private updateMonster(id: string, monsterState: MonsterState): void {
    const sprite = this.monsters.get(id)
    if (sprite) {
      // Store position for hit effect
      if (monsterState.position?.v) {
        this.previousMonsterPositions.set(id, {
          x: monsterState.position.v.x,
          y: monsterState.position.v.y
        })
      }
      sprite.update(monsterState)
    }
  }
  
  /**
   * Remove a monster
   */
  private remove(id: string): void {
    const sprite = this.monsters.get(id)
    if (sprite) {
      sprite.destroy()
      this.monsters.delete(id)
      this.previousMonsterPositions.delete(id)
    }
  }
  
  /**
   * Remove all monsters
   */
  private removeAll(): void {
    for (const sprite of this.monsters.values()) {
      sprite.destroy()
    }
    this.monsters.clear()
  }
  
  /**
   * Get a monster sprite by ID
   */
  getMonster(id: string): MonsterSprite | undefined {
    return this.monsters.get(id)
  }
  
  /**
   * Get all monster sprites
   */
  getAllMonsters(): MonsterSprite[] {
    return Array.from(this.monsters.values())
  }
}
