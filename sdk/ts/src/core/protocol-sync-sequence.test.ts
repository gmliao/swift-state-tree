/**
 * The sync sequence (`stateUpdateFeatures: ["syncSequence"]`): the server writes the land's sync
 * sequence right after the state-update opcode (`[opcode, seq, patch...]`), inside an opcode 107
 * frame too, and as a `seq` key in the JSON object. Patches are always arrays, so a scalar at
 * index 1 is the sequence; a frame without one decodes as before.
 */

import { describe, it, expect } from 'vitest'
import { encode as msgpackEncode, decode as msgpackDecode } from '@msgpack/msgpack'
import { decodeMessage, encodeSyncAck, SUPPORTED_STATE_UPDATE_FEATURES, StateUpdateFeatures } from './protocol'
import type { StateUpdate, StateUpdateWithEvents, TransportEncodingConfig } from '../types/transport'

const features = [StateUpdateFeatures.syncSequence]
const opcodeJson: TransportEncodingConfig = { message: 'json', stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: features }
const messagepack: TransportEncodingConfig = { message: 'messagepack', stateUpdate: 'opcodeJsonArray', stateUpdateFeatures: features }
const withoutFeature: TransportEncodingConfig = { message: 'json', stateUpdate: 'opcodeJsonArray' }

describe('sync sequence', () => {
  it('is declared with every join', () => {
    expect(SUPPORTED_STATE_UPDATE_FEATURES).toContain(StateUpdateFeatures.syncSequence)
  })

  it('is read from right after the opcode in opcode JSON', () => {
    const update = decodeMessage('[2,7,["/count",1,5]]', opcodeJson, new Map()) as StateUpdate
    expect(update.type).toBe('diff')
    expect(update.seq).toBe(7)
    expect(update.patches).toEqual([{ path: '/count', op: 'replace', value: 5 }])
  })

  it('decodes a frame without the feature as before', () => {
    const update = decodeMessage('[2,["/count",1,5]]', withoutFeature, new Map()) as StateUpdate
    expect(update.seq).toBeUndefined()
    expect(update.patches).toHaveLength(1)
  })

  it('follows the negotiated feature, not the frame shape', () => {
    // Negotiated: index 1 must be the sequence.
    expect(() => decodeMessage('[2,["/count",1,5]]', opcodeJson, new Map())).toThrow(/invalid sync sequence/)
    // Not negotiated: a sequence is a malformed patch.
    expect(() => decodeMessage('[2,7,["/count",1,5]]', withoutFeature, new Map())).toThrow(/Unknown message format/)
    // A zero-patch frame with its sequence.
    expect(decodeMessage('[2,9]', opcodeJson, new Map())).toEqual({ type: 'diff', patches: [], seq: 9 })
  })

  it('is carried by noChange and firstSync', () => {
    const none = decodeMessage('[0,3]', opcodeJson, new Map()) as StateUpdate
    expect(none).toEqual({ type: 'noChange', patches: [], seq: 3 })
    const first = decodeMessage('[1,4,["/count",1,1]]', opcodeJson, new Map()) as StateUpdate
    expect(first.type).toBe('firstSync')
    expect(first.seq).toBe(4)
  })

  it('is read from MessagePack, inside an opcode 107 frame too', () => {
    const plain = decodeMessage(msgpackEncode([2, 9, ['/count', 1, 5]]), messagepack, new Map()) as StateUpdate
    expect(plain.seq).toBe(9)
    expect(plain.patches).toHaveLength(1)

    const merged = decodeMessage(msgpackEncode([107, [2, 10, ['/count', 1, 6]], []]), messagepack, new Map()) as StateUpdateWithEvents
    expect(merged.type).toBe('stateUpdateWithEvents')
    expect(merged.stateUpdate.seq).toBe(10)
    expect(merged.stateUpdate.patches).toHaveLength(1)
  })

  it('is read from the JSON object', () => {
    const update = decodeMessage('{"type":"diff","seq":12,"patches":[]}', { message: 'json', stateUpdate: 'jsonObject' }) as StateUpdate
    expect(update.seq).toBe(12)
  })

  it('refuses a scalar after the opcode that is not a sequence', () => {
    expect(() => decodeMessage('[2,"x",["/count",1,5]]', opcodeJson, new Map())).toThrow(/invalid sync sequence/)
    expect(() => decodeMessage('[2,-1,["/count",1,5]]', opcodeJson, new Map())).toThrow(/invalid sync sequence/)
  })
})

describe('sync ack', () => {
  it('is [108, seq] in every message encoding', () => {
    expect(encodeSyncAck(42, 'json')).toBe('[108,42]')
    expect(encodeSyncAck(42, 'opcodeJsonArray')).toBe('[108,42]')
    expect(msgpackDecode(encodeSyncAck(70000, 'messagepack') as Uint8Array)).toEqual([108, 70000])
  })

  it('refuses a sequence that is not a non-negative safe integer', () => {
    expect(() => encodeSyncAck(-1, 'json')).toThrow(/Invalid sync sequence/)
    expect(() => encodeSyncAck(1.5, 'json')).toThrow(/Invalid sync sequence/)
  })
})
