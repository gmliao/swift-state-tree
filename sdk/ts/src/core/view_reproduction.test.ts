
import { describe, it, expect, vi, beforeEach } from 'vitest'
import { StateTreeView } from './view'
import { StateTreeRuntime } from './runtime'
import type { StateSnapshot, StateUpdate, StatePatch, TransportMessage } from '../types/transport'
import { NoOpLogger } from './logger'
import type { ProtocolSchema } from '../codegen/schema'

// Mock runtime
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

const testSchema: ProtocolSchema = {
  version: '0.1.0',
  schemaHash: 'test-hash',
  defs: {
    'Game': {
      type: 'object',
      properties: {
        monsters: {
          type: 'object', // Map<String, Monster>
          additionalProperties: {
            type: 'object',
            properties: {
              hp: { type: 'integer' }
            }
          }
        }
      }
    }
  },
  lands: {
    'game': { stateType: 'Game' }
  }
} as const

describe('View Reproduction Tests', () => {
  let runtime: MockRuntime
  let view: StateTreeView

  beforeEach(() => {
    runtime = new MockRuntime()
    view = runtime.createView('game', {
      schema: testSchema,
      playerID: 'p1',
      deviceID: 'd1'
    })
  })

  it('removes item from Map (nested object) via string path', () => {
    // Initial State
    view.handleSnapshot({
      values: {
        monsters: {
          'm1': { hp: 100 },
          'm2': { hp: 50 }
        }
      }
    })
    
    let state = view.getState()
    expect(state.monsters['m1']).toBeDefined()
    expect(state.monsters['m2']).toBeDefined()

    // Apply patch to remove m1
    // Server sends: path: /monsters/m1, op: remove
    const update: StateUpdate = {
      type: 'diff',
      patches: [
        {
          path: '/monsters/m1',
          op: 'remove'
        }
      ]
    }
    
    view.handleStateUpdate(update)
    
    state = view.getState()
    expect(state.monsters['m1']).toBeUndefined()
    expect(state.monsters['m2']).toBeDefined()
    
    // Check keys
    const keys = Object.keys(state.monsters)
    expect(keys).toContain('m2')
    expect(keys).not.toContain('m1')
  })
})
