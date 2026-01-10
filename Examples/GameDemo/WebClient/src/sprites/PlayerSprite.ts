import Phaser from 'phaser'
import type { PlayerState } from '../generated/defs'
import { Angle } from '../generated/defs'

/**
 * Encapsulates a player's sprite and update logic
 */
export class PlayerSprite {
  public readonly container: Phaser.GameObjects.Container
  public readonly playerID: string
  public readonly isCurrentPlayer: boolean
  
  private readonly scene: Phaser.Scene
  private readonly lerpFactor: number = 0.1  // For position interpolation
  private readonly rotationLerpFactor: number = 0.4  // Higher value = faster rotation (for shooting responsiveness)
  
  constructor(scene: Phaser.Scene, playerID: string, isCurrentPlayer: boolean) {
    this.scene = scene
    this.playerID = playerID
    this.isCurrentPlayer = isCurrentPlayer
    this.container = this.createSprite()
  }
  
  /**
   * Update player position and rotation based on server state
   * Note: SDK already converts Position2 and Angle from fixed-point to class instances,
   * so we can directly use playerState.position.v.x/y and playerState.rotation.toRadians()
   */
  update(playerState: PlayerState): void {
    // SDK already converted Position2.v from fixed-point to float via getter
    const serverPos = this.readServerPosition(playerState, 'update')
    if (!serverPos) return
    
    // SDK already converted Angle from fixed-point to Angle instance
    // Angle.toRadians() directly converts to radians
    if (!(playerState.rotation instanceof Angle)) {
      console.warn(`⚠️ PlayerSprite.update: rotation is not an Angle instance for player ${this.playerID}`)
      return
    }
    const serverRotation = playerState.rotation.toRadians()
    
    // Get current visual position (lerped)
    const currentX = this.container.x
    const currentY = this.container.y
    const targetX = serverPos.x
    const targetY = serverPos.y
    
    // Smooth position interpolation (lerp)
    this.container.x = currentX + (targetX - currentX) * this.lerpFactor
    this.container.y = currentY + (targetY - currentY) * this.lerpFactor
    
    // Smooth rotation interpolation (faster than position for shooting responsiveness)
    const currentRotation = this.container.rotation
    let targetRotation = Phaser.Math.Angle.Wrap(serverRotation)
    
    // Normalize rotation difference
    let rotationDiff = targetRotation - currentRotation
    if (rotationDiff > Math.PI) rotationDiff -= 2 * Math.PI
    if (rotationDiff < -Math.PI) rotationDiff += 2 * Math.PI
    
    // Use faster lerp factor for rotation to ensure player turns quickly when shooting
    this.container.rotation = currentRotation + rotationDiff * this.rotationLerpFactor
  }
  
  /**
   * Set initial position immediately (no lerp) to avoid jumping
   * Note: SDK already converts Position2 and Angle from fixed-point to class instances
   */
  setInitialPosition(playerState: PlayerState): void {
    // SDK already converted, use directly
    const pos = this.readServerPosition(playerState, 'setInitialPosition')
    if (!pos) return
    
    // SDK already converted Angle to Angle instance
    if (playerState.rotation instanceof Angle) {
      const rotation = playerState.rotation.toRadians()
      this.container.rotation = Phaser.Math.Angle.Wrap(rotation)
    } else {
      console.warn(`⚠️ PlayerSprite.setInitialPosition: rotation is not an Angle instance for player ${this.playerID}`)
    }
    
    this.container.x = pos.x
    this.container.y = pos.y
  }
  
  /**
   * Get server position (not lerped visual position)
   * Note: SDK already converts Position2 from fixed-point to float
   */
  getServerPosition(playerState: PlayerState): { x: number; y: number } {
    // SDK already converted, use directly
    const pos = this.readServerPosition(playerState, 'getServerPosition', false)
    if (!pos) {
      return { x: this.container.x, y: this.container.y }
    }
    return pos
  }
  
  /**
   * Destroy the sprite
   */
  destroy(): void {
    this.container.destroy()
  }
  
