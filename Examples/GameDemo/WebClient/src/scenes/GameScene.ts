import Phaser from 'phaser'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { HeroDefenseState, MoveToEvent, PlayAction, PlayResponse, PlayerState, Position2 } from '../generated/defs'
import { FIXED_POINT_SCALE } from '../generated/defs'

interface GameClient {
  tree: HeroDefenseStateTree | null
  play: (payload: PlayAction) => Promise<PlayResponse>
  events: {
    moveTo: (payload: MoveToEvent) => Promise<void>
  }
  currentPlayerID: string | null
}

function toRotationRadians(
  rotation: { degrees?: number },
  context: string,
  logMissing: boolean = true
): number | null {
  const degrees = rotation?.degrees
  if (!Number.isFinite(degrees)) {
    if (logMissing) {
      console.warn(`⚠️ ${context}: rotation.degrees is undefined or invalid`)
    }
    return null
  }
  let normalizedDegrees = degrees as number
  if (Math.abs(normalizedDegrees) > 360) {
    normalizedDegrees = normalizedDegrees / FIXED_POINT_SCALE
  }
  const radians = normalizedDegrees * Math.PI / 180
  return Phaser.Math.Angle.Wrap(radians)
}

/**
 * Encapsulates a player's sprite and update logic
 */
class PlayerSprite {
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
   * Note: SDK already converts Position2 from fixed-point to float in decodeSnapshotValue,
   * so we can directly use playerState.position.v.x and v.y without further conversion
   */
  update(playerState: PlayerState): void {
    // SDK already converted Position2.v from fixed-point (64000) to float (64.0)
    // So we can directly use the values without Position2ToFloat conversion
    const serverPos = this.readServerPosition(playerState, 'update')
    if (!serverPos) return
    const serverRotation = toRotationRadians(
      playerState.rotation,
      `PlayerSprite.update: rotation missing for player ${this.playerID}`,
      false
    )
    
    // Get current visual position (lerped)
    const currentX = this.container.x
    const currentY = this.container.y
    const targetX = serverPos.x
    const targetY = serverPos.y
    
    // Smooth position interpolation (lerp)
    this.container.x = currentX + (targetX - currentX) * this.lerpFactor
    this.container.y = currentY + (targetY - currentY) * this.lerpFactor
    
    // Smooth rotation interpolation
    if (serverRotation == null) {
      return
    }

    const currentRotation = this.container.rotation
    let targetRotation = serverRotation
    
    // Normalize rotation difference
    let rotationDiff = targetRotation - currentRotation
    if (rotationDiff > Math.PI) rotationDiff -= 2 * Math.PI
    if (rotationDiff < -Math.PI) rotationDiff += 2 * Math.PI
    
    this.container.rotation = currentRotation + rotationDiff * this.lerpFactor
  }
  
