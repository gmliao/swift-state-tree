import { describe, it, expect } from 'vitest'
import { readFileSync } from 'node:fs'
import { fileURLToPath } from 'node:url'
import { join, resolve } from 'node:path'
import { decodeMessage } from './protocol'
import type { StateSnapshot, StateUpdate, TransportMessage } from '../types/transport'

const fixtureDir = join(fileURLToPath(new URL('.', import.meta.url)), '../fixtures/messagepack')

function readFixture(name: string): Uint8Array {
  return readFileSync(resolve(fixtureDir, name))
}

function decodeBinaryJsonPayload(payload: unknown): any {
  if (typeof payload === 'string') {
    return JSON.parse(Buffer.from(payload, 'base64').toString('utf-8'))
  }
  if (payload instanceof Uint8Array) {
    return JSON.parse(Buffer.from(payload).toString('utf-8'))
  }
  throw new Error('Unsupported payload type')
}

describe('protocol messagepack fixtures', () => {
  it('decodes join fixture', () => {
    const data = readFixture('join.msgpack')
    const message = decodeMessage(data, 'messagepack') as TransportMessage
    expect(message.kind).toBe('join')
    const joinPayload = (message.payload as any).join
    expect(joinPayload.requestID).toBe('req-join-1')
    expect(joinPayload.landType).toBe('fixture-land')
    expect(joinPayload.landInstanceId).toBe('fixture-instance')
    expect(joinPayload.playerID).toBe('player-fixture')
    expect(joinPayload.deviceID).toBe('device-fixture')
    expect(joinPayload.metadata).toEqual({ role: 'mage', level: 7 })
  })

  it('decodes action fixture with binary payload', () => {
    const data = readFixture('action.msgpack')
    const message = decodeMessage(data, 'messagepack') as TransportMessage
    expect(message.kind).toBe('action')
    const actionPayload = (message.payload as any).action
    expect(actionPayload.requestID).toBe('req-action-1')
    expect(actionPayload.landID).toBe('fixture-land:fixture-instance')
    expect(actionPayload.action.typeIdentifier).toBe('FixtureActionPayload')
    expect(actionPayload.action.payload).toBeInstanceOf(Uint8Array)
    expect(decodeBinaryJsonPayload(actionPayload.action.payload)).toEqual({
      amount: 3,
      note: 'spin'
    })
  })

  it('decodes event fixture', () => {
    const data = readFixture('event.msgpack')
    const message = decodeMessage(data, 'messagepack') as TransportMessage
    expect(message.kind).toBe('event')
    const payload = (message.payload as any).event
    expect(payload.landID).toBe('fixture-land:fixture-instance')
    expect(payload.event.fromClient.event.type).toBe('FixtureClientEvent')
    expect(payload.event.fromClient.event.payload).toEqual({ message: 'hello', count: 2 })
  })

  it('decodes snapshot fixture', () => {
    const data = readFixture('snapshot.msgpack')
    const snapshot = decodeMessage(data, 'messagepack') as StateSnapshot
    expect(snapshot.values.round).toBe(2)
    expect(snapshot.values.active).toBe(true)
    expect(snapshot.values.players).toEqual({
      'player-1': 'Alice',
      'player-2': 'Bob'
    })
  })

  it('decodes update fixture', () => {
    const data = readFixture('update.msgpack')
    const update = decodeMessage(data, 'messagepack') as StateUpdate
    expect(update.type).toBe('diff')
    expect(update.patches).toEqual([
      { path: '/round', op: 'replace', value: 3 },
      { path: '/players/player-1', op: 'replace', value: 'Alicia' },
      { path: '/players/player-2', op: 'remove' },
      { path: '/scores', op: 'add', value: [10, 20] }
    ])
  })
})
