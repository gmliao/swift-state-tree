/**
 * Unit tests for view.ts
 * 
 * Tests StateTreeView functionality:
 * - State snapshot decoding
 * - Patch application
 * - Action/Event handling
 * - Join flow
 */

import { describe, it, expect, vi, beforeEach } from 'vitest'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import type { StateSnapshot, StateUpdate, StatePatch, TransportMessage } from '../types/transport'
import { NoOpLogger } from './logger'

// Mock runtime for testing
class MockRuntime extends StateTreeRuntime {
  public sentMessages: TransportMessage[] = []
  private _connected = true

  constructor() {
    super(new NoOpLogger())
  }

  override get connected(): boolean {
    return this._connected
  }

  set connected(value: boolean) {
    this._connected = value
  }

  override sendRawMessage(message: TransportMessage): void {
    this.sentMessages.push(message)
  }
}

describe('StateTreeView', () => {
  let runtime: MockRuntime
  let view: StateTreeView

  beforeEach(() => {
    runtime = new MockRuntime()
    view = runtime.createView('demo-game', {
      playerID: 'player-1',
      deviceID: 'device-1'
    })
    runtime.sentMessages = []
  })

  describe('constructor', () => {
    it('creates view with initial landID', () => {
      expect(view.landId).toBe('demo-game')
      expect(view.joined).toBe(false)
    })

    it('accepts optional parameters', () => {
      const customView = runtime.createView('test-land', {
        playerID: 'player-2',
        deviceID: 'device-2',
        metadata: { level: '10' }
      })
      expect(customView.landId).toBe('test-land')
    })
  })

  describe('join', () => {
    it('sends join message when connected', async () => {
      runtime.connected = true
      const joinPromise = view.join()

      // Wait a bit for promise to be set up
      await new Promise(resolve => setTimeout(resolve, 10))

      expect(runtime.sentMessages.length).toBe(1)
      const message = runtime.sentMessages[0]
      expect(message.kind).toBe('join')
      const join = (message.payload as any).join
      expect(join.landType).toBe('demo-game')
      expect(join.playerID).toBe('player-1')

      // Resolve the join promise
      view.handleTransportMessage({
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: join.requestID,
            success: true,
            playerID: 'player-1',
            landID: 'demo-game'
          }
        } as any
      })

      const result = await joinPromise
      expect(result.success).toBe(true)
      expect(view.joined).toBe(true)
    })

    it('throws error when not connected', async () => {
      runtime.connected = false
      await expect(view.join()).rejects.toThrow('Runtime not connected')
    })

    it('handles join response with updated landID', async () => {
      runtime.connected = true
      const joinPromise = view.join()

      await new Promise(resolve => setTimeout(resolve, 10))

      const message = runtime.sentMessages[0]
      const join = (message.payload as any).join

      // Server returns different landID (new room created)
      view.handleTransportMessage({
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: join.requestID,
            success: true,
            playerID: 'player-1',
            landID: 'demo-game:instance-123'
          }
        } as any
      })

      const result = await joinPromise
      expect(result.success).toBe(true)
      expect(result.landID).toBe('demo-game:instance-123')
      expect(view.landId).toBe('demo-game:instance-123')
    })
  })

  describe('sendAction', () => {
    beforeEach(async () => {
      // Set up view as joined
      runtime.connected = true
      const joinPromise = view.join()
      await new Promise(resolve => setTimeout(resolve, 10))
      
      const message = runtime.sentMessages[0]
      const join = (message.payload as any).join
      
      view.handleTransportMessage({
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: join.requestID,
            success: true,
            playerID: 'player-1',
            landID: 'demo-game'
          }
        } as any
      })
      
      await joinPromise
      runtime.sentMessages = []
    })

    it('sends action message when joined', async () => {
      const actionPromise = view.sendAction('BuyUpgrade', { upgradeID: 'cursor' })

      await new Promise(resolve => setTimeout(resolve, 10))

      expect(runtime.sentMessages.length).toBe(1)
      const message = runtime.sentMessages[0]
      expect(message.kind).toBe('action')
      const action = (message.payload as any).action
      expect(action.action.typeIdentifier).toBe('BuyUpgrade')
      expect(action.landID).toBe('demo-game')

      // Resolve the action
      view.handleTransportMessage({
        kind: 'actionResponse',
        payload: {
          actionResponse: {
            requestID: action.requestID,
            response: { success: true }
          }
        } as any
      })

      const result = await actionPromise
      expect(result.success).toBe(true)
    })

    it('throws error when not joined', async () => {
      const newView = runtime.createView('test-land')
      await expect(newView.sendAction('Test', {})).rejects.toThrow('Not joined to land')
    })

    it('handles action errors', async () => {
      const actionPromise = view.sendAction('BuyUpgrade', { upgradeID: 'cursor' })

      await new Promise(resolve => setTimeout(resolve, 10))

      const message = runtime.sentMessages[0]
      const action = (message.payload as any).action

      // Send error response
      view.handleTransportMessage({
        kind: 'actionResponse',
        payload: {
          actionResponse: {
            requestID: action.requestID,
            response: { error: { message: 'Insufficient cookies' } }
          }
        } as any
      })

      await expect(actionPromise).rejects.toThrow('Insufficient cookies')
    })
  })

  describe('handleSnapshot', () => {
    it('decodes snapshot and updates state', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: {
            'player-1': {
              name: 'Player 1',
              cookies: 100
            }
          },
          round: 5
        }
      }

      const onStateUpdate = vi.fn()
      const onSnapshot = vi.fn()
      const customView = runtime.createView('test-land', {
        onStateUpdate,
        onSnapshot
      })

      customView.handleSnapshot(snapshot)

      const state = customView.getState()
      expect(state.players['player-1'].name).toBe('Player 1')
      expect(state.players['player-1'].cookies).toBe(100)
      expect(state.round).toBe(5)

      expect(onSnapshot).toHaveBeenCalledWith(snapshot)
      expect(onStateUpdate).toHaveBeenCalled()
    })

    it('handles nested snapshot values', () => {
      const snapshot: StateSnapshot = {
        values: {
          nested: {
            deep: {
              value: 'test'
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      expect(state.nested.deep.value).toBe('test')
    })
  })

  describe('handleStateUpdate', () => {
    beforeEach(() => {
      // Set initial state
      view.handleSnapshot({
        values: {
          round: 0,
          players: {}
        }
      })
    })

    it('applies patches to update state', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/round',
            op: 'replace',
            value: 10
          }
        ]
      }

      const onStateUpdate = vi.fn()
      const customView = runtime.createView('test-land', { onStateUpdate })
      customView.handleSnapshot({
        values: {
          round: 0
        }
      })

      customView.handleStateUpdate(update)

      const state = customView.getState()
      expect(state.round).toBe(10)
      expect(onStateUpdate).toHaveBeenCalled()
    })

    it('applies nested patches', () => {
      view.handleSnapshot({
        values: {
          players: {
            'player-1': {
              name: 'Player 1',
              cookies: 0
            }
          }
        }
      })

      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/players/player-1/cookies',
            op: 'replace',
            value: 100
          }
        ]
      }

      view.handleStateUpdate(update)

      const state = view.getState()
      expect(state.players['player-1'].cookies).toBe(100)
    })

    it('handles remove operation', () => {
      view.handleSnapshot({
        values: {
          players: {
            'player-1': {
              name: 'Player 1'
            }
          }
        }
      })

      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/players/player-1',
            op: 'remove'
          }
        ]
      }

      view.handleStateUpdate(update)

      const state = view.getState()
      expect(state.players['player-1']).toBeUndefined()
    })

    it('ignores noChange updates', () => {
      const onStateUpdate = vi.fn()
      const customView = runtime.createView('test-land', { onStateUpdate })

      const update: StateUpdate = {
        type: 'noChange',
        patches: []
      }

      customView.handleStateUpdate(update)
      expect(onStateUpdate).not.toHaveBeenCalled()
    })
  })

  describe('onServerEvent', () => {
    beforeEach(async () => {
      // Set up view as joined
      runtime.connected = true
      const joinPromise = view.join()
      await new Promise(resolve => setTimeout(resolve, 10))
      
      const message = runtime.sentMessages[0]
      const join = (message.payload as any).join
      
      view.handleTransportMessage({
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: join.requestID,
            success: true,
            playerID: 'player-1',
            landID: 'demo-game'
          }
        } as any
      })
      
      await joinPromise
    })

    it('subscribes to server events', () => {
      const handler = vi.fn()
      const unsubscribe = view.onServerEvent('TestEvent', handler)

      // payloadObj.event || payloadObj, then check payload.event?.fromServer
      // So we need: payload = { event: { fromServer: { event: { ... } } } }
      view.handleTransportMessage({
        kind: 'event',
        payload: {
          event: {
            event: {
              fromServer: {
                event: {
                  type: 'TestEvent',
                  payload: { data: 'test' }
                }
              }
            }
          }
        } as any
      })

      expect(handler).toHaveBeenCalledWith({ data: 'test' })
      
      // Test unsubscribe
      unsubscribe()
      view.handleTransportMessage({
        kind: 'event',
        payload: {
          event: {
            event: {
              fromServer: {
                event: {
                  type: 'TestEvent',
                  payload: { data: 'test2' }
                }
              }
            }
          }
        } as any
      })

      expect(handler).toHaveBeenCalledTimes(1) // Should not be called again
    })
  })

  describe('destroy', () => {
    it('cleans up callbacks and state', () => {
      view.destroy()
      
      expect(view.joined).toBe(false)
      const state = view.getState()
      expect(Object.keys(state).length).toBe(0)
    })
  })
})

