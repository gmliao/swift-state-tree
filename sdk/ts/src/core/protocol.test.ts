/**
 * Unit tests for protocol.ts
 * 
 * Tests message encoding/decoding, join/action/event message creation
 */

import { describe, it, expect } from 'vitest'
import {
  encodeMessage,
  decodeMessage,
  createJoinMessage,
  createActionMessage,
  createEventMessage,
  generateRequestID
} from './protocol'
import type { TransportMessage, StateUpdate, StateSnapshot } from '../types/transport'
import { encode as encodeMessagePack } from '@msgpack/msgpack'

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

      const encoded = encodeMessage(message, 'json')
      expect(typeof encoded).toBe('string')
      
      const decoded = JSON.parse(encoded)
      expect(decoded.kind).toBe('join')
      expect(decoded.payload.join.requestID).toBe('test-123')
    })

    it('encodes TransportMessage to MessagePack bytes', () => {
      const message: TransportMessage = {
        kind: 'join',
        payload: {
          join: {
            requestID: 'test-456',
            landType: 'demo-game',
            landInstanceId: null
          }
        } as any
      }

      const encoded = encodeMessage(message, 'messagepack')
      expect(encoded).toBeInstanceOf(Uint8Array)

      const decoded = decodeMessage(encoded as Uint8Array, 'messagepack')
      expect(decoded).toHaveProperty('kind', 'join')
      if ('kind' in decoded) {
        expect(decoded.kind).toBe('join')
      }
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
      const decoded = decodeMessage(encoded, 'json')

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
      const decoded = decodeMessage(encoded, 'json')

      expect(decoded).toHaveProperty('type', 'diff')
      expect(decoded).toHaveProperty('patches')
      if ('type' in decoded && 'patches' in decoded) {
        expect((decoded as StateUpdate).patches.length).toBe(1)
      }
    })

    it('decodes StateSnapshot from JSON string', () => {
      const snapshot: StateSnapshot = {
        values: {
          players: { type: 'object', value: {} },
          round: { type: 'int', value: 0 }
        }
      }

      const encoded = JSON.stringify(snapshot)
      const decoded = decodeMessage(encoded, 'json')

      expect(decoded).toHaveProperty('values')
      if ('values' in decoded) {
        expect(Object.keys((decoded as StateSnapshot).values).length).toBe(2)
      }
    })

    it('throws error for unknown message format', () => {
      const invalid = JSON.stringify({ unknown: 'format' })
      
      expect(() => decodeMessage(invalid, 'json')).toThrow('Unknown message format')
    })

    it('decodes StateUpdate from MessagePack bytes', () => {
      const update: StateUpdate = {
        type: 'diff',
        patches: [
          {
            path: '/players',
            op: 'replace',
            value: { foo: 'bar' }
          }
        ]
      }

      const encoded = encodeMessagePack(update)
      const decoded = decodeMessage(encoded, 'messagepack')
      expect(decoded).toHaveProperty('type', 'diff')
      if ('type' in decoded && 'patches' in decoded) {
        expect(decoded.patches.length).toBe(1)
      }
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
      const message = createActionMessage('req-789', 'demo-game', 'BuyUpgrade', payload)

      expect(message.kind).toBe('action')
      const action = (message.payload as any).action
      expect(action.requestID).toBe('req-789')
      expect(action.landID).toBe('demo-game')
      expect(action.action.typeIdentifier).toBe('BuyUpgrade')
      expect(typeof action.action.payload).toBe('string') // base64 encoded
      
      // Decode and verify
      const decoded = JSON.parse(
        typeof Buffer !== 'undefined'
          ? Buffer.from(action.action.payload, 'base64').toString('utf-8')
          : decodeURIComponent(escape(atob(action.action.payload)))
      )
      expect(decoded).toEqual(payload)
    })

    it('creates action message with binary payload', () => {
      const payload = { upgradeID: 'cursor' }
      const message = createActionMessage('req-790', 'demo-game', 'BuyUpgrade', payload, {
        payloadEncoding: 'binary'
      })

      const action = (message.payload as any).action
      expect(action.action.typeIdentifier).toBe('BuyUpgrade')
      expect(action.action.payload).toBeInstanceOf(Uint8Array)
    })
  })

  describe('createEventMessage', () => {
    it('creates event message with payload', () => {
      const payload = { amount: 1 }
      const message = createEventMessage('demo-game', 'ClickCookie', payload, true)

      expect(message.kind).toBe('event')
      const eventPayload = (message.payload as any).event
      expect(eventPayload.landID).toBe('demo-game')
      expect(eventPayload.event.fromClient).toBeDefined()
      expect(eventPayload.event.fromClient.event.type).toBe('ClickCookie')
      expect(eventPayload.event.fromClient.event.payload).toEqual(payload)
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
})
