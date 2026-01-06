import Phaser from 'phaser'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { HeroDefenseState, MoveToEvent, PlayAction, PlayResponse } from '../generated/defs'
import { FloatToPosition2, Position2ToFloat, AngleToRadians } from '../generated/defs'

interface GameClient {
  tree: HeroDefenseStateTree | null
  play: (payload: PlayAction) => Promise<PlayResponse>
  events: {
    moveTo: (payload: MoveToEvent) => void
  }
  currentPlayerID: string | null
}

export class GameScene extends Phaser.Scene {
  private gameClient: GameClient | null = null
  private scoreText!: Phaser.GameObjects.Text
  private playerSprites: Map<string, Phaser.GameObjects.Container> = new Map()
  private currentPlayerSprite: Phaser.GameObjects.Container | null = null
  
  constructor() {
    super({ key: 'GameScene' })
  }
  
  setGameClient(client: GameClient) {
    this.gameClient = client
    
    // If scene is already created, update score immediately and setup camera follow
    if (this.scoreText) {
      this.updateFromState()
      // Setup camera follow on next frame to ensure sprites are created
      this.time.delayedCall(0, () => {
        this.setupCameraFollow()
      })
    }
  }
  
  private updateCameraZoom() {
    // Set camera view size to approximately 16 grid cells (8 * 16 = 128 units)
    // This shows a larger area (camera is further away)
    const gridSize = 8
    const cellsToShow = 16
    const viewSizeInUnits = gridSize * cellsToShow // 128 units
    
    // Calculate zoom to show approximately 16 cells in view
    const viewportWidth = this.scale.width
    const viewportHeight = this.scale.height
    // Zoom = viewport size / desired world units to show
    const zoomX = viewportWidth / viewSizeInUnits
    const zoomY = viewportHeight / viewSizeInUnits
    // Use the larger zoom to ensure we show at least 16 cells
    const zoom = Math.max(zoomX, zoomY)
    this.cameras.main.setZoom(zoom)
  }
  
  private setupCameraFollow() {
    if (!this.gameClient || !this.gameClient.tree || !this.gameClient.currentPlayerID) return
    
    // Try to use sprite if available
    if (this.currentPlayerSprite) {
      // Use startFollow for smooth camera following
      // Parameters: (target, roundPixels, lerpX, lerpY)
      // lerpX and lerpY control smoothness (0.1 = smooth, 1.0 = instant)
      this.cameras.main.startFollow(this.currentPlayerSprite, false, 0.1, 0.1)
      return
    }
    
    // If sprite doesn't exist yet, schedule retry
    const state = this.gameClient.tree.state as HeroDefenseState
    const currentPlayerID = this.gameClient.currentPlayerID
    const playerState = state.players?.[currentPlayerID]
    
    if (playerState) {
      // Set initial camera position, follow will be set up in update() when sprite is created
      const pos = Position2ToFloat(playerState.position)
      this.cameras.main.centerOn(pos.x, pos.y)
    }
  }
  
  create() {
    // No world bounds - allow infinite/unbounded world with negative coordinates
    // Set camera view size to approximately 8 grid cells (8 * 8 = 64 units)
    this.updateCameraZoom()
    
    // Listen for resize events to update camera zoom
    this.scale.on('resize', this.updateCameraZoom, this)
    
    // Center camera on origin (0, 0) initially
    // Players will spawn at their server-defined positions
    this.cameras.main.centerOn(0, 0)
    
    // Create white background covering a large area (can extend infinitely)
    // Use a large enough area to cover initial view
    const backgroundSize = 1000 // Large enough for initial view
    this.add.rectangle(0, 0, backgroundSize, backgroundSize, 0xffffff)
    
    // Create grid background (centered on origin, extending in all directions)
    this.createGrid()
    
    // Create score text with black color (in screen coordinates, fixed to camera)
    this.scoreText = this.add.text(10, 10, 'Score: 0', {
      fontSize: '24px',
      color: '#000000',
      fontFamily: 'Arial'
    })
    // Make score text fixed to camera (doesn't move with world)
    this.scoreText.setScrollFactor(0)
    
    // Mouse click handler to move player
    // Convert screen coordinates to world coordinates
    this.input.on('pointerdown', (pointer: Phaser.Input.Pointer) => {
      if (this.gameClient && this.gameClient.tree && this.gameClient.events) {
        // Get world coordinates from camera
        const worldX = this.cameras.main.getWorldPoint(pointer.x, pointer.y).x
        const worldY = this.cameras.main.getWorldPoint(pointer.x, pointer.y).y
        
        // No clamping - allow negative coordinates
        const target = FloatToPosition2(worldX, worldY)
        this.gameClient.events.moveTo({ target })
        
        // Visual feedback: draw a temporary marker at click position
        const marker = this.add.circle(worldX, worldY, 1, 0xff0000, 0.5)
        this.tweens.add({
          targets: marker,
          alpha: 0,
          scale: 2,
          duration: 500,
          onComplete: () => marker.destroy()
        })
      }
    })
    
    // Update from state if available
    if (this.gameClient) {
      this.updateFromState()
      // Setup camera follow if not already set up
      // Check if currentPlayerSprite exists to determine if we should set up follow
      if (this.gameClient.currentPlayerID && this.currentPlayerSprite) {
        this.setupCameraFollow()
      }
    }
  }
  
