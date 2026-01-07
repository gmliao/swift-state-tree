import Phaser from 'phaser'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { HeroDefenseState } from '../generated/defs'
import { Position2 } from '../generated/defs'
import { GameCamera } from '../camera/GameCamera'
import { Grid } from '../graphics/Grid'
import { MoveToInputHandler } from '../input/MoveToInputHandler'
import { PlayerManager } from '../managers/PlayerManager'

export class GameScene extends Phaser.Scene {
  private tree: HeroDefenseStateTree | null = null
  private gameCamera!: GameCamera
  private moveInput!: MoveToInputHandler
  private playerManager!: PlayerManager
  private scoreText!: Phaser.GameObjects.Text
  private grid!: Grid
  private positionOverlayText: Phaser.GameObjects.Text | null = null
  
  constructor() {
    super({ key: 'GameScene' })
  }
  
  setStateTree(tree: HeroDefenseStateTree) {
    this.tree = tree
    
    // If scene is already created, update score immediately and setup camera follow
    if (this.scoreText) {
      this.updateFromState()
      
      // Subscribe player manager to tree for onAdd/onRemove events
      // tree.currentPlayerID is automatically used
      if (this.playerManager) {
        this.playerManager.subscribeToTree(tree)
      }
      
      // Setup camera follow on next frame to ensure sprites are created
      this.time.delayedCall(0, () => {
        this.setupCameraFollow()
      })
    }
  }
  
  private setupCameraFollow() {
    if (!this.tree || !this.tree.currentPlayerID) return
    
    // Try to use player sprite if available
    const currentPlayer = this.playerManager.getCurrentPlayer()
    if (currentPlayer) {
      this.gameCamera.startFollow(currentPlayer.container)
      return
    }
    
    // If sprite doesn't exist yet, center on initial position
    const state = this.tree.state as HeroDefenseState
    const playerState = state.players?.[this.tree.currentPlayerID]
    
    if (playerState && playerState.position && playerState.position.v) {
      this.gameCamera.centerOn(playerState.position.v.x, playerState.position.v.y)
    }
  }
  
  create() {
    // Initialize camera
    this.gameCamera = new GameCamera(this).init()
    
    // Listen for resize events to reposition overlay
    this.scale.on('resize', () => {
      if (this.positionOverlayText) {
        this.positionOverlayText.x = this.scale.width / 2
        this.positionOverlayText.y = this.scale.height / 2
      }
    }, this)
    
    // Create white background covering a large area
    const backgroundSize = 1000
    this.add.rectangle(0, 0, backgroundSize, backgroundSize, 0xffffff)
    
    // Create grid background
    this.grid = new Grid(this).create()
    
    // Create score text (fixed to camera)
    this.scoreText = this.add.text(10, 10, 'Score: 0', {
      fontSize: '24px',
      color: '#000000',
      fontFamily: 'Arial'
    })
    this.scoreText.setScrollFactor(0)
    
    // Create position overlay text at screen center
    const centerX = this.scale.width / 2
    const centerY = this.scale.height / 2
    this.positionOverlayText = this.add.text(centerX, centerY, '(0.0, 0.0)', {
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
    
    // Initialize move-to input handler
    this.moveInput = new MoveToInputHandler(this).init(
      (screenX, screenY) => this.gameCamera.screenToWorld(screenX, screenY),
      async (target) => {
        if (this.tree) {
          const position = new Position2({ x: target.x, y: target.y }, false)
          await this.tree.events.moveTo({ target: position })
        }
      }
    )
    
    // Initialize player manager
    this.playerManager = new PlayerManager(this)
      .onCurrentPlayerUpdated((player, serverPos) => {
        this.gameCamera.startFollow(player.container)
        this.updateCurrentPlayerPositionText(serverPos.x, serverPos.y)
      })
    
    // Subscribe to tree if available (for onAdd/onRemove events)
    // tree.currentPlayerID is automatically used
    if (this.tree) {
      this.playerManager.subscribeToTree(this.tree)
    }
    
    // Update from state if available
    if (this.tree) {
      this.updateFromState()
      if (this.tree.currentPlayerID && this.playerManager.getCurrentPlayer()) {
        this.setupCameraFollow()
      }
    }
  }
  
  update() {
    if (!this.tree) return
    
    const state = this.tree.state as HeroDefenseState
    
    // Update player manager with current player ID (from tree)
    if (this.tree.currentPlayerID) {
      this.playerManager.setCurrentPlayerID(this.tree.currentPlayerID)
    }
    
    // Update all players (handles creation, updates, and removal)
    this.playerManager.update(state.players || {})
    
    // Update score
    this.updateFromState()
  }
  
  private updateFromState() {
    if (!this.tree) return
    
    // Direct access to underlying state (no Vue reactivity)
    const currentState = this.tree.state as HeroDefenseState
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

  /** Get the grid instance (for external control) */
  getGrid(): Grid {
    return this.grid
  }

  /** Get the move input handler (for external control) */
  getMoveInput(): MoveToInputHandler {
    return this.moveInput
  }
}
