import { describe, it, expect, vi, beforeEach } from 'vitest'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import type { StatePatch, StateSnapshot, StateUpdate } from '../types/transport'

describe('StateTreeView.createMapSubscriptions', () => {
  let runtime: StateTreeRuntime
  let view: StateTreeView
  let mockLogger: any

  beforeEach(() => {
    mockLogger = {
      debug: vi.fn(),
      info: vi.fn(),
      warn: vi.fn(),
      error: vi.fn(),
    }
    
    runtime = new StateTreeRuntime()
    view = runtime.createView('test-land', {
      logger: mockLogger,
      schema: {
        version: '1.0.0',
        lands: {
          'test-land': {
            stateType: 'TestState'
          }
        },
        defs: {
          TestState: {
            type: 'object',
            properties: {
              players: {
                type: 'object',
                additionalProperties: { $ref: '#/defs/Player' }
              }
            }
          },
          Player: {
            type: 'object',
            properties: {
              name: { type: 'string' }
            }
          }
        }
      }
    })
  })

  it('should trigger onAdd for existing items when subscribing', () => {
    // Setup: Simulate state with existing players
    view['currentState'] = {
      players: {
        'player-1': { name: 'Alice', position: { x: 0, y: 0 } },
        'player-2': { name: 'Bob', position: { x: 10, y: 10 } },
      }
    }

    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const addCallback = vi.fn()
    subscriptions.onAdd(addCallback)

    // Should have been called for existing players
    expect(addCallback).toHaveBeenCalledTimes(2)
    expect(addCallback).toHaveBeenCalledWith('player-1', { name: 'Alice', position: { x: 0, y: 0 } })
    expect(addCallback).toHaveBeenCalledWith('player-2', { name: 'Bob', position: { x: 10, y: 10 } })
  })

  it('should trigger onAdd for new items via patch after state is fully synced', () => {
    // Setup: Initialize with existing players
    view['currentState'] = {
      players: {
        'player-1': { name: 'Alice' }
      }
    }

    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const addCallback = vi.fn()
    subscriptions.onAdd(addCallback)

    // Clear calls from initial subscription
    addCallback.mockClear()

    // Apply state update with patch (this will apply patches and then trigger callbacks)
    const patch: StatePatch = {
      path: '/players/player-3',
      op: 'add',
      value: { name: 'Charlie' }
    }
    
    view['handleStateUpdate']({
      type: 'diff',
      patches: [patch]
    })

    // Should trigger after all patches are applied and state is fully synced
    expect(addCallback).toHaveBeenCalledWith('player-3', { name: 'Charlie' })
  })

  it('should trigger onRemove for removed items after state is fully synced', () => {
    // Setup: Add player first
    view['currentState'] = {
      players: {
        'player-1': { name: 'Alice' }
      }
    }

    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const removeCallback = vi.fn()
    subscriptions.onRemove(removeCallback)

    // Apply state update with remove patch (this will apply patches and then trigger callbacks)
    const patch: StatePatch = {
      path: '/players/player-1',
      op: 'remove'
    }
    
    view['handleStateUpdate']({
      type: 'diff',
      patches: [patch]
    })

    // Should trigger after all patches are applied and state is fully synced
    expect(removeCallback).toHaveBeenCalledWith('player-1')
  })

  it('should handle snapshot arriving after subscription (late join)', () => {
    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const addCallback = vi.fn()
    subscriptions.onAdd(addCallback)

    // Initially no players
    expect(addCallback).not.toHaveBeenCalled()

    // Snapshot arrives with players (simulating late join)
    const snapshot: StateSnapshot = {
      values: {
        players: {
          'player-1': { name: 'Alice' },
          'player-2': { name: 'Bob' },
        }
      }
    }
    
    view['handleSnapshot'](snapshot)

    // Should trigger callbacks for players in snapshot
    expect(addCallback).toHaveBeenCalledTimes(2)
    expect(addCallback).toHaveBeenCalledWith('player-1', { name: 'Alice' })
    expect(addCallback).toHaveBeenCalledWith('player-2', { name: 'Bob' })
  })

  it('should prevent duplicate triggers for the same key', () => {
    view['currentState'] = {
      players: {
        'player-1': { name: 'Alice' }
      }
    }

    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const addCallback = vi.fn()
    subscriptions.onAdd(addCallback)

    // Clear calls from initial subscription
    addCallback.mockClear()

    // Trigger state sync again (should not duplicate)
    view['handleSnapshot']({
      values: {
        players: {
          'player-1': { name: 'Alice' }
        }
      }
    })

    // Should not trigger again for same key
    expect(addCallback).not.toHaveBeenCalled()
  })

  it('should support multiple subscriptions', () => {
    view['currentState'] = {
      players: {
        'player-1': { name: 'Alice' }
      }
    }

    const subscriptions = view.createMapSubscriptions<{ name: string }>(
      '/players',
      (state) => state?.players
    )

    const callback1 = vi.fn()
    const callback2 = vi.fn()
    
    const unsub1 = subscriptions.onAdd(callback1)
    const unsub2 = subscriptions.onAdd(callback2)

    // Both should be called for existing items
    expect(callback1).toHaveBeenCalledWith('player-1', { name: 'Alice' })
    expect(callback2).toHaveBeenCalledWith('player-1', { name: 'Alice' })

    // Unsubscribe one
    unsub1()
    
    // Add new player via state update
    const patch: StatePatch = {
      path: '/players/player-2',
      op: 'add',
      value: { name: 'Bob' }
    }
    
    callback1.mockClear()
    callback2.mockClear()
    
    // Apply patch and trigger state sync
    view['handleStateUpdate']({
      type: 'diff',
      patches: [patch]
    })

    // Only callback2 should be called (callback1 unsubscribed)
    expect(callback1).not.toHaveBeenCalled()
    expect(callback2).toHaveBeenCalledWith('player-2', { name: 'Bob' })
  })
})