  private createGrid() {
    const gridSize = 8 // Grid cell size in world units
    const gridRange = 500 // Grid extends from -gridRange to +gridRange (allows negative coordinates)
    
    // Draw vertical lines (including negative x coordinates)
    for (let x = -gridRange; x <= gridRange; x += gridSize) {
      this.add.line(0, 0, x, -gridRange, x, gridRange, 0xe0e0e0, 0.3).setOrigin(0, 0)
    }
    
    // Draw horizontal lines (including negative y coordinates)
    for (let y = -gridRange; y <= gridRange; y += gridSize) {
      this.add.line(0, 0, -gridRange, y, gridRange, y, 0xe0e0e0, 0.3).setOrigin(0, 0)
    }
    
    // Draw thicker lines every 4 cells (32 units)
    const majorGridSize = gridSize * 4
    for (let x = -gridRange; x <= gridRange; x += majorGridSize) {
      this.add.line(0, 0, x, -gridRange, x, gridRange, 0xcccccc, 0.5).setOrigin(0, 0)
    }
    for (let y = -gridRange; y <= gridRange; y += majorGridSize) {
      this.add.line(0, 0, -gridRange, y, gridRange, y, 0xcccccc, 0.5).setOrigin(0, 0)
    }
    
    // Draw axes (x and y axes at 0, 0) for reference
    this.add.line(0, 0, 0, -gridRange, 0, gridRange, 0x999999, 0.7).setOrigin(0, 0) // Y axis
    this.add.line(0, 0, -gridRange, 0, gridRange, 0, 0x999999, 0.7).setOrigin(0, 0) // X axis
  }
  