  private createSprite(): Phaser.GameObjects.Container {
    const container = this.scene.add.container(0, 0)
    
    // All players have the same size
    const bodyRadius = 2.0
    
    // Generate a unique color for each player based on their ID
    const bodyColor = this.generatePlayerColor(this.playerID)
    const body = this.scene.add.circle(0, 0, bodyRadius, bodyColor)
    body.setOrigin(0.5, 0.5)
    
    // Add border for current player to distinguish them
    if (this.isCurrentPlayer) {
      const border = this.scene.add.circle(0, 0, bodyRadius + 0.2, 0xffffff, 0.5)
      border.setOrigin(0.5, 0.5)
      container.add(border)
    }
    
    // Direction indicator: arrow pointing forward (same size for all players)
    const arrowLength = 3.0
    const arrowWidth = 0.8
    const arrowHeadSize = 1.0
    
    // Create arrow container to ensure line and triangle are aligned
    const arrowContainer = this.scene.add.container(0, 0)
    
    // Arrow body (line pointing forward) - black color
    // Pointing right initially (positive X), which matches toAngle() reference
    const arrowBody = this.scene.add.line(0, 0, 0, 0, arrowLength, 0, 0x000000, 1)
    arrowBody.setLineWidth(arrowWidth)
    arrowBody.setOrigin(0, 0) // Anchor at start point (circle center at 0, 0)
    
    // Arrow head (triangle) - black color, pointing right
    const arrowHead = this.scene.add.triangle(
      arrowLength, 0,  // Position at line end
      arrowHeadSize, 0,  // Tip point (right, relative to position)
      -arrowHeadSize * 0.3, -arrowWidth,  // Top base point (relative to position)
      -arrowHeadSize * 0.3, arrowWidth,   // Bottom base point (relative to position)
      0x000000, 1
    )
    arrowHead.setOrigin(0, 0) // Anchor at base center to align with line end
    
    // Add line and triangle to arrow container
    arrowContainer.add([arrowBody, arrowHead])
    
    // Add body and arrow container to main container
    container.add([body, arrowContainer])
    container.setData('playerID', this.playerID)
    
    return container
  }

  private readServerPosition(
    playerState: PlayerState,
    context: string,
    logMissing: boolean = true
  ): { x: number; y: number } | null {
    const v = playerState.position?.v
    if (!v) {
      if (logMissing) {
        console.warn(`⚠️ PlayerSprite.${context}: position.v is undefined for player ${this.playerID}`)
      }
      return null
    }
    return { x: v.x, y: v.y }
  }

  /**
   * Generate a unique color for each player based on their ID as seed
   * Uses playerID as seed for deterministic color generation
   */
  private generatePlayerColor(playerID: string): number {
    // Create a seeded random number generator from playerID
    const seed = this.stringToSeed(playerID)
    const rng = this.seededRandom(seed)
    
    // Generate hue (0-360), saturation (60-90%), lightness (50-70%)
    const hue = rng() * 360
    const saturation = 60 + rng() * 30
    const lightness = 50 + rng() * 20
    
    // Convert HSL to RGB
    const h = hue / 360
    const s = saturation / 100
    const l = lightness / 100
    
    const c = (1 - Math.abs(2 * l - 1)) * s
    const x = c * (1 - Math.abs((h * 6) % 2 - 1))
    const m = l - c / 2
    
    let r = 0, g = 0, b = 0
    if (h < 1/6) {
      r = c; g = x; b = 0
    } else if (h < 2/6) {
      r = x; g = c; b = 0
    } else if (h < 3/6) {
      r = 0; g = c; b = x
    } else if (h < 4/6) {
      r = 0; g = x; b = c
    } else if (h < 5/6) {
      r = x; g = 0; b = c
    } else {
      r = c; g = 0; b = x
    }
    
    const red = Math.round((r + m) * 255)
    const green = Math.round((g + m) * 255)
    const blue = Math.round((b + m) * 255)
    
    return (red << 16) | (green << 8) | blue
  }

  /**
   * Convert string to a numeric seed
   */
  private stringToSeed(str: string): number {
    let hash = 0
    for (let i = 0; i < str.length; i++) {
      const char = str.charCodeAt(i)
      hash = ((hash << 5) - hash) + char
      hash = hash & hash // Convert to 32-bit integer
    }
    return Math.abs(hash)
  }

  /**
   * Seeded random number generator (returns values between 0 and 1)
   * Uses Linear Congruential Generator (LCG) algorithm
   */
  private seededRandom(seed: number): () => number {
    let state = seed
    return () => {
      // LCG parameters (same as used in many programming languages)
      state = (state * 1664525 + 1013904223) % Math.pow(2, 32)
      return state / Math.pow(2, 32)
    }
  }
}
