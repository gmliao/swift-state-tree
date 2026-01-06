// Tests/SwiftStateTreeDeterministicMathTests/Grid2Tests.swift
//
// Tests for Grid2 coordinate conversion.

import Foundation
import Testing
@testable import SwiftStateTreeDeterministicMath

@Test("Grid2 worldToCell converts correctly")
func testGrid2WorldToCell() {
    let grid = Grid2(cellSize: 1000)
    let world = IVec2(x: 2.5, y: 3.5)
    let cell = grid.worldToCell(world)
    
    #expect(cell.x == 2)  // 2.5 / 1.0 = 2
    #expect(cell.y == 3)  // 3.5 / 1.0 = 3
}

@Test("Grid2 cellToWorld converts correctly")
func testGrid2CellToWorld() {
    let grid = Grid2(cellSize: 1000)
    // Use internal initializer for cell coordinates (they're already in fixed-point)
    let cell = IVec2(fixedPointX: 2, fixedPointY: 3)
    let world = grid.cellToWorld(cell)
    
    #expect(world.x == 2000)  // 2 * 1000 = 2000
    #expect(world.y == 3000)  // 3 * 1000 = 3000
}

@Test("Grid2 snapToCell works correctly")
func testGrid2SnapToCell() {
    let grid = Grid2(cellSize: 1000)
    let world = IVec2(x: 2.5, y: 3.5)
    let snapped = grid.snapToCell(world)
    
    #expect(snapped.x == 2000)  // Snapped to cell (2, 3) -> (2.0, 3.0) -> (2000, 3000)
    #expect(snapped.y == 3000)
}