  update() {
    if (!this.gameClient || !this.gameClient.tree) return
    
    const state = this.gameClient.tree.state as HeroDefenseState
    const currentPlayerID = this.gameClient.currentPlayerID
    
    // Reset current player sprite tracking at start of each frame
    this.currentPlayerSprite = null
    
    // Update all players
    for (const [playerID, playerState] of Object.entries(state.players || {})) {
      let sprite = this.playerSprites.get(playerID)
      
      // Convert fixed-point to float (world coordinates) - do this before creating sprite
      const pos = Position2ToFloat(playerState.position)
      // Convert Angle to radians
      const rotationRad = AngleToRadians(playerState.rotation)
      
      if (!sprite) {
        // Create new player sprite
        const isCurrentPlayer = currentPlayerID !== null && String(playerID) === String(currentPlayerID)
        sprite = this.createPlayerSprite(playerID, isCurrentPlayer)
        // IMPORTANT: Set sprite to correct position immediately to avoid jumping
        sprite.x = pos.x
        sprite.y = pos.y
        sprite.rotation = rotationRad
        this.playerSprites.set(playerID, sprite)
        
        // If this is the current player, set it immediately and setup camera follow
        if (isCurrentPlayer) {
          this.currentPlayerSprite = sprite
          // Use startFollow for smooth camera following
          // Parameters: (target, roundPixels, lerpX, lerpY)
          // lerpX and lerpY control smoothness (0.1 = smooth, 1.0 = instant)
          this.cameras.main.startFollow(sprite, false, 0.1, 0.1)
        }
      }
      
      // Track current player sprite (check both null and string comparison)
      // Use String() to ensure type-safe comparison
      if (currentPlayerID !== null && String(playerID) === String(currentPlayerID)) {
        this.currentPlayerSprite = sprite
        // Ensure camera is following this sprite
        // startFollow can be called multiple times safely
        this.cameras.main.startFollow(sprite, false, 0.1, 0.1)
      }
      
      // Smooth interpolation for position (in world coordinates)
      const currentX = sprite.x
      const currentY = sprite.y
      const targetX = pos.x
      const targetY = pos.y
      
      // Interpolate position (lerp factor: 0.1 for smooth movement)
      const lerpFactor = 0.1
      sprite.x = currentX + (targetX - currentX) * lerpFactor
      sprite.y = currentY + (targetY - currentY) * lerpFactor
      
      // No bounds clamping - allow negative coordinates
      
      // Smooth rotation interpolation
      const currentRotation = sprite.rotation
      let targetRotation = rotationRad
      
      // Normalize rotation difference
      let rotationDiff = targetRotation - currentRotation
      if (rotationDiff > Math.PI) rotationDiff -= 2 * Math.PI
      if (rotationDiff < -Math.PI) rotationDiff += 2 * Math.PI
      
      sprite.rotation = currentRotation + rotationDiff * lerpFactor
    }
    
    // Remove sprites for players that left
    for (const [playerID] of this.playerSprites) {
      if (!state.players[playerID]) {
        this.playerSprites.get(playerID)?.destroy()
        this.playerSprites.delete(playerID)
        if (playerID === currentPlayerID) {
          this.currentPlayerSprite = null
        }
      }
    }
    
    // Camera follow is handled by Phaser's startFollow() method
    // No manual camera positioning needed - Phaser handles it automatically
    // startFollow is set up when sprite is created, so no action needed here
    
    // Update score
    this.updateFromState()
  }
  
  private updateFromState() {
    if (!this.gameClient || !this.gameClient.tree) return
    
    // Direct access to underlying state (no Vue reactivity)
    const currentState = this.gameClient.tree.state as HeroDefenseState
    if (!currentState) return
    
    // Update score from state
    const score = currentState.score || 0
    this.scoreText.setText(`Score: ${score}`)
  }
  
  private createPlayerSprite(playerID: string, isCurrentPlayer: boolean = false): Phaser.GameObjects.Container {
    const container = this.add.container(0, 0)
    
    // Player body (circle) - size in world units
    // Current player: larger and brighter, other players: smaller and darker
    const bodyRadius = isCurrentPlayer ? 2 : 1.5
    const bodyColor = isCurrentPlayer ? 0x667eea : 0x9999cc
    const body = this.add.circle(0, 0, bodyRadius, bodyColor)
    
    // Add border for current player
    if (isCurrentPlayer) {
      const border = this.add.circle(0, 0, bodyRadius + 0.2, 0xffffff, 0.3)
      container.add(border)
    }
    
    // Direction indicator: arrow pointing forward
    // Use a more visible arrow with black color
    const arrowLength = isCurrentPlayer ? 3 : 2.5
    const arrowWidth = isCurrentPlayer ? 0.8 : 0.6
    
    // Arrow body (line pointing forward) - black color
    // Pointing right initially (positive X), which matches toAngle() reference
    const arrowBody = this.add.line(0, 0, 0, 0, arrowLength, 0, 0x000000, 1)
    arrowBody.setLineWidth(arrowWidth)
    arrowBody.setOrigin(0, 0.5) // Anchor at left center
    
    // Arrow head (triangle) - black color, pointing right
    const arrowHead = this.add.triangle(
      arrowLength, 0,  // Position at tip (right)
      arrowLength + 1, 0,  // Right point
      arrowLength - 0.3, -arrowWidth,  // Top point
      arrowLength - 0.3, arrowWidth,   // Bottom point
      0x000000, 1
    )
    
    container.add([body, arrowBody, arrowHead])
    container.setData('playerID', playerID)
    
    return container
  }
}
