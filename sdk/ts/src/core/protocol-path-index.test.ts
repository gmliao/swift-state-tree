/**
 * The path index (`stateUpdateFeatures: ["pathIndex"]`): a patch entry's path id is the
 * pattern's rank among the joined land's sorted schema path hashes, not the hash. The client
 * declares the feature in its join metadata, and decodes indices with its own land's table once
 * `joinResponse` echoes the feature. The table is per connection (a session is bound to one
 * land), never shared between connections.
 */

import { describe, it, expect } from 'vitest'
import {
  decodeMessage,
  encodeMessageArray,
  pathIndexTableFor,
  SUPPORTED_STATE_UPDATE_FEATURES
} from './protocol'
import { StateTreeRuntime } from './runtime'
import { NoOpLogger } from './logger'
import type { ProtocolSchema } from '../codegen/schema'
import type { StateUpdate, TransportEncodingConfig, TransportMessage } from '../types/transport'

// Rank 1 is `round` in land A and `names.*` in land B.
const landA = { 'players.*.hp': 900, round: 40, players: 7, 'players.*': 40000 }
const landB = { names: 2, 'names.*': 41, flags: 50 }

const schema: ProtocolSchema = {
  version: '0.1.0',
  defs: {
    A: {
      type: 'object',
      properties: {
        round: { type: 'integer' },
        players: { type: 'object', additionalProperties: { type: 'object', properties: { hp: { type: 'integer' } } } }
      }
    },
    B: {
      type: 'object',
      properties: {
        names: { type: 'object', additionalProperties: { type: 'string' } },
        flags: { type: 'integer' }
      }
    }
  },
  lands: { 'land-a': { stateType: 'A', pathHashes: landA }, 'land-b': { stateType: 'B', pathHashes: landB } }
} as any

function config(table?: readonly number[], features: string[] = ['pathIndex']): TransportEncodingConfig {
  return { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: features, pathIndexTable: table }
}

describe('Path index', () => {
  it('the rank table is the land\'s path hashes, de-duplicated and sorted ascending', () => {
    expect(pathIndexTableFor(landA)).toEqual([7, 40, 900, 40000])
    expect(pathIndexTableFor(landB)).toEqual([2, 41, 50])
    expect(pathIndexTableFor({ a: 5, b: 3, c: 5 })).toEqual([3, 5])
  })

  it('decodes indices with the feature and the land\'s table, and hashes without the feature', () => {
    const table = pathIndexTableFor(landA)
    // Reverse lookup (hash -> pattern) for land A.
    const viewRuntime = new StateTreeRuntime(new NoOpLogger())
    viewRuntime.createView('land-a', { schema })
    const indexed = decodeMessage('[2,[1,null,1,5],[2,[0,"a"],1,9]]', config(table), new Map()) as StateUpdate
    expect(indexed.patches).toEqual([
      { path: '/round', op: 'replace', value: 5 },
      { path: '/players/a/hp', op: 'replace', value: 9 }
    ])
    const hashed = decodeMessage('[2,[40,null,1,5]]', config(table, []), new Map()) as StateUpdate
    expect(hashed.patches).toEqual([{ path: '/round', op: 'replace', value: 5 }])
  })

  it('an index out of range is a decode error, and the feature without a table is one too', () => {
    expect(() => decodeMessage('[2,[4,null,1,5]]', config(pathIndexTableFor(landA)), new Map())).toThrow(/^Unknown path index: 4\./)
    expect(() => decodeMessage('[2,[1,null,1,5]]', config(undefined), new Map())).toThrow(/no path index table/)
  })

  it('joinResponse carries stateUpdateFeatures in the array form', () => {
    const message: TransportMessage = {
      kind: 'joinResponse',
      payload: { joinResponse: { requestID: 'r', success: true, encoding: 'messagepack', stateUpdateFeatures: ['pathIndex'] } }
    } as any
    const array = JSON.parse(encodeMessageArray(message)) as any[]
    expect(array.length).toBe(9)
    expect(array[8]).toEqual(['pathIndex'])
    const decoded = decodeMessage(JSON.stringify(array)) as TransportMessage
    expect((decoded.payload as any).joinResponse.stateUpdateFeatures).toEqual(['pathIndex'])
  })
})

