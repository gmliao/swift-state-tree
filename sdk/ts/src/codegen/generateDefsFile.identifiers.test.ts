import { describe, expect, it } from 'vitest'
import { generateDefsTs } from './generateDefsFile'
import type { ProtocolSchema } from './schema'

/** Identifiers are strings on the wire (#154); the schema says so and the types follow it. */
describe('identifier defs', () => {
  it('generates PlayerID, ClientID and SessionID as string aliases, used by reference', () => {
    const schema = {
      version: '1.0.0',
      schemaHash: 'test',
      defs: {
        PlayerID: { type: 'string', 'x-stateTree': { nodeKind: 'leaf' } },
        ClientID: { type: 'string', 'x-stateTree': { nodeKind: 'leaf' } },
        SessionID: { type: 'string', 'x-stateTree': { nodeKind: 'leaf' } },
        ShotEvent: {
          type: 'object',
          properties: { playerID: { $ref: '#/defs/PlayerID' }, owners: { type: 'array', items: { $ref: '#/defs/PlayerID' } } },
          required: ['playerID', 'owners']
        },
        GameState: { type: 'object', properties: {} }
      },
      lands: { game: { stateType: 'GameState', actions: {}, clientEvents: {}, events: { Shot: { $ref: '#/defs/ShotEvent' } } } }
    } as unknown as ProtocolSchema
    const defs = generateDefsTs(schema)

    expect(defs).toContain('export type PlayerID = string')
    expect(defs).toContain('export type ClientID = string')
    expect(defs).toContain('export type SessionID = string')
    expect(defs).not.toContain('rawValue')
    expect(defs).toContain("export type ShotEvent = { playerID: PlayerID; owners: PlayerID[] }")
  })
})
