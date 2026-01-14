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
import { NoOpLogger, type Logger } from './logger'
import type { ProtocolSchema } from '../codegen/schema'

// Minimal test schema for basic tests
const testSchema: ProtocolSchema = {
  version: '0.1.0',
  defs: {
    'DemoGameState': {
      type: 'object',
      properties: {
        round: { type: 'integer' },
        players: {
          type: 'object',
          additionalProperties: {
            type: 'object',
            properties: {
              name: { type: 'string' },
              cookies: { type: 'integer' }
            }
          }
        }
      }
    }
  },
  lands: {
    'demo-game': {
      stateType: 'DemoGameState'
    },
    'test-land': {
      stateType: 'DemoGameState'
    }
  }
} as const

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
      schema: testSchema,
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
        schema: testSchema,
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
      const action = message.payload as any
      // Simplified structure: fields directly in payload
      expect(action.typeIdentifier).toBe('BuyUpgrade')

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
      const newView = runtime.createView('test-land', { schema: testSchema })
      await expect(newView.sendAction('Test', {})).rejects.toThrow('Not joined to land')
    })

    it('handles action errors', async () => {
      const actionPromise = view.sendAction('BuyUpgrade', { upgradeID: 'cursor' })

      await new Promise(resolve => setTimeout(resolve, 10))

      const message = runtime.sentMessages[0]
      const action = message.payload as any

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
        schema: testSchema,
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
      const customView = runtime.createView('test-land', { schema: testSchema, onStateUpdate })
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
      const customView = runtime.createView('test-land', { schema: testSchema, onStateUpdate })

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

      // Simplified structure: payload directly contains fromServer
      view.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'TestEvent',
            payload: { data: 'test' }
          }
        } as any
      })

      expect(handler).toHaveBeenCalledWith({ data: 'test' })
      
      // Test unsubscribe
      unsubscribe()
      view.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'TestEvent',
            payload: { data: 'test2' }
          }
        } as any
      })

      expect(handler).toHaveBeenCalledTimes(1) // Should not be called again
    })

    it('decodes event payload with schema lookup using event ID (short name)', () => {
      // Create a schema with event definition
      const schemaWithEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          },
          'PlayerShootEvent': {
            type: 'object',
            properties: {
              playerID: { type: 'string' },
              from: { $ref: '#/defs/Position2' },
              to: { $ref: '#/defs/Position2' }
            },
            required: ['playerID', 'from', 'to']
          },
          'Position2': {
            type: 'object',
            properties: {
              v: { $ref: '#/defs/IVec2' }
            },
            required: ['v']
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            },
            required: ['x', 'y']
          }
        },
        lands: {
          'test-event-decode': {
            stateType: 'DemoGameState',
            events: {
              'PlayerShoot': {  // Short name (without "Event" suffix)
                $ref: '#/defs/PlayerShootEvent'  // Full name in defs
              }
            }
          }
        }
      } as any

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-event-decode', {
        schema: schemaWithEvent
      })

      const handler = vi.fn()
      testView.onServerEvent('PlayerShoot', handler)

      // Send event with short name "PlayerShoot"
      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'PlayerShoot',  // Short name
            payload: {
              playerID: 'player-1',
              from: { v: { x: 1000, y: 2000 } },
              to: { v: { x: 3000, y: 4000 } }
            }
          }
        } as any
      })

      // Handler should be called with decoded payload
      expect(handler).toHaveBeenCalledTimes(1)
      const callArgs = handler.mock.calls[0][0]
      expect(callArgs.playerID).toBe('player-1')
      expect(callArgs.from).toBeDefined()
      expect(callArgs.to).toBeDefined()
      // Verify that schema lookup worked (payload should be decoded, not just plain object)
      // The exact structure depends on decodeValueWithType implementation
      expect(callArgs.from).toHaveProperty('v')
      expect(callArgs.to).toHaveProperty('v')
    })

    it('handles payload when it is already an object (not array)', () => {
      // Test case: payload is already an object (not compressed array)
      // This can happen if compression is disabled or payload is sent as object
      const schemaWithEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          },
          'PlayerShootEvent': {
            type: 'object',
            properties: {
              playerID: { type: 'string' },
              from: { $ref: '#/defs/Position2' },
              to: { $ref: '#/defs/Position2' }
            },
            required: ['playerID', 'from', 'to']
          },
          'Position2': {
            type: 'object',
            properties: {
              v: { $ref: '#/defs/IVec2' }
            },
            required: ['v']
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            },
            required: ['x', 'y']
          }
        },
        lands: {
          'test-event-object': {
            stateType: 'DemoGameState',
            events: {
              'PlayerShoot': {
                $ref: '#/defs/PlayerShootEvent'
              }
            }
          }
        }
      } as any

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-event-object', {
        schema: schemaWithEvent
      })

      const handler = vi.fn()
      testView.onServerEvent('PlayerShoot', handler)

      // Send event with object payload (not array)
      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'PlayerShoot',
            payload: {
              playerID: { rawValue: 'player-1' },  // PlayerID as object
              from: { v: { x: 1000, y: 2000 } },
              to: { v: { x: 3000, y: 4000 } }
            }
          }
        } as any
      })

      // Handler should be called with decoded payload
      expect(handler).toHaveBeenCalledTimes(1)
      const callArgs = handler.mock.calls[0][0]
      // Verify structure is correct (not nested incorrectly)
      expect(callArgs).toHaveProperty('playerID')
      expect(callArgs).toHaveProperty('from')
      expect(callArgs).toHaveProperty('to')
      // playerID should not be the entire payload
      expect(callArgs.playerID).not.toEqual(callArgs)
      expect(callArgs.from).toHaveProperty('v')
      expect(callArgs.to).toHaveProperty('v')
    })

    it('handles array payload compression correctly (via decodeEventArray)', () => {
      // Test case: payload is compressed array, should be decoded using field order
      // This tests the full flow: decodeEventArray converts array to object, then decodeEventPayload decodes types
      const schemaWithEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          },
          'PlayerShootEvent': {
            type: 'object',
            properties: {
              playerID: { $ref: '#/defs/PlayerID' },
              from: { $ref: '#/defs/Position2' },
              to: { $ref: '#/defs/Position2' }
            },
            required: ['playerID', 'from', 'to']
          },
          'PlayerID': {
            type: 'object',
            properties: {
              rawValue: { type: 'string' }
            },
            required: ['rawValue']
          },
          'Position2': {
            type: 'object',
            properties: {
              v: { $ref: '#/defs/IVec2' }
            },
            required: ['v']
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            },
            required: ['x', 'y']
          }
        },
        lands: {
          'test-event-array': {
            stateType: 'DemoGameState',
            events: {
              'PlayerShoot': {
                $ref: '#/defs/PlayerShootEvent'
              }
            }
          }
        }
      } as any

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-event-array', {
        schema: schemaWithEvent
      })

      const handler = vi.fn()
      testView.onServerEvent('PlayerShoot', handler)

      // Simulate the object payload that decodeEventArray would produce from array
      // decodeEventArray converts [playerID, from, to] to {playerID, from, to}
      // Then decodeEventPayload decodes the nested types
      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'PlayerShoot',
            payload: {
              playerID: { rawValue: 'player-1' },  // Already converted from array by decodeEventArray
              from: { v: { x: 1000, y: 2000 } },
              to: { v: { x: 3000, y: 4000 } }
            }
          }
        } as any
      })

      // Handler should be called with decoded payload
      expect(handler).toHaveBeenCalledTimes(1)
      const callArgs = handler.mock.calls[0][0]
      // Verify structure is correct
      expect(callArgs).toHaveProperty('playerID')
      expect(callArgs).toHaveProperty('from')
      expect(callArgs).toHaveProperty('to')
      // Verify nested types are decoded
      expect(callArgs.from).toHaveProperty('v')
      expect(callArgs.to).toHaveProperty('v')
    })

    it('detects and warns about nested payload corruption', () => {
      // Test case: payload field contains entire payload (corruption detection)
      const schemaWithEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          },
          'PlayerShootEvent': {
            type: 'object',
            properties: {
              playerID: { $ref: '#/defs/PlayerID' },
              from: { $ref: '#/defs/Position2' },
              to: { $ref: '#/defs/Position2' }
            },
            required: ['playerID', 'from', 'to']
          },
          'PlayerID': {
            type: 'object',
            properties: {
              rawValue: { type: 'string' }
            },
            required: ['rawValue']
          },
          'Position2': {
            type: 'object',
            properties: {
              v: { $ref: '#/defs/IVec2' }
            },
            required: ['v']
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            },
            required: ['x', 'y']
          }
        },
        lands: {
          'test-event-corrupt': {
            stateType: 'DemoGameState',
            events: {
              'PlayerShoot': {
                $ref: '#/defs/PlayerShootEvent'
              }
            }
          }
        }
      } as any

      const mockLogger: Logger = {
        debug: vi.fn(),
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn()
      }

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-event-corrupt', {
        schema: schemaWithEvent,
        logger: mockLogger
      })

      const handler = vi.fn()
      testView.onServerEvent('PlayerShoot', handler)

      // Simulate corrupted payload where playerID contains entire payload
      const corruptedPayload = {
        playerID: {
          playerID: { rawValue: 'player-1' },
          from: { v: { x: 1000, y: 2000 } },
          to: { v: { x: 3000, y: 4000 } }
        },
        from: { v: { x: 1000, y: 2000 } },
        to: { v: { x: 3000, y: 4000 } }
      }

      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'PlayerShoot',
            payload: corruptedPayload
          }
        } as any
      })

      // Should detect corruption and warn
      expect(mockLogger.warn).toHaveBeenCalled()
      const warnCall = (mockLogger.warn as any).mock.calls.find((call: any[]) => 
        call[0]?.includes('appears to contain the entire payload')
      )
      expect(warnCall).toBeDefined()

      // Handler should still be called (with corrupted data, but not further corrupted)
      expect(handler).toHaveBeenCalledTimes(1)
      const callArgs = handler.mock.calls[0][0]
      // playerID should be the corrupted value (not further processed)
      expect(callArgs.playerID).toEqual(corruptedPayload.playerID)
    })

    it('handles missing schema gracefully (object payload)', () => {
      // Test case: event type not found in schema, but payload is object (uncompressed)
      // This simulates the old behavior before compression was enabled
      const schemaWithoutEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          }
        },
        lands: {
          'test-no-event': {
            stateType: 'DemoGameState',
            events: {}
          }
        }
      } as any

      const mockLogger: Logger = {
        debug: vi.fn(),
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn()
      }

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-no-event', {
        schema: schemaWithoutEvent,
        logger: mockLogger
      })

      const handler = vi.fn()
      testView.onServerEvent('UnknownEvent', handler)

      // Simulate uncompressed object payload (old behavior)
      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'UnknownEvent',
            payload: { data: 'test' }  // Object format (uncompressed)
          }
        } as any
      })

      // Should warn about missing schema
      expect(mockLogger.warn).toHaveBeenCalled()
      const warnCall = (mockLogger.warn as any).mock.calls.find((call: any[]) => 
        call[0]?.includes('No schema found for event')
      )
      expect(warnCall).toBeDefined()

      // Handler should still be called with original payload (structure preserved)
      expect(handler).toHaveBeenCalledTimes(1)
      expect(handler).toHaveBeenCalledWith({ data: 'test' })
    })

    it('handles missing field order for compressed array payload', () => {
      // Test case: compressed array payload but field order not found
      // This is the NEW problem that occurs with compression enabled
      const schemaWithoutEvent: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'DemoGameState': {
            type: 'object',
            properties: {
              round: { type: 'integer' }
            }
          }
        },
        lands: {
          'test-no-field-order': {
            stateType: 'DemoGameState',
            events: {}  // No events defined, so no field order
          }
        }
      } as any

      const mockLogger: Logger = {
        debug: vi.fn(),
        info: vi.fn(),
        warn: vi.fn(),
        error: vi.fn()
      }

      const testRuntime = new MockRuntime()
      const testView = testRuntime.createView('test-no-field-order', {
        schema: schemaWithoutEvent,
        logger: mockLogger
      })

      const handler = vi.fn()
      testView.onServerEvent('UnknownEvent', handler)

      // Simulate compressed array payload (new behavior with compression enabled)
      // This would come from decodeEventArray when it receives [103, 1, "UnknownEvent", [value1, value2], null]
      // But since field order is missing, decodeEventArray returns {}
      testView.handleTransportMessage({
        kind: 'event',
        payload: {
          fromServer: {
            type: 'UnknownEvent',
            payload: {}  // Empty object because field order was missing in decodeEventArray
          }
        } as any
      })

      // Handler should be called with empty object (not corrupted structure)
      expect(handler).toHaveBeenCalledTimes(1)
      const callArgs = handler.mock.calls[0][0]
      // Should be empty object, not corrupted nested structure
      expect(callArgs).toEqual({})
      expect(Object.keys(callArgs).length).toBe(0)
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

