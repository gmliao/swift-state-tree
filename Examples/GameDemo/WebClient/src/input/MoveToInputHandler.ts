import Phaser from 'phaser'

export interface MoveToInputConfig {
  /** Marker color (default: 0xff0000) */
  markerColor?: number
  /** Marker radius (default: 1) */
  markerRadius?: number
  /** Marker fade duration in ms (default: 500) */
  markerDuration?: number
  /** Error marker radius (default: 1.5) */
  errorMarkerRadius?: number
  /** Error marker duration in ms (default: 1000) */
  errorMarkerDuration?: number
}

export interface MoveToTarget {
  x: number
  y: number
}

/**
 * Handles click-to-move input with visual feedback
 */
export class MoveToInputHandler {
  private readonly scene: Phaser.Scene
  private readonly config: Required<MoveToInputConfig>
  private enabled: boolean = true
  private onMoveCallback: ((target: MoveToTarget) => Promise<void>) | null = null
  private screenToWorldFn: ((screenX: number, screenY: number) => { x: number; y: number }) | null = null

  constructor(scene: Phaser.Scene, config: MoveToInputConfig = {}) {
    this.scene = scene
    this.config = {
      markerColor: config.markerColor ?? 0xff0000,
      markerRadius: config.markerRadius ?? 1,
      markerDuration: config.markerDuration ?? 500,
      errorMarkerRadius: config.errorMarkerRadius ?? 1.5,
      errorMarkerDuration: config.errorMarkerDuration ?? 1000,
    }
  }

  /**
   * Initialize input handler
   * @param screenToWorld Function to convert screen to world coordinates
   * @param onMove Callback when move is requested
   */
  init(
    screenToWorld: (screenX: number, screenY: number) => { x: number; y: number },
    onMove: (target: MoveToTarget) => Promise<void>
  ): this {
    this.screenToWorldFn = screenToWorld
    this.onMoveCallback = onMove

    this.scene.input.on('pointerdown', this.handlePointerDown, this)
    return this
  }

  /**
   * Enable or disable input handling
   */
  setEnabled(enabled: boolean): this {
    this.enabled = enabled
    return this
  }

  /**
   * Check if input is enabled
   */
  isEnabled(): boolean {
    return this.enabled
  }

  /**
   * Destroy input handler
   */
  destroy(): void {
    this.scene.input.off('pointerdown', this.handlePointerDown, this)
    this.onMoveCallback = null
    this.screenToWorldFn = null
  }

  private async handlePointerDown(pointer: Phaser.Input.Pointer): Promise<void> {
    if (!this.enabled || !this.onMoveCallback || !this.screenToWorldFn) return

    const worldPos = this.screenToWorldFn(pointer.x, pointer.y)
    
    // Show click marker
    this.showClickMarker(worldPos.x, worldPos.y)

    try {
      await this.onMoveCallback(worldPos)
      console.log('MoveToEvent sent successfully', worldPos)
    } catch (error) {
      console.error('Failed to send MoveToEvent:', error)
      this.showErrorMarker(worldPos.x, worldPos.y)
    }
  }

  private showClickMarker(x: number, y: number): void {
    const { markerColor, markerRadius, markerDuration } = this.config
    const marker = this.scene.add.circle(x, y, markerRadius, markerColor, 0.5)
    
    this.scene.tweens.add({
      targets: marker,
      alpha: 0,
      scale: 2,
      duration: markerDuration,
      onComplete: () => marker.destroy()
    })
  }

  private showErrorMarker(x: number, y: number): void {
    const { markerColor, errorMarkerRadius, errorMarkerDuration } = this.config
    const marker = this.scene.add.circle(x, y, errorMarkerRadius, markerColor, 0.8)
    
    this.scene.tweens.add({
      targets: marker,
      alpha: 0,
      scale: 3,
      duration: errorMarkerDuration,
      onComplete: () => marker.destroy()
    })
  }
}
