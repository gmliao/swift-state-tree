// Examples/HummingbirdDemo/WebClient/src/test/deterministicMathAutoConvert.test.ts
//
// Tests for automatic conversion of DeterministicMath types in StateTreeView.

import { describe, it, expect } from 'vitest'
import { StateTreeRuntime } from '@swiftstatetree/sdk/core'
import { StateTreeView } from '@swiftstatetree/sdk/core'
import type { StateSnapshot, StateUpdate } from '@swiftstatetree/sdk/core'

describe('DeterministicMath Auto-Conversion', () => {
  it('automatically converts IVec2 from fixed-point to float in snapshot', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    // Simulate receiving a snapshot with IVec2 in fixed-point format
    const snapshot: StateSnapshot = {
      values: {
        directVector: { x: 1500, y: 2300 } // Fixed-point integers
      }
    }

    view.handleSnapshot(snapshot)
    const state = view.getState()

    // Should be automatically converted to float
    expect(state.directVector).toEqual({ x: 1.5, y: 2.3 })
  })

  it('automatically converts Position2 from fixed-point to float in snapshot', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    const snapshot: StateSnapshot = {
      values: {
        playerPositions: {
          player1: { v: { x: 1000, y: 2000 } } // Fixed-point integers
        }
      }
    }

    view.handleSnapshot(snapshot)
    const state = view.getState()

    // Should be automatically converted to float
    expect(state.playerPositions.player1).toEqual({ v: { x: 1.0, y: 2.0 } })
  })

  it('automatically converts IVec2 in state update patches', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    // First, set initial state
    const initialSnapshot: StateSnapshot = {
      values: {
        directVector: { x: 0, y: 0 }
      }
    }
    view.handleSnapshot(initialSnapshot)

    // Then apply a patch with IVec2
    const update: StateUpdate = {
      type: 'diff',
      patches: [
        {
          path: '/directVector',
          op: 'replace',
          value: { x: 1500, y: 2300 } // Fixed-point integers
        }
      ]
    }

    view.handleStateUpdate(update)
    const state = view.getState()

    // Should be automatically converted to float
    expect(state.directVector).toEqual({ x: 1.5, y: 2.3 })
  })

  it('automatically converts nested IVec2 in arrays', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    const snapshot: StateSnapshot = {
      values: {
        vectors: [
          { x: 1000, y: 2000 },
          { x: 1500, y: 2300 }
        ]
      }
    }

    view.handleSnapshot(snapshot)
    const state = view.getState()

    // Should be automatically converted to float
    expect(state.vectors).toEqual([
      { x: 1.0, y: 2.0 },
      { x: 1.5, y: 2.3 }
    ])
  })

  it('automatically converts Velocity2 and Acceleration2', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    const snapshot: StateSnapshot = {
      values: {
        playerVelocities: {
          player1: { v: { x: 100, y: 50 } }
        },
        playerAccelerations: {
          player1: { v: { x: 10, y: 5 } }
        }
      }
    }

    view.handleSnapshot(snapshot)
    const state = view.getState()

    // Should be automatically converted to float
    expect(state.playerVelocities.player1).toEqual({ v: { x: 0.1, y: 0.05 } })
    expect(state.playerAccelerations.player1).toEqual({ v: { x: 0.01, y: 0.005 } })
  })

  it('does not convert non-IVec2 objects with x and y', () => {
    const runtime = new StateTreeRuntime()
    const view = new StateTreeView(runtime, 'test-land')

    // Object with x, y but also other properties should not be converted
    const snapshot: StateSnapshot = {
      values: {
        customObject: { x: 100, y: 200, z: 300, other: 'value' }
      }
    }

    view.handleSnapshot(snapshot)
    const state = view.getState()

    // Should remain as-is (not converted, but z and other should be preserved)
    expect(state.customObject).toEqual({ x: 100, y: 200, z: 300, other: 'value' })
  })
})
