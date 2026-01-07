/**
 * Unit tests for view.ts DeterministicMath integration
 * 
 * Tests StateTreeView's decodeSnapshotValue and encodeSnapshotValue:
 * - Creating IVec2, Position2, Angle instances from fixed-point integers
 * - Encoding instances back to fixed-point integers
 * - Handling nested objects with DeterministicMath types
 * - Patch application for DeterministicMath types
 */

import { describe, it, expect, beforeEach } from 'vitest'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import type { StateSnapshot, StateUpdate } from '../types/transport'
import { NoOpLogger } from './logger'
import { IVec2, Position2, Angle } from './deterministic-math'
import type { ProtocolSchema } from '../codegen/schema'

// Minimal test schema for DeterministicMath types
const testSchema: ProtocolSchema = {
  version: '0.1.0',
  defs: {
    'TestState': {
      type: 'object',
      properties: {
        vec: { $ref: '#/defs/IVec2' },
        position: { $ref: '#/defs/Position2' },
        rotation: { $ref: '#/defs/Angle' },
        players: {
          type: 'object',
          additionalProperties: { $ref: '#/defs/PlayerState' }
        },
        player: { $ref: '#/defs/PlayerState' }
      }
    },
    'PlayerState': {
      type: 'object',
      properties: {
        position: { $ref: '#/defs/Position2' },
        rotation: { $ref: '#/defs/Angle' }
      }
    },
    'Position2': {
      type: 'object',
      properties: {
        v: { $ref: '#/defs/IVec2' }
      }
    },
    'IVec2': {
      type: 'object',
      properties: {
        x: { type: 'integer' },
        y: { type: 'integer' }
      }
    },
    'Angle': {
      type: 'object',
      properties: {
        degrees: { type: 'integer' }
      }
    }
  },
  lands: {
    'test-land': {
      stateType: 'TestState'
    },
    'test-schema-land-1': {
      stateType: 'TestState'
    },
    'test-schema-land-2': {
      stateType: 'TestState'
    },
    'test-schema-land-3': {
      stateType: 'TestState'
    }
  }
} as const

// Mock runtime for testing
class MockRuntime extends StateTreeRuntime {
  public sentMessages: any[] = []
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

  override sendRawMessage(message: any): void {
    this.sentMessages.push(message)
  }
}

