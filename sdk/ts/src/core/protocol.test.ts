/**
 * Unit tests for protocol.ts
 * 
 * Tests message encoding/decoding, join/action/event message creation
 */

import { describe, it, expect, beforeEach } from 'vitest'
import {
  encodeMessage,
  encodeMessageArray,
  encodeMessageArrayToMessagePack,
  decodeMessage,
  createJoinMessage,
  createActionMessage,
  createEventMessage,
  generateRequestID,
  eventHashReverseLookup,
  clientEventHashReverseLookup,
  eventFieldOrder,
  clientEventFieldOrder,
  pathHashReverseLookup,
  MessageKindOpcode,
  StateUpdateOpcode,
  StatePatchOpcode,
  EventDirection
} from './protocol'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'
import type { TransportMessage, StateUpdate, StateSnapshot, StateUpdateWithEvents } from '../types/transport'

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
          requestID: 'action-123',
          typeIdentifier: 'BuyUpgrade',
          payload: { upgradeID: 'cursor' }
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
      const updateArray = [StateUpdateOpcode.noChange]
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
      const updateArray = [StateUpdateOpcode.firstSync, ['/score', StatePatchOpcode.replace, 10]]
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

    it('decodes opcode 107 (stateUpdateWithEvents) from JSON array', () => {
      const statePayload = [StateUpdateOpcode.diff, ['/score', StatePatchOpcode.replace, 10]]
      const eventsPayload = [[EventDirection.fromServer, 'GameStarted', { gameID: 'g1' }]]
      const payload107 = [MessageKindOpcode.stateUpdateWithEvents, statePayload, eventsPayload]
      const encoded = JSON.stringify(payload107)
      const decoded = decodeMessage(encoded, {
        message: MessageEncodingValues.opcodeJsonArray,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray
      })

      expect(decoded).toHaveProperty('type', 'stateUpdateWithEvents')
      const combined = decoded as StateUpdateWithEvents
      expect(combined.stateUpdate).toBeDefined()
      expect(combined.stateUpdate.type).toBe('diff')
      expect(combined.stateUpdate.patches.length).toBe(1)
      expect(combined.stateUpdate.patches[0]).toMatchObject({ path: '/score', op: 'replace', value: 10 })
      expect(Array.isArray(combined.events)).toBe(true)
      expect(combined.events.length).toBe(1)
      expect(combined.events[0].kind).toBe('event')
      expect((combined.events[0].payload as any).fromServer).toBeDefined()
      expect((combined.events[0].payload as any).fromServer.type).toBe('GameStarted')
      expect((combined.events[0].payload as any).fromServer.payload).toEqual({ gameID: 'g1' })
    })

    it('decodes opcode array StateUpdate with nested object', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        ['/player', StatePatchOpcode.replace, { name: 'Alice', hp: 100, inventory: ['sword', 'potion'] }],
        ['/stats', StatePatchOpcode.replace, { str: 10, dex: 8 }]
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
        StateUpdateOpcode.diff,
        [
          '/player',
          StatePatchOpcode.replace,
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
      const updateArray = [StateUpdateOpcode.diff, ['/score', StatePatchOpcode.replace, 10]]
      const encoded = JSON.stringify(updateArray)
      expect(() => decodeMessage(encoded, {
        message: MessageEncodingValues.json,
        stateUpdate: StateUpdateEncodingValues.jsonObject,
        stateUpdateDecoding: StateUpdateEncodingValues.jsonObject
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
        message: MessageEncodingValues.json,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray,
        stateUpdateDecoding: StateUpdateEncodingValues.opcodeJsonArray
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

    it('decodes StateUpdate from JSON bytes (binary WebSocket frame)', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          { path: '/count', op: 'replace', value: 1 }
        ]
      }

      const encoded = JSON.stringify(update)
      const bytes = new TextEncoder().encode(encoded)
      const decoded = decodeMessage(bytes)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const u = decoded as StateUpdate
        expect(u.patches.length).toBe(1)
        expect(u.patches[0]).toMatchObject({ path: '/count', op: 'replace', value: 1 })
      }
    })

    it('decodes StateSnapshot from JSON bytes (binary WebSocket frame)', () => {
      const snapshot: StateSnapshot = {
        values: {
          count: 0
        }
      }

      const encoded = JSON.stringify(snapshot)
      const bytes = new TextEncoder().encode(encoded)
      const decoded = decodeMessage(bytes)

      expect(decoded).toHaveProperty('values')
      if ('values' in decoded) {
        expect((decoded as StateSnapshot).values).toEqual({ count: 0 })
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
    it('creates action message with raw payload', () => {
      const payload = { upgradeID: 'cursor' }
      const message = createActionMessage('req-789', 'BuyUpgrade', payload)

      expect(message.kind).toBe('action')
      const action = message.payload as any
      // Simplified structure: fields directly in payload
      expect(action.requestID).toBe('req-789')
      expect(action.typeIdentifier).toBe('BuyUpgrade')
      expect(action.payload).toEqual(payload)
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
      // Real-world example from docs: 0xC8312A34 = 3358665268
      pathHashReverseLookup.set(3358665268, 'players.*.position')
      // Multi-wildcard example (nested maps/arrays)
      pathHashReverseLookup.set(888888, 'players.*.inventory.*.itemId')
    })

    function hexToBytes(hex: string): Uint8Array {
      const cleaned = hex.replace(/\s+/g, '')
      if (cleaned.length % 2 !== 0) {
        throw new Error(`Invalid hex length: ${cleaned.length}`)
      }
      const out = new Uint8Array(cleaned.length / 2)
      for (let i = 0; i < cleaned.length; i += 2) {
        out[i / 2] = parseInt(cleaned.slice(i, i + 2), 16)
      }
      return out
    }

    it('decodes PathHash format with static path', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, null, StatePatchOpcode.replace, 100] // [pathHash, dynamicKey, op, value]
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

    it('decodes MessagePack bytes (uint32 PathHash, CE) into StateUpdate', () => {
      // MessagePack for: [2, [3358665268, 1, 1, 100]]
      // 92 = array(2), 02 = diff, 94 = array(4), CE = uint32(0xC8312A34), 01 01 64
      const bytes = hexToBytes('92 02 94 CE C8 31 2A 34 01 01 64')
      const decoded = decodeMessage(bytes)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/1/position',
          op: 'replace',
          value: 100
        })
      }
    })

    it('decodes MessagePack bytes (float64 PathHash, CB) into StateUpdate', () => {
      // Some JS-based encoders emit 3358665268 as float64 (CB) instead of uint32 (CE).
      // This still decodes to the same numeric value in JS (<= 2^53, so exact).
      const bytes = hexToBytes('92 02 94 CB 41 E9 06 25 46 80 00 00 01 01 64')
      const decoded = decodeMessage(bytes)

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/1/position',
          op: 'replace',
          value: 100
        })
      }
    })

    it('decodes PathHash format with dynamic key', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [567890, '42', StatePatchOpcode.replace, 50] // monsters.42.health = 50
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

    it('decodes PathHash format with multiple dynamic keys (multi-wildcard pattern)', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        // [pathHash, dynamicKeys[], op, value]
        [888888, ['42', '7'], StatePatchOpcode.replace, 'sword']
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/42/inventory/7/itemId',
          op: 'replace',
          value: 'sword'
        })
      }
    })

    it('decodes PathHash format remove operation', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [123456, '36', StatePatchOpcode.remove] // remove monsters.36
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
        StateUpdateOpcode.diff,
        ['/score', StatePatchOpcode.replace, 100], // Legacy format
        [567890, '42', StatePatchOpcode.replace, 50] // PathHash format
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
        StateUpdateOpcode.diff,
        [901234, '37', StatePatchOpcode.replace, 90] // monsters.37.rotation.degrees = 90
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
        StateUpdateOpcode.diff,
        [999999, '42', StatePatchOpcode.replace, 50] // Unknown hash
      ]

      const encoded = JSON.stringify(updateArray)
      expect(() => decodeMessage(encoded)).toThrow('Unknown pathHash: 999999')
    })

    it('decodes PathHash format with complex object value', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [789012, '42', StatePatchOpcode.replace, { v: { x: 10, y: 20 } }] // monsters.42.position
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
    beforeEach(() => {
      // Setup mock pathHashes (simulate schema initialization)
      pathHashReverseLookup.clear()
      pathHashReverseLookup.set(222222, 'players.*.hp')
      pathHashReverseLookup.set(567890, 'monsters.*.health')
    })

    it('decodes compressed path with dynamic key', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, null, StatePatchOpcode.replace, 100] // [pathHash, dynamicKey, op, value]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: MessageEncodingValues.json, 
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray, 
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
      const updateArray = [
        StateUpdateOpcode.firstSync,
        [222222, null, StatePatchOpcode.replace, 100],
        [567890, 'monster-1', 1, 50]
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: MessageEncodingValues.json, 
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray, 
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
      const updateArray = [
        StateUpdateOpcode.noChange,
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: MessageEncodingValues.json, 
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray, 
        stateUpdateDecoding: 'opcodeJsonArray' 
      })

      expect(decoded).toHaveProperty('type', 'noChange')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(0)
      }
    })



    it('decodes playerSlot with PathHash format patches', () => {
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, 'player-abc', StatePatchOpcode.replace, 150], // PathHash with dynamic key
        [567890, null, StatePatchOpcode.replace, 75] // PathHash without dynamic key
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: MessageEncodingValues.json, 
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray, 
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
      const updateArray = [
        StateUpdateOpcode.diff,
        ['/score', StatePatchOpcode.replace, 200], // Legacy format
        [567890, 'monster-xyz', StatePatchOpcode.replace, 60] // PathHash format
      ]

      const encoded = JSON.stringify(updateArray)
      const decoded = decodeMessage(encoded, { 
        message: MessageEncodingValues.json, 
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray, 
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
        MessageKindOpcode.event, // Opcode for Event
        EventDirection.fromServer,   // Direction: fromServer
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

  describe('encodeMessageArray - joinResponse with encoding', () => {
    it('encodes joinResponse with encoding field', () => {
      const message: TransportMessage = {
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: 'req-123',
            success: true,
            landType: 'demo-game',
            landInstanceId: 'instance-1',
            playerSlot: 0,
            encoding: MessageEncodingValues.opcodeJsonArray,
            reason: undefined
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(105) // opcode
      expect(array[1]).toBe('req-123') // requestID
      expect(array[2]).toBe(1) // success
      expect(array[3]).toBe('demo-game') // landType
      expect(array[4]).toBe('instance-1') // landInstanceId
      expect(array[5]).toBe(0) // playerSlot
      expect(array[6]).toBe('opcodeJsonArray') // encoding
      expect(array.length).toBe(7) // No reason field
    })

    it('encodes joinResponse without encoding field', () => {
      const message: TransportMessage = {
        kind: 'joinResponse',
        payload: {
          joinResponse: {
            requestID: 'req-456',
            success: false,
            reason: 'Room full'
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.joinResponse)
      expect(array[1]).toBe('req-456') // requestID
      expect(array[2]).toBe(0) // success
      expect(array[3]).toBe(null) // landType
      expect(array[4]).toBe(null) // landInstanceId
      expect(array[5]).toBe(null) // playerSlot
      expect(array[6]).toBe(null) // encoding (null when not provided)
      expect(array[7]).toBe('Room full') // reason
    })

    it('decodes joinResponse with encoding field from opcode array', () => {
      const array = [
        MessageKindOpcode.joinResponse,
        'req-789',
        1, // success
        'demo-game',
        'instance-2',
        1, // playerSlot
        MessageEncodingValues.opcodeJsonArray, // encoding
        null // reason
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('joinResponse')
      const payload = (decoded.payload as any).joinResponse
      expect(payload.requestID).toBe('req-789')
      expect(payload.success).toBe(true)
      expect(payload.landType).toBe('demo-game')
      expect(payload.landInstanceId).toBe('instance-2')
      expect(payload.playerSlot).toBe(1)
      expect(payload.encoding).toBe(MessageEncodingValues.opcodeJsonArray)
    })

    it('decodes joinResponse without encoding field from opcode array', () => {
      const array = [
        MessageKindOpcode.joinResponse,
        'req-999',
        0, // success
        null, // landType
        null, // landInstanceId
        null, // playerSlot
        null, // encoding (not provided)
        'Access denied' // reason
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('joinResponse')
      const payload = (decoded.payload as any).joinResponse
      expect(payload.requestID).toBe('req-999')
      expect(payload.success).toBe(false)
      expect(payload.encoding).toBeUndefined()
      expect(payload.reason).toBe('Access denied')
    })
  })

  describe('Opcode Constants', () => {
    it('has correct MessageKindOpcode values', () => {
      expect(MessageKindOpcode.action).toBe(101)
      expect(MessageKindOpcode.actionResponse).toBe(102)
      expect(MessageKindOpcode.event).toBe(103)
      expect(MessageKindOpcode.join).toBe(104)
      expect(MessageKindOpcode.joinResponse).toBe(105)
      expect(MessageKindOpcode.error).toBe(106)
    })

    it('has correct StateUpdateOpcode values', () => {
      expect(StateUpdateOpcode.noChange).toBe(0)
      expect(StateUpdateOpcode.firstSync).toBe(1)
      expect(StateUpdateOpcode.diff).toBe(2)
    })

    it('has correct StatePatchOpcode values', () => {
      expect(StatePatchOpcode.replace).toBe(1)
      expect(StatePatchOpcode.remove).toBe(2)
      expect(StatePatchOpcode.add).toBe(3)
    })

    it('has correct EventDirection values', () => {
      expect(EventDirection.fromClient).toBe(0)
      expect(EventDirection.fromServer).toBe(1)
    })

    it('has correct MessageEncodingValues', () => {
      expect(MessageEncodingValues.json).toBe('json')
      expect(MessageEncodingValues.opcodeJsonArray).toBe('opcodeJsonArray')
      expect(MessageEncodingValues.messagepack).toBe('messagepack')
    })

    it('has correct StateUpdateEncodingValues', () => {
      expect(StateUpdateEncodingValues.jsonObject).toBe('jsonObject')
      expect(StateUpdateEncodingValues.opcodeJsonArray).toBe('opcodeJsonArray')
    })
  })

  describe('encodeMessageArray - other message types', () => {
    it('encodes action message', () => {
      const message: TransportMessage = {
        kind: 'action',
        payload: {
          requestID: 'req-action-1',
          typeIdentifier: 'BuyItem',
          payload: { itemID: 'sword' }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.action)
      expect(array[1]).toBe('req-action-1')
      expect(array[2]).toBe('BuyItem')
      expect(array[3]).toEqual({ itemID: 'sword' })
    })

    it('encodes actionResponse message', () => {
      const message: TransportMessage = {
        kind: 'actionResponse',
        payload: {
          actionResponse: {
            requestID: 'req-action-1',
            response: { success: true, itemID: 'sword' }
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.actionResponse)
      expect(array[1]).toBe('req-action-1')
      expect(array[2]).toEqual({ success: true, itemID: 'sword' })
    })

    it('encodes error message', () => {
      const message: TransportMessage = {
        kind: 'error',
        payload: {
          error: {
            code: 'INVALID_ACTION',
            message: 'Action not found',
            details: { actionType: 'UnknownAction' }
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.error)
      expect(array[1]).toBe('INVALID_ACTION')
      expect(array[2]).toBe('Action not found')
      expect(array[3]).toEqual({ actionType: 'UnknownAction' })
    })

    it('encodes join message', () => {
      const message: TransportMessage = {
        kind: 'join',
        payload: {
          join: {
            requestID: 'req-join-1',
            landType: 'demo-game',
            landInstanceId: 'room-123',
            playerID: 'player-1',
            deviceID: 'device-1',
            metadata: { version: '1.0' }
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.join)
      expect(array[1]).toBe('req-join-1')
      expect(array[2]).toBe('demo-game')
      expect(array[3]).toBe('room-123')
      expect(array[4]).toBe('player-1')
      expect(array[5]).toBe('device-1')
      expect(array[6]).toEqual({ version: '1.0' })
    })

    it('encodes event message fromClient', () => {
      const message: TransportMessage = {
        kind: 'event',
        payload: {
          fromClient: {
            type: 'ClickButton',
            payload: { buttonID: 'start' }
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.event)
      expect(array[1]).toBe(EventDirection.fromClient)
      expect(array[2]).toBe('ClickButton')
      expect(array[3]).toEqual({ buttonID: 'start' })
    })

    it('encodes event message fromServer', () => {
      const message: TransportMessage = {
        kind: 'event',
        payload: {
          fromServer: {
            type: 'GameStarted',
            payload: { gameID: 'game-123' }
          }
        } as any
      }

      const encoded = encodeMessageArray(message)
      const array = JSON.parse(encoded)
      
      expect(array[0]).toBe(MessageKindOpcode.event)
      expect(array[1]).toBe(EventDirection.fromServer)
      expect(array[2]).toBe('GameStarted')
      expect(array[3]).toEqual({ gameID: 'game-123' })
    })
  })

  describe('decodeTransportMessageArray - other message types', () => {
    it('decodes action message from opcode array', () => {
      const array = [
        MessageKindOpcode.action,
        'req-action-1',
        'BuyItem',
        { itemID: 'sword' }
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('action')
      const payload = decoded.payload as any
      expect(payload.requestID).toBe('req-action-1')
      expect(payload.typeIdentifier).toBe('BuyItem')
      expect(payload.payload).toEqual({ itemID: 'sword' })
    })

    it('decodes actionResponse message from opcode array', () => {
      const array = [
        MessageKindOpcode.actionResponse,
        'req-action-1',
        { success: true, itemID: 'sword' }
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('actionResponse')
      const payload = (decoded.payload as any).actionResponse
      expect(payload.requestID).toBe('req-action-1')
      expect(payload.response).toEqual({ success: true, itemID: 'sword' })
    })

    it('decodes error message from opcode array', () => {
      const array = [
        MessageKindOpcode.error,
        'INVALID_ACTION',
        'Action not found',
        { actionType: 'UnknownAction' }
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('error')
      const payload = (decoded.payload as any).error
      expect(payload.code).toBe('INVALID_ACTION')
      expect(payload.message).toBe('Action not found')
      expect(payload.details).toEqual({ actionType: 'UnknownAction' })
    })

    it('decodes join message from opcode array', () => {
      const array = [
        MessageKindOpcode.join,
        'req-join-1',
        'demo-game',
        'room-123',
        'player-1',
        'device-1',
        { version: '1.0' }
      ]

      const encoded = JSON.stringify(array)
      const decoded = decodeMessage(encoded) as TransportMessage

      expect(decoded.kind).toBe('join')
      const payload = (decoded.payload as any).join
      expect(payload.requestID).toBe('req-join-1')
      expect(payload.landType).toBe('demo-game')
      expect(payload.landInstanceId).toBe('room-123')
      expect(payload.playerID).toBe('player-1')
      expect(payload.deviceID).toBe('device-1')
      expect(payload.metadata).toEqual({ version: '1.0' })
    })
  })

  describe('Dynamic key slot error handling', () => {
    beforeEach(() => {
      // Setup mock pathHashes
      pathHashReverseLookup.clear()
      pathHashReverseLookup.set(222222, 'players.*.hp')
    })

    it('throws error when dynamic key slot is used before definition', () => {
      // Create a state update where slot 0 is used before it's defined
      // This simulates a malformed message where patches are out of order
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, 0, StatePatchOpcode.replace, 100] // Uses slot 0 before it's defined
      ]

      const encoded = JSON.stringify(updateArray)
      
      // Create a dynamicKeyMap to enable slot-based resolution
      // Slot 0 is NOT defined in the map, so it should throw
      const dynamicKeyMap = new Map<number, string>()
      // Don't define slot 0 - this should cause the error
      
      // Should throw error because slot 0 is not defined in dynamicKeyMap
      expect(() => decodeMessage(encoded, {
        message: MessageEncodingValues.json,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray,
        stateUpdateDecoding: StateUpdateEncodingValues.opcodeJsonArray
      }, dynamicKeyMap)).toThrow('Dynamic key slot 0 used before definition')
    })

    it('decodes correctly when dynamic key slot is defined before use', () => {
      // Define slot 0 first, then use it
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, [0, 'player-1'], StatePatchOpcode.replace, 100], // Define slot 0 = 'player-1'
        [222222, 0, StatePatchOpcode.replace, 150] // Use slot 0
      ]

      const encoded = JSON.stringify(updateArray)
      const dynamicKeyMap = new Map<number, string>()
      
      const decoded = decodeMessage(encoded, {
        message: MessageEncodingValues.json,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray,
        stateUpdateDecoding: StateUpdateEncodingValues.opcodeJsonArray
      }, dynamicKeyMap)

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(2)
        // Both patches should resolve to the same path since slot 0 = 'player-1'
        expect(update.patches[0]).toMatchObject({
          path: '/players/player-1/hp',
          op: 'replace',
          value: 100
        })
        expect(update.patches[1]).toMatchObject({
          path: '/players/player-1/hp',
          op: 'replace',
          value: 150
        })
      }
    })

    it('falls back to string conversion when dynamicKeyMap is not provided', () => {
      // When dynamicKeyMap is not provided, number slots are converted to strings
      const updateArray = [
        StateUpdateOpcode.diff,
        [222222, 0, StatePatchOpcode.replace, 100] // Slot 0 without map
      ]

      const encoded = JSON.stringify(updateArray)
      
      // No dynamicKeyMap provided - should fallback to String(0) = "0"
      const decoded = decodeMessage(encoded, {
        message: MessageEncodingValues.json,
        stateUpdate: StateUpdateEncodingValues.opcodeJsonArray,
        stateUpdateDecoding: StateUpdateEncodingValues.opcodeJsonArray
      })

      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        expect(update.patches.length).toBe(1)
        expect(update.patches[0]).toMatchObject({
          path: '/players/0/hp', // Falls back to string "0"
          op: 'replace',
          value: 100
        })
      }
    })
  })
})