class MockRuntime extends StateTreeRuntime {
  public sent: TransportMessage[] = []
  constructor() {
    super(new NoOpLogger())
  }
  override get connected(): boolean {
    return true
  }
  override sendRawMessage(message: TransportMessage): void {
    this.sent.push(message)
  }
  get encodingConfig(): TransportEncodingConfig {
    return (this as any).transportEncoding
  }
}

async function joinedRuntime(landType: string, echoed?: string[]): Promise<MockRuntime> {
  const runtime = new MockRuntime()
  const view = runtime.createView(landType, { schema, playerID: 'p1' })
  const joined = view.join()
  await new Promise(resolve => setTimeout(resolve, 10))
  const join = (runtime.sent[0].payload as any).join
  expect(join.metadata.stateUpdateFeatures).toEqual(SUPPORTED_STATE_UPDATE_FEATURES)
  view.handleTransportMessage({
    kind: 'joinResponse',
    payload: { joinResponse: { requestID: join.requestID, success: true, playerID: 'p1', landID: landType, stateUpdateFeatures: echoed } }
  } as any)
  expect((await joined).success).toBe(true)
  return runtime
}

describe('Path index handshake', () => {
  it('a frame before the joinResponse (no table yet) fails loudly instead of decoding', async () => {
    const runtime = new MockRuntime()
    runtime.createView('land-a', { schema, playerID: 'p1' })
    // Rank 1 read as a hash before the table is set: no such hash.
    expect(() => decodeMessage('[2,[1,null,1,5]]', runtime.encodingConfig, new Map())).toThrow(/^Unknown pathHash: 1\./)
    // The feature without a table (a schema land with no pathHashes) fails too.
    runtime.updateStateUpdateFeatures(['pathIndex'])
    expect(() => decodeMessage('[2,[1,null,1,5]]', runtime.encodingConfig, new Map())).toThrow(/no path index table/)
  })

  it('a join declares the features this SDK decodes; joinResponse sets the ones in use and the land\'s table', async () => {
    expect(SUPPORTED_STATE_UPDATE_FEATURES).toContain('pathIndex')
    const on = await joinedRuntime('land-a', ['pathIndex'])
    expect(on.encodingConfig.stateUpdateFeatures).toEqual(['pathIndex'])
    expect(on.encodingConfig.pathIndexTable).toEqual([7, 40, 900, 40000])
    const off = await joinedRuntime('land-a', undefined)
    expect(off.encodingConfig.stateUpdateFeatures).toEqual([])
  })

  it('two connections to two lands in one process: the same rank decodes to each land\'s own pattern', async () => {
    const a = await joinedRuntime('land-a', ['pathIndex'])
    const b = await joinedRuntime('land-b', ['pathIndex'])
    expect(a.encodingConfig.pathIndexTable).not.toEqual(b.encodingConfig.pathIndexTable)
    // Rank 1: `round` in land A, `names.*` in land B. Land B's view was created last; land A's
    // connection still decodes with its own table and patterns.
    const fromA = decodeMessage('[2,[1,null,1,5]]', a.encodingConfig, new Map()) as StateUpdate
    const fromB = decodeMessage('[2,[1,"k",1,"v"]]', b.encodingConfig, new Map()) as StateUpdate
    expect(fromA.patches).toEqual([{ path: '/round', op: 'replace', value: 5 }])
    expect(fromB.patches).toEqual([{ path: '/names/k', op: 'replace', value: 'v' }])
    // Hashes too (path index off): each connection resolves its own land's patterns.
    const hashedA = decodeMessage('[2,[40,null,1,5]]', { ...a.encodingConfig, stateUpdateFeatures: [] }, new Map()) as StateUpdate
    expect(hashedA.patches).toEqual([{ path: '/round', op: 'replace', value: 5 }])
  })
})