describe('StateTreeView DeterministicMath Integration', () => {
  let runtime: MockRuntime
  let view: StateTreeView

  beforeEach(() => {
    runtime = new MockRuntime()
    view = runtime.createView('test-land', { schema: testSchema })
    runtime.sentMessages = []
    // Mark view as joined for encode tests
    ;(view as any).isJoined = true
  })

  describe('decodeSnapshotValue - IVec2', () => {
    it('creates IVec2 instance from fixed-point integers', () => {
      const snapshot: StateSnapshot = {
        values: {
          vec: { x: 64000, y: 36000 }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      expect(state.vec).toBeInstanceOf(IVec2)
      expect(state.vec.x).toBe(64.0)
      expect(state.vec.y).toBe(36.0)
      expect(state.vec.rawX).toBe(64000)
      expect(state.vec.rawY).toBe(36000)
    })
  })

  describe('decodeSnapshotValue - Position2', () => {
    it('creates Position2 instance from fixed-point integers', () => {
      const snapshot: StateSnapshot = {
        values: {
          position: {
            v: { x: 64000, y: 36000 }
          }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      expect(state.position).toBeInstanceOf(Position2)
      expect(state.position.v).toBeInstanceOf(IVec2)
      expect(state.position.v.x).toBe(64.0)
      expect(state.position.v.y).toBe(36.0)
    })

    it('handles nested Position2 in PlayerState', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: {
            'player-1': {
              position: {
                v: { x: 64000, y: 36000 }
              },
              rotation: {
                degrees: 45000
              }
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      const player = state.players['player-1']
      expect(player.position).toBeInstanceOf(Position2)
      expect(player.position.v).toBeInstanceOf(IVec2)
      expect(player.position.v.x).toBe(64.0)
      expect(player.position.v.y).toBe(36.0)
      expect(player.rotation).toBeInstanceOf(Angle)
      expect(player.rotation.degrees).toBe(45.0)
    })
  })

  describe('decodeSnapshotValue - Angle', () => {
    it('creates Angle instance from fixed-point integer degrees', () => {
      const snapshot: StateSnapshot = {
        values: {
          rotation: { degrees: 90000 }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      expect(state.rotation).toBeInstanceOf(Angle)
      expect(state.rotation.degrees).toBe(90.0)
      expect(state.rotation.rawDegrees).toBe(90000)
    })
  })

  describe('encodeSnapshotValue', () => {
    it('encodes IVec2 instance to fixed-point integers', () => {
      const snapshot: StateSnapshot = {
        values: {
          vec: { x: 64000, y: 36000 }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      // Use sendEvent to trigger encoding
      view.sendEvent('TestEvent', { vec: state.vec })
      
      const message = runtime.sentMessages[0]
      const eventPayload = (message.payload as any).fromClient.payload
      
      expect(eventPayload.vec).toEqual({ x: 64000, y: 36000 })
    })

    it('encodes Position2 instance to fixed-point integers', () => {
      const snapshot: StateSnapshot = {
        values: {
          position: {
            v: { x: 64000, y: 36000 }
          }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      view.sendEvent('TestEvent', { position: state.position })
      
      const message = runtime.sentMessages[0]
      const eventPayload = (message.payload as any).fromClient.payload
      
      expect(eventPayload.position).toEqual({ v: { x: 64000, y: 36000 } })
    })

    it('encodes Angle instance to fixed-point integer degrees', () => {
      const snapshot: StateSnapshot = {
        values: {
          rotation: { degrees: 45000 }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      view.sendEvent('TestEvent', { rotation: state.rotation })
      
      const message = runtime.sentMessages[0]
      const eventPayload = (message.payload as any).fromClient.payload
      
      expect(eventPayload.rotation).toEqual({ degrees: 45000 })
    })
  })

  describe('applyNestedPatch - DeterministicMath types', () => {
    it('handles patch to entire position.v (atomic update)', () => {
      const snapshot: StateSnapshot = {
        values: {
          player: {
            position: {
              v: { x: 64000, y: 36000 }
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player/position/v',
            op: 'replace',
            value: { x: 65000, y: 36000 }
          }
        ]
      }

      view.handleStateUpdate(update)
      const state = view.getState()
      
      expect(state.player.position).toBeInstanceOf(Position2)
      expect(state.player.position.v).toBeInstanceOf(IVec2)
      expect(state.player.position.v.x).toBe(65.0)
      expect(state.player.position.v.y).toBe(36.0)
    })

    it('handles patch to entire position.v with both coordinates updated', () => {
      const snapshot: StateSnapshot = {
        values: {
          player: {
            position: {
              v: { x: 64000, y: 36000 }
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player/position/v',
            op: 'replace',
            value: { x: 64000, y: 37000 }
          }
        ]
      }

      view.handleStateUpdate(update)
      const state = view.getState()
      
      expect(state.player.position.v.x).toBe(64.0)
      expect(state.player.position.v.y).toBe(37.0)
    })

    it('handles patch to entire position.v', () => {
      const snapshot: StateSnapshot = {
        values: {
          player: {
            position: {
              v: { x: 64000, y: 36000 }
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player/position/v',
            op: 'replace',
            value: { x: 100000, y: 50000 }
          }
        ]
      }

      view.handleStateUpdate(update)
      const state = view.getState()
      
      expect(state.player.position.v).toBeInstanceOf(IVec2)
      expect(state.player.position.v.x).toBe(100.0)
      expect(state.player.position.v.y).toBe(50.0)
    })
  })

  describe('Real-world scenario - PlayerState with Position2 and Angle', () => {
    it('handles complete PlayerState snapshot', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: {
            'player-1': {
              position: {
                v: { x: 64000, y: 36000 }
              },
              rotation: {
                degrees: 45000
              },
              targetPosition: null
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      const state = view.getState()
      
      const player = state.players['player-1']
      expect(player.position).toBeInstanceOf(Position2)
      expect(player.position.v).toBeInstanceOf(IVec2)
      expect(player.position.v.x).toBe(64.0)
      expect(player.position.v.y).toBe(36.0)
      expect(player.rotation).toBeInstanceOf(Angle)
      expect(player.rotation.degrees).toBe(45.0)
    })

    it('handles position update via patch (atomic update)', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: {
            'player-1': {
              position: {
                v: { x: 64000, y: 36000 }
              },
              rotation: {
                degrees: 0
              }
            }
          }
        }
      }

      view.handleSnapshot(snapshot)
      
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/players/player-1/position/v',
            op: 'replace',
            value: { x: 65000, y: 37000 }
          }
        ]
      }

      view.handleStateUpdate(update)
      const state = view.getState()
      
      const player = state.players['player-1']
      expect(player.position.v).toBeInstanceOf(IVec2)
      expect(player.position.v.x).toBe(65.0)
      expect(player.position.v.y).toBe(37.0)
    })
  })

  describe('Schema-based type checking', () => {
    it('uses schema to determine Position2 type correctly', () => {
      const schemaRuntime = new MockRuntime()
      const schema: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'TestState': {
            type: 'object',
            properties: {
              position: {
                $ref: '#/defs/Position2'
              }
            }
          },
          'Position2': {
            type: 'object',
            properties: {
              v: {
                $ref: '#/defs/IVec2'
              }
            }
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            }
          }
        },
        lands: {
          'test-schema-land-1': {
            stateType: 'TestState'
          },
          'test-schema-land-2': {
            stateType: 'TestState'
          },
          'test-schema-land-3': {
            stateType: 'TestState'
          }
        }
      }

      const schemaView = schemaRuntime.createView('test-schema-land-1', { schema })
      ;(schemaView as any).isJoined = true

      const snapshot: StateSnapshot = {
        values: {
          position: {
            v: { x: 64000, y: 36000 }
          }
        }
      }

      schemaView.handleSnapshot(snapshot)
      const state = schemaView.getState()
      
      expect(state.position).toBeInstanceOf(Position2)
      expect(state.position.v).toBeInstanceOf(IVec2)
      expect(state.position.v.x).toBe(64.0)
      expect(state.position.v.y).toBe(36.0)
    })

    it('uses schema to handle nested Position2 in map', () => {
      const schemaRuntime2 = new MockRuntime()
      const schema2: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'TestState': {
            type: 'object',
            properties: {
              players: {
                type: 'object',
                additionalProperties: {
                  $ref: '#/defs/PlayerState'
                }
              }
            }
          },
          'PlayerState': {
            type: 'object',
            properties: {
              position: {
                $ref: '#/defs/Position2'
              }
            }
          },
          'Position2': {
            type: 'object',
            properties: {
              v: {
                $ref: '#/defs/IVec2'
              }
            }
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            }
          }
        },
        lands: {
          'test-schema-land-2': {
            stateType: 'TestState'
          }
        }
      }

      const schemaView = schemaRuntime2.createView('test-schema-land-2', { schema: schema2 })
      ;(schemaView as any).isJoined = true

      const snapshot: StateSnapshot = {
        values: {
          players: {
            'player-1': {
              position: {
                v: { x: 64000, y: 36000 }
              }
            }
          }
        }
      }

      schemaView.handleSnapshot(snapshot)
      const state = schemaView.getState()
      
      const player = state.players['player-1']
      expect(player.position).toBeInstanceOf(Position2)
      expect(player.position.v).toBeInstanceOf(IVec2)
      expect(player.position.v.x).toBe(64.0)
      expect(player.position.v.y).toBe(36.0)
    })

    it('uses schema to handle patch correctly (atomic update)', () => {
      const schemaRuntime3 = new MockRuntime()
      const schema3: ProtocolSchema = {
        version: '0.1.0',
        defs: {
          'TestState': {
            type: 'object',
            properties: {
              player: {
                $ref: '#/defs/PlayerState'
              }
            }
          },
          'PlayerState': {
            type: 'object',
            properties: {
              position: {
                $ref: '#/defs/Position2'
              }
            }
          },
          'Position2': {
            type: 'object',
            properties: {
              v: {
                $ref: '#/defs/IVec2'
              }
            }
          },
          'IVec2': {
            type: 'object',
            properties: {
              x: { type: 'integer' },
              y: { type: 'integer' }
            }
          }
        },
        lands: {
          'test-schema-land-3': {
            stateType: 'TestState'
          }
        }
      }

      const schemaView = schemaRuntime3.createView('test-schema-land-3', { schema: schema3 })
      ;(schemaView as any).isJoined = true

      const snapshot: StateSnapshot = {
        values: {
          player: {
            position: {
              v: { x: 64000, y: 36000 }
            }
          }
        }
      }

      schemaView.handleSnapshot(snapshot)
      
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player/position/v',
            op: 'replace',
            value: { x: 65000, y: 36000 }
          }
        ]
      }

      schemaView.handleStateUpdate(update)
      const state = schemaView.getState()
      
      expect(state.player.position).toBeInstanceOf(Position2)
      expect(state.player.position.v).toBeInstanceOf(IVec2)
      expect(state.player.position.v.x).toBe(65.0)
      expect(state.player.position.v.y).toBe(36.0)
    })
  })
})
