import Phaser from 'phaser'

export interface GameCameraConfig {
  /** Grid cell size in world units (default: 8) */
  cellSize?: number
  /** Number of cells to show in view (default: 16) */
  cellsToShow?: number
  /** Camera follow lerp factor (default: 0.1) */
  followLerp?: number
}

/**
 * Manages camera zoom and follow behavior for the game
 */
export class GameCamera {
  private readonly scene: Phaser.Scene
  private readonly config: Required<GameCameraConfig>
  private followTarget: Phaser.GameObjects.GameObject | null = null

  constructor(scene: Phaser.Scene, config: GameCameraConfig = {}) {
    this.scene = scene
    this.config = {
      cellSize: config.cellSize ?? 8,
      cellsToShow: config.cellsToShow ?? 16,
      followLerp: config.followLerp ?? 0.1,
    }
  }

  /**
   * Initialize camera settings
   */
  init(): this {
    this.updateZoom()
    this.scene.cameras.main.centerOn(0, 0)

    // Listen for resize events
    this.scene.scale.on('resize', () => {
      this.updateZoom()
    }, this)

    return this
  }

  /**
   * Update camera zoom based on viewport size
   */
  updateZoom(): this {
    const { cellSize, cellsToShow } = this.config
    const viewSizeInUnits = cellSize * cellsToShow

    const viewportWidth = this.scene.scale.width
    const viewportHeight = this.scene.scale.height

    const zoomX = viewportWidth / viewSizeInUnits
    const zoomY = viewportHeight / viewSizeInUnits
    const zoom = Math.max(zoomX, zoomY)

    this.scene.cameras.main.setZoom(zoom)
    return this
  }

  /**
   * Start following a game object
   */
  startFollow(target: Phaser.GameObjects.GameObject): this {
    this.followTarget = target
    const lerp = this.config.followLerp
    this.scene.cameras.main.startFollow(target, false, lerp, lerp)
    return this
  }

  /**
   * Stop following current target
   */
  stopFollow(): this {
    this.scene.cameras.main.stopFollow()
    this.followTarget = null
    return this
  }

  /**
   * Center camera on a position
   */
  centerOn(x: number, y: number): this {
    this.scene.cameras.main.centerOn(x, y)
    return this
  }

  /**
   * Get the current follow target
   */
  getFollowTarget(): Phaser.GameObjects.GameObject | null {
    return this.followTarget
  }

  /**
   * Convert screen coordinates to world coordinates
   */
  screenToWorld(screenX: number, screenY: number): { x: number; y: number } {
    const worldPoint = this.scene.cameras.main.getWorldPoint(screenX, screenY)
    return { x: worldPoint.x, y: worldPoint.y }
  }
}