  /**
   * Set initial position immediately (no lerp) to avoid jumping
   * Note: SDK already converts Position2 from fixed-point to float
   */
  setInitialPosition(playerState: PlayerState): void {
    // SDK already converted, use directly
    const pos = this.readServerPosition(playerState, 'setInitialPosition')
    if (!pos) return
    const rotation = toRotationRadians(
      playerState.rotation,
      `PlayerSprite.setInitialPosition: rotation missing for player ${this.playerID}`
    )
    this.container.x = pos.x
    this.container.y = pos.y
    if (rotation != null) {
      this.container.rotation = rotation
    }
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

export class GameScene extends Phaser.Scene {
  private gameClient: GameClient | null = null
  private scoreText!: Phaser.GameObjects.Text
  private players: Map<string, PlayerSprite> = new Map()
  private currentPlayer: PlayerSprite | null = null
  private lastStateLogTime: number = 0
  private positionOverlayText: Phaser.GameObjects.Text | null = null
  
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
    
    // Try to use player sprite if available
    if (this.currentPlayer) {
      // Use startFollow for smooth camera following
      // Parameters: (target, roundPixels, lerpX, lerpY)
      // lerpX and lerpY control smoothness (0.1 = smooth, 1.0 = instant)
      this.cameras.main.startFollow(this.currentPlayer.container, false, 0.1, 0.1)
      return
    }
    
    // If sprite doesn't exist yet, schedule retry
    const state = this.gameClient.tree.state as HeroDefenseState
    const currentPlayerID = this.gameClient.currentPlayerID
    const playerState = state.players?.[currentPlayerID]
    
    if (playerState && playerState.position && playerState.position.v) {
      // Set initial camera position, follow will be set up in update() when sprite is created
      // SDK already converted Position2 from fixed-point to float, so use directly
      const pos = { x: playerState.position.v.x, y: playerState.position.v.y }
      this.cameras.main.centerOn(pos.x, pos.y)
    }
  }
  
  create() {
    // No world bounds - allow infinite/unbounded world with negative coordinates
    // Set camera view size to approximately 8 grid cells (8 * 8 = 64 units)
    this.updateCameraZoom()
    
    // Listen for resize events to update camera zoom and reposition overlay
    this.scale.on('resize', () => {
      this.updateCameraZoom()
      // Reposition overlay text to center after resize
      if (this.positionOverlayText) {
        this.positionOverlayText.x = this.scale.width / 2
        this.positionOverlayText.y = this.scale.height / 2
      }
    }, this)
    
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
    
    // Create position overlay text at screen center (2D UI)
    const centerX = this.scale.width / 2
    const centerY = this.scale.height / 2
    this.positionOverlayText = this.add.text(centerX, centerY, '(0.0, 0.0)', {
      fontSize: '12px',
      color: '#000000',
      align: 'center',
      strokeThickness: 0,
      fontFamily: 'Arial, sans-serif'
    })
    this.positionOverlayText.setOrigin(0.5, -2) // Center both horizontally and vertically
    this.positionOverlayText.setScrollFactor(0, 0) // Fixed to camera (2D UI) - won't move with world
    this.positionOverlayText.setDepth(1000) // Always on top
    // Ensure text is not affected by camera zoom
    this.positionOverlayText.setScale(0.1) // Explicitly set scale to 1
    
    // Mouse click handler to move player
    // Convert screen coordinates to world coordinates
    this.input.on('pointerdown', async (pointer: Phaser.Input.Pointer) => {
      if (this.gameClient && this.gameClient.tree && this.gameClient.events) {
        // Get world coordinates from camera
        const worldX = this.cameras.main.getWorldPoint(pointer.x, pointer.y).x
        const worldY = this.cameras.main.getWorldPoint(pointer.x, pointer.y).y
        
        // No clamping - allow negative coordinates
        // SDK automatically converts float to fixed-point integers, so we can use float directly
        const target = { v: { x: worldX, y: worldY } } as Position2
        
        // Visual feedback: draw a temporary marker at click position
        const marker = this.add.circle(worldX, worldY, 1, 0xff0000, 0.5)
        this.tweens.add({
          targets: marker,
          alpha: 0,
          scale: 2,
          duration: 500,
          onComplete: () => marker.destroy()
        })
        
        // Send move event with error handling
        try {
          await this.gameClient.events.moveTo({ target })
          console.log('MoveToEvent sent successfully', { worldX, worldY, target })
        } catch (error) {
          console.error('Failed to send MoveToEvent:', error)
          // Show error feedback
          const errorMarker = this.add.circle(worldX, worldY, 1.5, 0xff0000, 0.8)
          this.tweens.add({
            targets: errorMarker,
            alpha: 0,
            scale: 3,
            duration: 1000,
            onComplete: () => errorMarker.destroy()
          })
        }
      }
    })
    
    // Update from state if available
    if (this.gameClient) {
      this.updateFromState()
      // Setup camera follow if not already set up
      // Check if currentPlayer exists to determine if we should set up follow
      if (this.gameClient.currentPlayerID && this.currentPlayer) {
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
    
    // Reset current player tracking at start of each frame
    this.currentPlayer = null
    
    // Log state update (throttled to avoid spam)
    const now = Date.now()
    if (!this.lastStateLogTime || now - this.lastStateLogTime > 1000) {
      const playerCount = Object.keys(state.players || {}).length
      const movingCount = Object.values(state.players || {}).filter(p => p.targetPosition != null).length
      console.log(`📥 Client: State update received - ${playerCount} players, ${movingCount} moving`)
      this.lastStateLogTime = now
    }
    
    // Update all players
    for (const [playerID, playerState] of Object.entries(state.players || {})) {
      let player = this.players.get(playerID)
      const isCurrentPlayer = currentPlayerID !== null && String(playerID) === String(currentPlayerID)
      
      if (!player) {
        // Create new player sprite
        player = new PlayerSprite(this, playerID, isCurrentPlayer)
        // IMPORTANT: Set sprite to correct position immediately to avoid jumping
        player.setInitialPosition(playerState)
        this.players.set(playerID, player)
        
        // Log first position received for this player
        // If this is the current player, set it immediately and setup camera follow
        if (isCurrentPlayer) {
          this.currentPlayer = player
          this.cameras.main.startFollow(player.container, false, 0.1, 0.1)
        }
      }
      
      // Update player sprite (handles lerp internally)
      player.update(playerState)
      
      // Track current player and update UI
      if (isCurrentPlayer) {
        this.currentPlayer = player
        // Ensure camera is following this sprite
        this.cameras.main.startFollow(player.container, false, 0.1, 0.1)
        
        // Get server position for UI display
        const serverPos = player.getServerPosition(playerState)
        this.updateCurrentPlayerPositionText(serverPos.x, serverPos.y)
      }
    }
    
    // Remove sprites for players that left
    for (const [playerID, player] of this.players) {
      if (!state.players[playerID]) {
        player.destroy()
        this.players.delete(playerID)
        if (playerID === currentPlayerID) {
          this.currentPlayer = null
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
  
  private updateCurrentPlayerPositionText(x: number, y: number) {
    // Update overlay text at screen center
    if (this.positionOverlayText) {
      this.positionOverlayText.setText(`(${x.toFixed(1)}, ${y.toFixed(1)})`)
    }
  }
  
  // Removed createPlayerSprite - now handled by PlayerSprite class
}
