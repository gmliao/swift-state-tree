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
  private readonly lerpFactor: number = 0.1
  
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
    
    // Smooth rotation interpolation
    const currentRotation = this.container.rotation
    let targetRotation = Phaser.Math.Angle.Wrap(serverRotation)
    
    // Normalize rotation difference
    let rotationDiff = targetRotation - currentRotation
    if (rotationDiff > Math.PI) rotationDiff -= 2 * Math.PI
    if (rotationDiff < -Math.PI) rotationDiff += 2 * Math.PI
    
    this.container.rotation = currentRotation + rotationDiff * this.lerpFactor
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
    
    // Player body (circle) - size in world units
    // Current player: larger and brighter, other players: smaller and darker
    const bodyRadius = this.isCurrentPlayer ? 2 : 1.5
    const bodyColor = this.isCurrentPlayer ? 0x667eea : 0x9999cc
    const body = this.scene.add.circle(0, 0, bodyRadius, bodyColor)
    body.setOrigin(0.5, 0.5)
    
    // Add border for current player
    if (this.isCurrentPlayer) {
      const border = this.scene.add.circle(0, 0, bodyRadius + 0.2, 0xffffff, 0.3)
      border.setOrigin(0.5, 0.5)
      container.add(border)
    }
    
    // Direction indicator: arrow pointing forward
    const arrowLength = this.isCurrentPlayer ? 3 : 2.5
    const arrowWidth = this.isCurrentPlayer ? 0.8 : 0.6
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
}
