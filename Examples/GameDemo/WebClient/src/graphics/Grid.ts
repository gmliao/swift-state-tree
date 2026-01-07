import Phaser from 'phaser'

export interface GridConfig {
  /** Grid cell size in world units (default: 8) */
  cellSize?: number
  /** Grid extends from -range to +range (default: 500) */
  range?: number
  /** Minor grid line color (default: 0xe0e0e0) */
  minorLineColor?: number
  /** Minor grid line alpha (default: 0.3) */
  minorLineAlpha?: number
  /** Major grid line interval in cells (default: 4) */
  majorLineInterval?: number
  /** Major grid line color (default: 0xcccccc) */
  majorLineColor?: number
  /** Major grid line alpha (default: 0.5) */
  majorLineAlpha?: number
  /** Axis line color (default: 0x999999) */
  axisColor?: number
  /** Axis line alpha (default: 0.7) */
  axisAlpha?: number
  /** Whether to draw axes at origin (default: true) */
  showAxes?: boolean
}

/**
 * A reusable grid background for Phaser scenes
 */
export class Grid {
  private readonly scene: Phaser.Scene
  private readonly config: Required<GridConfig>
  private lines: Phaser.GameObjects.Line[] = []

  constructor(scene: Phaser.Scene, config: GridConfig = {}) {
    this.scene = scene
    this.config = {
      cellSize: config.cellSize ?? 8,
      range: config.range ?? 500,
      minorLineColor: config.minorLineColor ?? 0xe0e0e0,
      minorLineAlpha: config.minorLineAlpha ?? 0.3,
      majorLineInterval: config.majorLineInterval ?? 4,
      majorLineColor: config.majorLineColor ?? 0xcccccc,
      majorLineAlpha: config.majorLineAlpha ?? 0.5,
      axisColor: config.axisColor ?? 0x999999,
      axisAlpha: config.axisAlpha ?? 0.7,
      showAxes: config.showAxes ?? true,
    }
  }

  /**
   * Create and render the grid
   */
  create(): this {
    const { cellSize, range, minorLineColor, minorLineAlpha } = this.config
    const { majorLineInterval, majorLineColor, majorLineAlpha } = this.config
    const { axisColor, axisAlpha, showAxes } = this.config

    // Draw minor vertical lines
    for (let x = -range; x <= range; x += cellSize) {
      const line = this.scene.add.line(0, 0, x, -range, x, range, minorLineColor, minorLineAlpha)
      line.setOrigin(0, 0)
      this.lines.push(line)
    }

    // Draw minor horizontal lines
    for (let y = -range; y <= range; y += cellSize) {
      const line = this.scene.add.line(0, 0, -range, y, range, y, minorLineColor, minorLineAlpha)
      line.setOrigin(0, 0)
      this.lines.push(line)
    }

    // Draw major lines
    const majorGridSize = cellSize * majorLineInterval
    for (let x = -range; x <= range; x += majorGridSize) {
      const line = this.scene.add.line(0, 0, x, -range, x, range, majorLineColor, majorLineAlpha)
      line.setOrigin(0, 0)
      this.lines.push(line)
    }
    for (let y = -range; y <= range; y += majorGridSize) {
      const line = this.scene.add.line(0, 0, -range, y, range, y, majorLineColor, majorLineAlpha)
      line.setOrigin(0, 0)
      this.lines.push(line)
    }

    // Draw axes at origin
    if (showAxes) {
      const yAxis = this.scene.add.line(0, 0, 0, -range, 0, range, axisColor, axisAlpha)
      yAxis.setOrigin(0, 0)
      this.lines.push(yAxis)

      const xAxis = this.scene.add.line(0, 0, -range, 0, range, 0, axisColor, axisAlpha)
      xAxis.setOrigin(0, 0)
      this.lines.push(xAxis)
    }

    return this
  }

  /**
   * Set visibility of the grid
   */
  setVisible(visible: boolean): this {
    for (const line of this.lines) {
      line.setVisible(visible)
    }
    return this
  }

  /**
   * Set depth (z-index) of the grid
   */
  setDepth(depth: number): this {
    for (const line of this.lines) {
      line.setDepth(depth)
    }
    return this
  }

  /**
   * Destroy all grid lines
   */
  destroy(): void {
    for (const line of this.lines) {
      line.destroy()
    }
    this.lines = []
  }
}
