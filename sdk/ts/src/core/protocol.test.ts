/**
 * Unit tests for protocol.ts
 * 
 * Tests message encoding/decoding, join/action/event message creation
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  encodeMessage,
  decodeMessage,
  createJoinMessage,
  createActionMessage,
  createEventMessage,
  generateRequestID,
  eventHashReverseLookup,
  clientEventHashReverseLookup,
  eventFieldOrder,
  clientEventFieldOrder
} from './protocol'
import type { TransportMessage, StateUpdate, StateSnapshot } from '../types/transport'

describe('protocol', () => {
  describe('encodeMessage', () => {
    it('encodes TransportMessage to JSON string', () => {
      const message: TransportMessage = {
        kind: 'join',
        payload: {
          join: {
            requestID: 'test-123',
            landType: 'demo-game',
            landInstanceId: null,
            playerID: 'player-1',
            deviceID: 'device-1',
            metadata: { test: 'value' }
          }
        } as any
      }

      const encoded = encodeMessage(message)
      expect(typeof encoded).toBe('string')
      
      const decoded = JSON.parse(encoded)
      expect(decoded.kind).toBe('join')
      expect(decoded.payload.join.requestID).toBe('test-123')
    })
  })

  describe('decodeMessage', () => {
    it('decodes TransportMessage from JSON string', () => {
      const message: TransportMessage = {
        kind: 'action',
        payload: {
          action: {
            requestID: 'action-123',
            landID: 'demo-game',
            actionType: 'BuyUpgrade',
            payload: 'base64encoded'
          }
        } as any
      }

      const encoded = JSON.stringify(message)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('kind', 'action')
      if ('kind' in decoded) {
        expect((decoded as TransportMessage).kind).toBe('action')
      }
    })

    it('decodes StateUpdate from JSON string', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/players',
            op: 'replace',
            value: {} // Native JSON format (no type wrapper)
          }
        ]
      }

      const encoded = JSON.stringify(update)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        expect((decoded as StateUpdate).patches.length).toBe(1)
      }
    })

    it('decodes StateUpdate with nested object from JSON string', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player',
            op: 'replace',
            value: {
              name: 'Alice',
              hp: 100,
              inventory: ['sword', 'potion']
            }
          },
          {
            path: '/stats',
            op: 'replace',
            value: {
              str: 10,
              dex: 8
            }
          }
        ]
      }

      const encoded = JSON.stringify(update)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const updateDecoded = decoded as StateUpdate
        expect(updateDecoded.patches.length).toBe(2)
        expect(updateDecoded.patches[0]).toMatchObject({
          path: '/player',
          op: 'replace',
          value: {
            name: 'Alice',
            hp: 100,
            inventory: ['sword', 'potion']
          }
        })
        expect(updateDecoded.patches[1]).toMatchObject({
          path: '/stats',
          op: 'replace',
          value: {
            str: 10,
            dex: 8
          }
        })
      }
    })

    it('decodes StateUpdate with deeply nested object from JSON string', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/player',
            op: 'replace',
            value: {
              name: 'Bob',
              level: 5,
              stats: {
                str: 10,
                dex: 8,
                equipment: {
                  weapon: 'sword',
                  armor: 'plate'
                }
              }
            }
          }
        ]
      }

      const encoded = JSON.stringify(update)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const updateDecoded = decoded as StateUpdate
        expect(updateDecoded.patches.length).toBe(1)
        expect(updateDecoded.patches[0].path).toBe('/player')
        expect(updateDecoded.patches[0].op).toBe('replace')
        if (updateDecoded.patches[0].value && typeof updateDecoded.patches[0].value === 'object') {
          const value = updateDecoded.patches[0].value as any
          expect(value.name).toBe('Bob')
          expect(value.level).toBe(5)
          expect(value.stats).toEqual({
            str: 10,
            dex: 8,
            equipment: {
              weapon: 'sword',
              armor: 'plate'
            }
          })
        }
      }
    })

    it('decodes opcode array StateUpdate from JSON string', () => {
      const updateArray = [
        2,
        'player-1',
        ['/players', 1, { hp: 10 }],
        ['/stats', 2],
        ['/items', 3, { id: 1 }]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(3)
        expect(update.patches[0]).toMatchObject({ path: '/players', op: 'replace', value: { hp: 10 } })
        expect(update.patches[1]).toMatchObject({ path: '/stats', op: 'remove' })
        expect(update.patches[2]).toMatchObject({ path: '/items', op: 'add', value: { id: 1 } })
      }
    })

    it('decodes opcode array noChange StateUpdate from JSON string', () => {
      const updateArray = [0, 'player-1']
      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'noChange')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(0)
      }
    })

    it('decodes opcode array firstSync StateUpdate from JSON string', () => {
      const updateArray = [1, 'player-1', ['/score', 1, 10]]
      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'firstSync')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({ path: '/score', op: 'replace', value: 10 })
      }
    })

    it('decodes opcode array StateUpdate with nested object', () => {
      const updateArray = [
        2,
        'player-1',
        ['/player', 1, { name: 'Alice', hp: 100, inventory: ['sword', 'potion'] }],
        ['/stats', 1, { str: 10, dex: 8 }]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        expect(update.patches[0]).toMatchObject({
          path: '/player',
          op: 'replace',
          value: { name: 'Alice', hp: 100, inventory: ['sword', 'potion'] }
        })
        expect(update.patches[1]).toMatchObject({
          path: '/stats',
          op: 'replace',
          value: { str: 10, dex: 8 }
        })
      }
    })

    it('decodes opcode array StateUpdate with deeply nested object', () => {
      const updateArray = [
        2,
        'player-1',
        [
          '/player',
          1,
          {
            name: 'Bob',
            level: 5,
            stats: {
              str: 10,
              dex: 8,
              equipment: {
                weapon: 'sword',
                armor: 'plate'
              }
            }
          }
        ]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0].path).toBe('/player')
        expect(update.patches[0].op).toBe('replace')
        if (update.patches[0].value && typeof update.patches[0].value === 'object') {
          const value = update.patches[0].value as any
          expect(value.name).toBe('Bob')
          expect(value.level).toBe(5)
          expect(value.stats).toEqual({
            str: 10,
            dex: 8,
            equipment: {
              weapon: 'sword',
              armor: 'plate'
            }
          })
        }
      }
    })

    it('throws when opcode array is received with jsonObject decoding', () => {
      const updateArray = [2, 'player-1', ['/score', 1, 10]]
      const encoded = JSON.stringify(updateArray)
      expect(() => decodeMessage(encoded, {
        message: 'json',
        stateUpdate: 'jsonObject',
        stateUpdateDecoding: 'jsonObject'
      })).toThrow('Unknown message format')
    })

    it('throws when JSON object is received with opcodeJsonArray decoding', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/score',
            op: 'replace',
            value: 10
          }
        ]
      }
      const encoded = JSON.stringify(update)
      expect(() => decodeMessage(encoded, {
        message: 'json',
        stateUpdate: 'opcodeJsonArray',
        stateUpdateDecoding: 'opcodeJsonArray'
      })).toThrow('Unknown message format')
    })

    it('decodes StateSnapshot from JSON string', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: { type: 'object', value: {} },
          round: { type: 'int', value: 0 }
        }
      }

      const encoded = JSON.stringify(snapshot)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('values')
      if ('values' in decoded) {
        expect(Object.keys((decoded as StateSnapshot).values).length).toBe(2)
      }
    })

    it('throws error for unknown message format', () => {
      const invalid = JSON.stringify({ unknown: 'format' })
      
      expect(() => decodeMessage(invalid)).toThrow('Unknown message format')
    })
  })

  describe('createJoinMessage', () => {
    it('creates join message with required fields', () => {
      const message = createJoinMessage('req-123', 'demo-game', null)

      expect(message.kind).toBe('join')
      expect(message.payload).toHaveProperty('join')
      const join = (message.payload as any).join
      expect(join.requestID).toBe('req-123')
      expect(join.landType).toBe('demo-game')
      expect(join.landInstanceId).toBeNull()
    })

    it('creates join message with optional fields', () => {
      const message = createJoinMessage(
        'req-456',
        'demo-game',
        'instance-123',
        {
          playerID: 'player-1',
          deviceID: 'device-1',
          metadata: { level: '10' }
        }
      )

      const join = (message.payload as any).join
      expect(join.playerID).toBe('player-1')
      expect(join.deviceID).toBe('device-1')
      expect(join.metadata).toEqual({ level: '10' })
    })
  })

  describe('createActionMessage', () => {
    it('creates action message with base64 encoded payload', () => {
      const payload = { upgradeID: 'cursor' }
      const message = createActionMessage('req-789', 'BuyUpgrade', payload)

      expect(message.kind).toBe('action')
      const action = message.payload as any
      // Simplified structure: fields directly in payload
      expect(action.requestID).toBe('req-789')
      expect(action.typeIdentifier).toBe('BuyUpgrade')
      expect(typeof action.payload).toBe('string') // base64 encoded
      
      // Decode and verify
      const decoded = JSON.parse(
        typeof Buffer !== 'undefined'
          ? Buffer.from(action.payload, 'base64').toString('utf-8')
          : decodeURIComponent(escape(atob(action.payload)))
      )
      expect(decoded).toEqual(payload)
    })
  })

  describe('createEventMessage', () => {
    it('creates event message with payload', () => {
      const payload = { amount: 1 }
      const message = createEventMessage('ClickCookie', payload, true)

      expect(message.kind).toBe('event')
      const eventPayload = message.payload as any
      // Simplified structure: fromClient is directly in payload
      expect(eventPayload.fromClient).toBeDefined()
      expect(eventPayload.fromClient.type).toBe('ClickCookie')
      expect(eventPayload.fromClient.payload).toEqual(payload)
    })
  })

  describe('generateRequestID', () => {
    it('generates unique request IDs', () => {
      const id1 = generateRequestID('join')
      const id2 = generateRequestID('action')
      const id3 = generateRequestID('join')

      expect(id1).toMatch(/^join-/)
      expect(id2).toMatch(/^action-/)
      expect(id3).toMatch(/^join-/)
      
      // IDs should be unique
      expect(id1).not.toBe(id3)
    })

    it('includes prefix in request ID', () => {
      const id = generateRequestID('test')
      expect(id.startsWith('test-')).toBe(true)
    })
  })

  describe('PathHash format decoding', async () => {
    // Import pathHashReverseLookup for testing
    const { pathHashReverseLookup } = await import('./protocol')

    beforeEach(() => {
      // Setup mock pathHashes (simulate schema initialization)
      pathHashReverseLookup.clear()
      pathHashReverseLookup.set(123456, 'monsters.*')
      pathHashReverseLookup.set(789012, 'monsters.*.position')
      pathHashReverseLookup.set(345678, 'monsters.*.rotation')
      pathHashReverseLookup.set(901234, 'monsters.*.rotation.degrees')
      pathHashReverseLookup.set(567890, 'monsters.*.health')
      pathHashReverseLookup.set(111111, 'players.*')
      pathHashReverseLookup.set(222222, 'players.*.hp')
    })

    it('decodes PathHash format with static path', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [222222, null, 1, 100] // [pathHash, dynamicKey, op, value]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/*/hp',
          op: 'replace',
          value: 100
        })
      }
    })

    it('decodes PathHash format with dynamic key', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [567890, '42', 1, 50] // monsters.42.health = 50
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/monsters/42/health',
          op: 'replace',
          value: 50
        })
      }
    })

    it('decodes PathHash format remove operation', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [123456, '36', 2] // remove monsters.36
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/monsters/36',
          op: 'remove'
        })
        expect(update.patches[0].value).toBeUndefined()
      }
    })

    it('decodes mixed Legacy and PathHash formats', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        ['/score', 1, 100], // Legacy format
        [567890, '42', 1, 50] // PathHash format
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        expect(update.patches[0]).toMatchObject({
          path: '/score',
          op: 'replace',
          value: 100
        })
        expect(update.patches[1]).toMatchObject({
          path: '/monsters/42/health',
          op: 'replace',
          value: 50
        })
      }
    })

    it('decodes PathHash format with nested property (rotation.degrees)', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [901234, '37', 1, 90] // monsters.37.rotation.degrees = 90
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/monsters/37/rotation/degrees',
          op: 'replace',
          value: 90
        })
      }
    })

    it('throws error for unknown pathHash', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [999999, '42', 1, 50] // Unknown hash
      ]

      const encoded = JSON.stringify(updateArray)
      expect(() => decodeMessage(encoded)).toThrow('Unknown pathHash: 999999')
    })

    it('decodes PathHash format with complex object value', () => {
      const updateArray = [
        2, // diff opcode
        'player-1',
        [789012, '42', 1, { v: { x: 10, y: 20 } }] // monsters.42.position
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/monsters/42/position',
          op: 'replace',
          value: { v: { x: 10, y: 20 } }
        })
      }
    })
  })

  describe('playerSlot compression', async () => {
    // Import pathHashReverseLookup for testing
    const { pathHashReverseLookup } = await import('./protocol')

    beforeEach(() => {
      // Setup mock pathHashes (simulate schema initialization)
      pathHashReverseLookup.clear()
      pathHashReverseLookup.set(222222, 'players.*.hp')
      pathHashReverseLookup.set(567890, 'monsters.*.health')
    })

    it('decodes opcode format with playerSlot (Int) instead of playerID (String)', () => {
      const playerSlot = 42
      const updateArray = [
        2, // diff opcode
        playerSlot, // playerSlot (Int) instead of playerID (String)
        [222222, null, 1, 100] // [pathHash, dynamicKey, op, value]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/*/hp',
          op: 'replace',
          value: 100
        })
      }
    })

    it('decodes firstSync opcode with playerSlot (Int)', () => {
      const playerSlot = 12345
      const updateArray = [
        1, // firstSync opcode
        playerSlot, // playerSlot (Int)
        [222222, null, 1, 100],
        [567890, 'monster-1', 1, 50]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'firstSync')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        expect(update.patches[0]).toMatchObject({
          path: '/players/*/hp',
          op: 'replace',
          value: 100
        })
        expect(update.patches[1]).toMatchObject({
          path: '/monsters/monster-1/health',
          op: 'replace',
          value: 50
        })
      }
    })

    it('decodes noChange opcode with playerSlot (Int)', () => {
      const playerSlot = 999
      const updateArray = [
        0, // noChange opcode
        playerSlot // playerSlot (Int)
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'noChange')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(0)
      }
    })

    it('maintains backward compatibility with playerID (String)', () => {
      const playerID = 'player-very-long-id-string'
      const updateArray = [
        2, // diff opcode
        playerID, // playerID (String) - legacy format
        [222222, null, 1, 100]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/*/hp',
          op: 'replace',
          value: 100
        })
      }
    })

    it('throws error for invalid playerIdentifier type', () => {
      const updateArray = [
        2, // diff opcode
        true, // Invalid type (should be string or number)
        [222222, null, 1, 100]
      ]

      const encoded = JSON.stringify(updateArray)
      expect(() => {
        decodeMessage(encoded, { 
          message: 'json', 
          stateUpdate: 'opcodeJsonArray', 
          stateUpdateDecoding: 'opcodeJsonArray' 
        })
      }).toThrow('expected string (playerID) or number (playerSlot)')
    })

    it('decodes playerSlot with PathHash format patches', () => {
      const playerSlot = 777
      const updateArray = [
        2, // diff opcode
        playerSlot, // playerSlot (Int)
        [222222, 'player-abc', 1, 150], // PathHash with dynamic key
        [567890, null, 1, 75] // PathHash without dynamic key
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        expect(update.patches[0]).toMatchObject({
          path: '/players/player-abc/hp',
          op: 'replace',
          value: 150
        })
        expect(update.patches[1]).toMatchObject({
          path: '/monsters/*/health',
          op: 'replace',
          value: 75
        })
      }
    })

    it('decodes playerSlot with mixed Legacy and PathHash formats', () => {
      const playerSlot = 888
      const updateArray = [
        2, // diff opcode
        playerSlot, // playerSlot (Int)
        ['/score', 1, 200], // Legacy format
        [567890, 'monster-xyz', 1, 60] // PathHash format
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: 'json', 
        stateUpdate: 'opcodeJsonArray', 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        expect(update.patches[0]).toMatchObject({
          path: '/score',
          op: 'replace',
          value: 200
        })
        expect(update.patches[1]).toMatchObject({
          path: '/monsters/monster-xyz/health',
          op: 'replace',
          value: 60
        })
      }
    })
  })

  describe('Event Opcode Decoding', () => {

    beforeEach(() => {
      // Reset lookups
      eventHashReverseLookup.clear()
      clientEventHashReverseLookup.clear()
    })

    it('falls back to string type if rawType is string', () => {
      const eventPayload = { msg: 'hello' }
      const eventArray = [
        103, // Opcode for Event
        1,   // Direction: fromServer
        'UnknownEvent', // String type
        eventPayload,
        null
      ]
      
      const encoded = JSON.stringify(eventArray)
      const decoded = decodeMessage(encoded)
      
      expect(decoded).toHaveProperty('kind', 'event')
      if ('kind' in decoded && decoded.kind === 'event') {
        const messagePayload = decoded.payload as any
        const event = messagePayload.fromServer
        expect(event.type).toBe('UnknownEvent')
        expect(event.payload).toEqual(eventPayload)
      }
    })

    it('throws error for unknown event opcode', () => {
      const eventArray = [
        103,
        1,
        999, // Unknown opcode
        {},
        null
      ]
      
      const encoded = JSON.stringify(eventArray)
      expect(() => decodeMessage(encoded)).toThrow('Unknown event opcode: 999')
    })
  })
})
