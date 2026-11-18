/**
 * Client frames for the server's decoder fuzz tests (#528). The Swift suite
 * `ClientFrameFuzzTests` mutates these frames, so its corpus is what this SDK sends: joins,
 * actions, client events and sync acks, each in the three message encodings, written by the
 * SDK's own encoders (`encodeMessageToFormat`, `encodeSyncAck`).
 *
 * The fixture lives at `Tests/SwiftStateTreeTransportTests/Fixtures/ClientFrames/client-frames.json`.
 * This test re-encodes every case and compares, so a change to the SDK's frames fails here
 * until the fixture is regenerated with `SST_REGENERATE_CLIENT_FRAMES=1 npx vitest run
 * src/core/client-frames-fixture.test.ts`.
 */

import { describe, it, expect } from 'vitest'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from 'fs'
import { dirname, join } from 'path'
import { fileURLToPath } from 'url'
import {
  createActionMessage,
  createEventMessage,
  createJoinMessage,
  encodeMessageToFormat,
  encodeSyncAck
} from './protocol'
import type { MessageEncoding, TransportMessage } from '../types/transport'

interface FixtureFrame {
  name: string
  kind: 'join' | 'action' | 'clientEvent' | 'syncAck'
  encoding: MessageEncoding
  /** The frame's bytes, base64 (UTF-8 text for the JSON encodings). */
  base64: string
}

const fixturePath = join(
  dirname(fileURLToPath(import.meta.url)),
  '../../../../Tests/SwiftStateTreeTransportTests/Fixtures/ClientFrames/client-frames.json'
)

const encodings: MessageEncoding[] = ['json', 'opcodeJsonArray', 'messagepack']

/** A nested payload: every JSON value kind, unicode, and two levels of containers. */
const richPayload = {
  int: 42,
  negative: -7,
  maxSafe: Number.MAX_SAFE_INTEGER,
  minSafe: Number.MIN_SAFE_INTEGER,
  fraction: 1.5,
  tiny: 5e-324,
  flag: true,
  nothing: null,
  text: 'café ✓ 🎮',
  empty: '',
  list: [1, 'two', false, null, [3, [4]], { five: 5 }],
  map: { a: { b: { c: [] } }, 'key with space': {} }
}

const messages: { name: string; kind: FixtureFrame['kind']; message: TransportMessage }[] = [
  { name: 'join-minimal', kind: 'join', message: createJoinMessage('j-1', 'demo', null) },
  {
    name: 'join-instance',
    kind: 'join',
    message: createJoinMessage('j-2', 'hero-defense', 'room-01')
  },
  {
    name: 'join-full',
    kind: 'join',
    message: createJoinMessage('j-3', 'demo', 'room-02', {
      playerID: 'player-é',
      deviceID: 'device-1',
      metadata: { name: 'Alice', level: 3, tags: ['a', 'b'], prefs: { sound: false, volume: 0.5 } }
    })
  },
  { name: 'action-empty', kind: 'action', message: createActionMessage('a-1', 'Ping', {}) },
  {
    name: 'action-scalars',
    kind: 'action',
    message: createActionMessage('a-2', 'AddGold', { amount: 100, reason: 'quest' })
  },
  { name: 'action-rich', kind: 'action', message: createActionMessage('a-3', 'Module.Rich', richPayload) },
  {
    name: 'action-positional',
    kind: 'action',
    message: createActionMessage('a-4', 'Move', [[1000, -2000], 3, 'run'])
  },
  { name: 'event-empty', kind: 'clientEvent', message: createEventMessage('Heartbeat', {}) },
  {
    name: 'event-scalars',
    kind: 'clientEvent',
    message: createEventMessage('Chat', { message: 'hello', channel: 2 })
  },
  { name: 'event-rich', kind: 'clientEvent', message: createEventMessage('Rich', richPayload) }
]

const syncAckSequences = [0, 1, 255, 65_536, Number.MAX_SAFE_INTEGER]

function toBase64(encoded: string | Uint8Array): string {
  return typeof encoded === 'string'
    ? Buffer.from(encoded, 'utf-8').toString('base64')
    : Buffer.from(encoded).toString('base64')
}

function encodeAll(): FixtureFrame[] {
  const frames: FixtureFrame[] = []
  for (const encoding of encodings) {
    for (const { name, kind, message } of messages) {
      frames.push({ name, kind, encoding, base64: toBase64(encodeMessageToFormat(message, encoding)) })
    }
    for (const seq of syncAckSequences) {
      frames.push({ name: `sync-ack-${seq}`, kind: 'syncAck', encoding, base64: toBase64(encodeSyncAck(seq, encoding)) })
    }
  }
  return frames
}

describe('client frames fixture (#528)', () => {
  it('matches what the SDK encoders write', () => {
    const frames = encodeAll()
    if (process.env.SST_REGENERATE_CLIENT_FRAMES === '1') {
      // Regenerating compares the fixture with itself: an inherited variable in CI would turn
      // the drift check off without a sign.
      if (process.env.CI) {
        throw new Error('SST_REGENERATE_CLIENT_FRAMES is set under CI; regenerate the fixture locally')
      }
      if (!existsSync(dirname(fixturePath))) mkdirSync(dirname(fixturePath), { recursive: true })
      writeFileSync(fixturePath, JSON.stringify({ frames }, null, 2) + '\n', 'utf-8')
    }
    const fixture: { frames: FixtureFrame[] } = JSON.parse(readFileSync(fixturePath, 'utf-8'))
    expect(fixture.frames).toEqual(frames)
  })
})
