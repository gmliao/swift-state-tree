import Phaser from 'phaser'

export interface PlaceTurretInputConfig {
  /** Marker color (default: 0x00ff00) */
  markerColor?: number
  /** Marker radius (default: 1.5) */
  markerRadius?: number
  /** Invalid marker color (default: 0xff0000) */
  invalidMarkerColor?: number
}

export interface PlaceTurretTarget {
  x: number
  y: number
}

/**
 * Handles turret placement input (keyboard key + click)
 */
export class PlaceTurretInputHandler {
  private readonly scene: Phaser.Scene
  private readonly config: Required<PlaceTurretInputConfig>
  private enabled: boolean = true
  private isPlacingMode: boolean = false
  private onPlaceCallback: ((target: PlaceTurretTarget) => Promise<void>) | null = null
  private screenToWorldFn: ((screenX: number, screenY: number) => { x: number; y: number }) | null = null
  private previewMarker: Phaser.GameObjects.Arc | null = null

  constructor(scene: Phaser.Scene, config: PlaceTurretInputConfig = {}) {
    this.scene = scene
    this.config = {
      markerColor: config.markerColor ?? 0x00ff00,
      markerRadius: config.markerRadius ?? 1.5,
      invalidMarkerColor: config.invalidMarkerColor ?? 0xff0000,
    }
  }

  /**
   * Initialize input handler
   * @param screenToWorld Function to convert screen to world coordinates
   * @param onPlace Callback when place is requested
   */
  init(
    screenToWorld: (screenX: number, screenY: number) => { x: number; y: number },
    onPlace: (target: PlaceTurretTarget) => Promise<void>
  ): this {
    this.screenToWorldFn = screenToWorld
    this.onPlaceCallback = onPlace

    // T key to toggle placement mode
    this.scene.input.keyboard?.on('keydown-T', this.togglePlacementMode, this)
    
    // ESC to cancel placement mode
    this.scene.input.keyboard?.on('keydown-ESC', this.cancelPlacementMode, this)
    
    // Click to place when in placement mode
    this.scene.input.on('pointerdown', this.handlePointerDown, this)
    
    // Update preview marker
    this.scene.input.on('pointermove', this.updatePreviewMarker, this)
    
    return this
  }

  /**
   * Enable or disable input handling
   */
  setEnabled(enabled: boolean): this {
    this.enabled = enabled
    if (!enabled) {
      this.cancelPlacementMode()
    }
    return this
  }

  /**
   * Check if input is enabled
   */
  isEnabled(): boolean {
    return this.enabled
  }

  /**
   * Check if in placement mode
   */
  isInPlacementMode(): boolean {
    return this.isPlacingMode
  }

  /**
   * Destroy input handler
   */
  destroy(): void {
    this.scene.input.keyboard?.off('keydown-T', this.togglePlacementMode, this)
    this.scene.input.keyboard?.off('keydown-ESC', this.cancelPlacementMode, this)
    this.scene.input.off('pointerdown', this.handlePointerDown, this)
    this.scene.input.off('pointermove', this.updatePreviewMarker, this)
    this.onPlaceCallback = null
    this.screenToWorldFn = null
    this.cancelPlacementMode()
  }

  private togglePlacementMode(): void {
    if (!this.enabled) return
    
    this.isPlacingMode = !this.isPlacingMode
    
    if (this.isPlacingMode) {
      console.log('🏰 Turret placement mode enabled. Click to place, ESC to cancel.')
      this.updatePreviewMarker()
    } else {
      this.cancelPlacementMode()
    }
  }

  private cancelPlacementMode(): void {
    this.isPlacingMode = false
    if (this.previewMarker) {
      this.previewMarker.destroy()
      this.previewMarker = null
    }
  }

  private updatePreviewMarker(): void {
    if (!this.isPlacingMode || !this.screenToWorldFn) {
      if (this.previewMarker) {
        this.previewMarker.destroy()
        this.previewMarker = null
      }
      return
    }

    const pointer = this.scene.input.activePointer
    const worldPos = this.screenToWorldFn(pointer.x, pointer.y)
    
    if (!this.previewMarker) {
      this.previewMarker = this.scene.add.circle(
        worldPos.x,
        worldPos.y,
        this.config.markerRadius,
        this.config.markerColor,
        0.5
      )
    } else {
      this.previewMarker.x = worldPos.x
      this.previewMarker.y = worldPos.y
    }
  }

  private async handlePointerDown(pointer: Phaser.Input.Pointer): Promise<void> {
    if (!this.isPlacingMode || !this.enabled || !this.onPlaceCallback || !this.screenToWorldFn) {
      return
    }

    // Only handle left-click
    if (!pointer.leftButtonDown()) return

    const worldPos = this.screenToWorldFn(pointer.x, pointer.y)
    
    // Remove preview marker
    this.cancelPlacementMode()
    
    // Show placement marker
    this.showPlaceMarker(worldPos.x, worldPos.y)
    
    try {
      await this.onPlaceCallback(worldPos)
      console.log('PlaceTurretEvent sent successfully', worldPos)
    } catch (error) {
      console.error('Failed to send PlaceTurretEvent:', error)
      this.showErrorMarker(worldPos.x, worldPos.y)
    }
  }

  private showPlaceMarker(x: number, y: number): void {
    const { markerColor, markerRadius } = this.config
    const marker = this.scene.add.circle(x, y, markerRadius, markerColor, 0.8)
    
    this.scene.tweens.add({
      targets: marker,
      alpha: 0,
      scale: 2,
      duration: 500,
      onComplete: () => marker.destroy()
    })
  }

  private showErrorMarker(x: number, y: number): void {
    const { invalidMarkerColor, markerRadius } = this.config
    const marker = this.scene.add.circle(x, y, markerRadius, invalidMarkerColor, 0.8)
    
    this.scene.tweens.add({
      targets: marker,
      alpha: 0,
      scale: 3,
      duration: 1000,
      onComplete: () => marker.destroy()
    })
  }
}
