import Phaser from 'phaser'

/**
 * Handles mouse position tracking and player rotation updates
 */
export class MouseRotationHandler {
  private readonly scene: Phaser.Scene
  private enabled: boolean = true
  private screenToWorldFn: ((screenX: number, screenY: number) => { x: number; y: number }) | null = null
  private getPlayerPositionFn: (() => { x: number; y: number } | null) | null = null
  private onRotationUpdateFn: ((angle: number) => void) | null = null
  private lastUpdateTime: number = 0
  private readonly updateInterval: number = 50 // Update every 50ms (20 times per second)

  constructor(scene: Phaser.Scene) {
    this.scene = scene
  }

  /**
   * Initialize mouse rotation handler
   * @param screenToWorld Function to convert screen to world coordinates
   * @param getPlayerPosition Function to get current player position
   * @param onRotationUpdate Callback when rotation should be updated
   */
  init(
    screenToWorld: (screenX: number, screenY: number) => { x: number; y: number },
    getPlayerPosition: () => { x: number; y: number } | null,
    onRotationUpdate: (angle: number) => void
  ): this {
    this.screenToWorldFn = screenToWorld
    this.getPlayerPositionFn = getPlayerPosition
    this.onRotationUpdateFn = onRotationUpdate

    // Track mouse movement
    this.scene.input.on('pointermove', this.handlePointerMove, this)
    
    return this
  }

  /**
   * Enable or disable mouse rotation
   */
  setEnabled(enabled: boolean): this {
    this.enabled = enabled
    return this
  }

  /**
   * Check if enabled
   */
  isEnabled(): boolean {
    return this.enabled
  }

  /**
   * Destroy handler
   */
  destroy(): void {
    this.scene.input.off('pointermove', this.handlePointerMove, this)
    this.screenToWorldFn = null
    this.getPlayerPositionFn = null
    this.onRotationUpdateFn = null
  }

  private handlePointerMove(pointer: Phaser.Input.Pointer): void {
    if (!this.enabled || !this.screenToWorldFn || !this.getPlayerPositionFn || !this.onRotationUpdateFn) {
      return
    }

    // Throttle updates to avoid too frequent calls
    const now = Date.now()
    if (now - this.lastUpdateTime < this.updateInterval) {
      return
    }
    this.lastUpdateTime = now

    // Get mouse position in world coordinates
    const mouseWorldPos = this.screenToWorldFn(pointer.x, pointer.y)
    
    // Get player position
    const playerPos = this.getPlayerPositionFn()
    if (!playerPos) {
      return
    }

    // Calculate angle from player to mouse
    const dx = mouseWorldPos.x - playerPos.x
    const dy = mouseWorldPos.y - playerPos.y
    const angle = Math.atan2(dy, dx)

    // Update rotation
    this.onRotationUpdateFn(angle)
  }
}
