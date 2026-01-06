import Phaser from 'phaser'
import type { HeroDefenseStateTree } from '../generated/hero-defense/index'
import type { PlayAction, PlayResponse } from '../generated/defs'

interface GameClient {
  tree: HeroDefenseStateTree | null
  play: (payload: PlayAction) => Promise<PlayResponse>
}

export class GameScene extends Phaser.Scene {
  private gameClient: GameClient | null = null
  private scoreText!: Phaser.GameObjects.Text
  private player!: Phaser.GameObjects.Rectangle
  private cursors!: Phaser.Types.Input.Keyboard.CursorKeys
  
  constructor() {
    super({ key: 'GameScene' })
  }
  
  setGameClient(client: GameClient) {
    this.gameClient = client
    
    // If scene is already created, update score immediately
    if (this.scoreText) {
      this.updateFromState()
    }
  }
  
  create() {
    // Create white background (use scene dimensions)
    const width = this.scale.width
    const height = this.scale.height
    this.add.rectangle(width / 2, height / 2, width, height, 0xffffff)
    
    // Create score text with black color
    this.scoreText = this.add.text(20, 20, 'Score: 0', {
      fontSize: '32px',
      color: '#000000',
      fontFamily: 'Arial'
    })
    
    // Create player (simple rectangle for now) - center of scene
    this.player = this.add.rectangle(width / 2, height / 2, 50, 50, 0x667eea)
    this.player.setInteractive()
    
    // Add click handler to player - send action to increase score
    this.player.on('pointerdown', () => {
      this.sendPlayAction()
    })
    
    // Add hover effect
    this.player.on('pointerover', () => {
      this.player.setScale(1.1)
      this.input.setDefaultCursor('pointer')
    })
    
    this.player.on('pointerout', () => {
      this.player.setScale(1.0)
      this.input.setDefaultCursor('default')
    })
    
    // Create cursor keys
    this.cursors = this.input.keyboard!.createCursorKeys()
    
    // Player movement
    // Space bar also sends action
    this.input.keyboard!.on('keydown', (event: KeyboardEvent) => {
      if (event.key === ' ') {
        this.sendPlayAction()
      }
    })
    
    // Update score when state changes (if gameClient is already set)
    if (this.gameClient) {
      this.updateFromState()
    }
  }
  
  update() {
    const speed = 200
    let dx = 0
    let dy = 0
    
    // Handle movement
    if (this.cursors.left.isDown || this.input.keyboard!.checkDown(this.input.keyboard!.addKey('A'))) {
      dx = -speed
    } else if (this.cursors.right.isDown || this.input.keyboard!.checkDown(this.input.keyboard!.addKey('D'))) {
      dx = speed
    }
    
    if (this.cursors.up.isDown || this.input.keyboard!.checkDown(this.input.keyboard!.addKey('W'))) {
      dy = -speed
    } else if (this.cursors.down.isDown || this.input.keyboard!.checkDown(this.input.keyboard!.addKey('S'))) {
      dy = speed
    }
    
    // Update player position
    const deltaTime = this.game.loop.delta / 1000
    this.player.x += dx * deltaTime
    this.player.y += dy * deltaTime
    
    // Keep player in bounds (use scene dimensions)
    const width = this.scale.width
    const height = this.scale.height
    this.player.x = Phaser.Math.Clamp(this.player.x, 25, width - 25)
    this.player.y = Phaser.Math.Clamp(this.player.y, 25, height - 25)
    
    // Update from state if available
    if (this.gameClient) {
      this.updateFromState()
    }
  }
  
  private updateFromState() {
    if (!this.gameClient || !this.gameClient.tree) return
    
    // Direct access to underlying state (no Vue reactivity)
    const currentState = this.gameClient.tree.state as { score?: number }
    if (!currentState) return
    
    // Update score from state
    const score = currentState.score || 0
    this.scoreText.setText(`Score: ${score}`)
  }
  
  private async sendPlayAction() {
    if (!this.gameClient) return
    
    try {
      await this.gameClient.play({})
    } catch (error) {
      console.error('Failed to send action:', error)
    }
  }
}
