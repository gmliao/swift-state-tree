// Sources/SwiftStateTreeDeterministicMath/Grid/Grid2.swift
//
// Grid utilities for converting between world coordinates and cell coordinates.
// All operations use integer arithmetic for deterministic behavior.

import Foundation

/// A 2D grid for converting between world and cell coordinates.
///
/// This type provides utilities for tile-based or grid-based game logic,
/// converting between continuous world coordinates and discrete cell coordinates.
///
/// Example:
/// ```swift
/// let grid = Grid2(cellSize: 1000)  // Each cell is 1.0 world units
/// let worldPos = IVec2(x: 2500, y: 3500)
/// let cell = grid.worldToCell(worldPos)  // IVec2(x: 2, y: 3)
/// ```
public struct Grid2: Sendable {
    /// The size of each cell in fixed-point units.
    public let cellSize: Int32
    
    /// Creates a new Grid2 with the given cell size.
    ///
    /// - Parameter cellSize: The size of each cell (must be positive).
    public init(cellSize: Int32) {
        self.cellSize = cellSize
    }
    
    /// Converts a world position to cell coordinates.
    ///
    /// - Parameter pos: The world position.
    /// - Returns: The cell coordinates (integer division, rounds toward zero).
    ///
    /// Example:
    /// ```swift
    /// let grid = Grid2(cellSize: 1000)
    /// let cell = grid.worldToCell(IVec2(x: 2500, y: 3500))  // IVec2(x: 2, y: 3)
    /// ```
    public func worldToCell(_ pos: IVec2) -> IVec2 {
        IVec2(fixedPointX: pos.x / cellSize, fixedPointY: pos.y / cellSize)
    }
    
    /// Converts cell coordinates to the world position of the cell's origin (bottom-left corner).
    ///
    /// - Parameter cell: The cell coordinates.
    /// - Returns: The world position of the cell's origin.
    ///
    /// Example:
    /// ```swift
    /// let grid = Grid2(cellSize: 1000)
    /// let world = grid.cellToWorld(IVec2(x: 2, y: 3))  // IVec2(x: 2000, y: 3000)
    /// ```
    public func cellToWorld(_ cell: IVec2) -> IVec2 {
        IVec2(fixedPointX: cell.x * cellSize, fixedPointY: cell.y * cellSize)
    }
    
    /// Snaps a world position to the nearest cell origin.
    ///
    /// - Parameter pos: The world position.
    /// - Returns: The snapped world position (cell origin).
    ///
    /// Example:
    /// ```swift
    /// let grid = Grid2(cellSize: 1000)
    /// let snapped = grid.snapToCell(IVec2(x: 2500, y: 3500))  // IVec2(x: 2000, y: 3000)
    /// ```
    public func snapToCell(_ pos: IVec2) -> IVec2 {
        let cell = worldToCell(pos)
        return cellToWorld(cell)
    }
}
