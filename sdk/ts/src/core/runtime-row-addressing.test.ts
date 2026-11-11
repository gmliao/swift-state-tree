/**
 * The runtime with row addressing: the strict close (4013 `invalidRowEntry`), the row tables'
 * lifetimes (a fresh set per join, per connection and per resync), the join check, and the
 * resync skip per patch. Frames are delivered by hand on a fake socket; no timing.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { ConnectionClosedError } from './errors'
import { INVALID_ROW_ENTRY_CLOSE_CODE, pathIndexTableFor, truncatedCloseReason } from './protocol'
import { registerWebSocketFactory, type WebSocketConnection, type WebSocketFactory } from './websocket'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'
import type { ProtocolSchema } from '../codegen/schema'

const pathHashes: Record<string, number> = {
  round: 101,
  units: 102,
  'units.*': 103,
  'units.*.hp': 104,
  'units.*.parts': 105,
  'units.*.parts.*': 106,
  'units.*.parts.*.v': 107,
}
const table = pathIndexTableFor(pathHashes)
const idx = (pattern: string) => table.indexOf(pathHashes[pattern])

const schema = {
  version: '0.1.0',
  schemaHash: 'test',
  defs: {
    Part: { type: 'object', properties: { v: { type: 'integer' } } },
    Unit: { type: 'object', properties: { hp: { type: 'integer' }, parts: { type: 'object', additionalProperties: { $ref: '#/defs/Part' } } } },
    DemoState: {
      type: 'object',
      properties: { round: { type: 'integer' }, units: { type: 'object', additionalProperties: { $ref: '#/defs/Unit' } } },
    },
  },
  lands: { demo: { stateType: 'DemoState', pathHashes } },
} as unknown as ProtocolSchema

const rowFeatures = ['pathIndex', 'syncSequence', 'rowAddressing']

class FakeSocket implements WebSocketConnection {
  sent: Array<string | ArrayBuffer> = []
  closes: Array<{ code?: number; reason?: string }> = []
  readyState = 1
  onopen: WebSocketConnection['onopen'] = null
  onclose: WebSocketConnection['onclose'] = null
  onerror: WebSocketConnection['onerror'] = null
  onmessage: WebSocketConnection['onmessage'] = null
  send(data: string | ArrayBuffer): void {
    this.sent.push(data)
  }
  /** Throws on a reason past 123 UTF-8 bytes, as a browser's `WebSocket.close` does. */
  close(code?: number, reason?: string): void {
    if (reason !== undefined && new TextEncoder().encode(reason).length > 123) {
      throw new SyntaxError('The close reason must not be greater than 123 UTF-8 bytes')
    }
    this.closes.push({ code, reason })
  }
  open(): void {
    this.onopen?.({ type: 'open' })
  }
  serverClose(code: number, reason = ''): void {
    this.onclose?.({ type: 'close', code, reason, wasClean: true })
  }
  receive(frame: unknown): void {
    this.onmessage?.({ type: 'message', data: JSON.stringify(frame) })
  }
}

let sockets: FakeSocket[] = []
const factory: WebSocketFactory = {
  create: async () => {
    const socket = new FakeSocket()
    sockets.push(socket)
    return socket
  },
}

async function connect(runtime: StateTreeRuntime): Promise<FakeSocket> {
  const before = sockets.length
  const connected = runtime.connect('ws://test/game')
  await vi.waitUntil(() => sockets.length > before && sockets[sockets.length - 1].onopen !== null)
  const socket = sockets[sockets.length - 1]
  socket.open()
  await connected
  return socket
}

function makeRuntime(): StateTreeRuntime {
  return new StateTreeRuntime({
    transportEncoding: { message: MessageEncodingValues.opcodeJsonArray, stateUpdate: StateUpdateEncodingValues.opcodeJsonArray },
  })
}

/** Answers the join sent last on `socket`. */
function answerJoin(socket: FakeSocket, joinResponse: Record<string, unknown>): void {
  const joins = socket.sent.map((d) => JSON.parse(String(d))).filter((m) => m?.kind === 'join')
  const requestID = joins[joins.length - 1].payload.join.requestID
  socket.receive({
    kind: 'joinResponse',
    payload: { joinResponse: { requestID, landType: 'demo', landInstanceId: 'room-1', landID: 'demo:room-1', playerID: 'p1', encoding: 'opcodeJsonArray', ...joinResponse } },
  })
}

async function join(runtime: StateTreeRuntime, socket: FakeSocket, features = rowFeatures) {
  const onError = vi.fn()
  const view = runtime.createView('demo:room-1', { playerID: 'p1', schema, onError })
  const joined = view.join()
  answerJoin(socket, { success: true, stateUpdateFeatures: features })
  expect(await joined).toMatchObject({ success: true })
  return { view, onError }
}

/** Lets the runtime's async message handler finish. */
const settle = () => new Promise<void>((resolve) => setTimeout(resolve, 0))

const create = (slot: number, generation: number, key: string, value: unknown = { hp: 1, parts: {} }) =>
  [idx('units.*'), slot, 6, generation, null, key, value]

describe('the strict close (4013 invalidRowEntry)', () => {
  beforeEach(() => {
    sockets = []
    registerWebSocketFactory(factory)
  })

  it('closes with 4013, tells each view, drops later frames, and does not rejoin', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const { view, onError } = await join(runtime, socket)
    const onDisconnect = vi.fn()
    runtime.onDisconnect(onDisconnect)
    socket.receive([1, 1, create(0, 0, 'a')])
    await settle()

    // A column on slot 1, which nothing bound.
    socket.receive([2, 2, [idx('units.*.hp'), [1], 8, [5]]])
    // Queued behind it on the same connection: not applied.
    socket.receive([2, 3, [idx('units.*.hp'), [0], 8, [9]]])
    await settle()

    expect(socket.closes).toEqual([{ code: INVALID_ROW_ENTRY_CLOSE_CODE, reason: 'row entry: Row entry on unbound slot 1 of units.*.hp' }])
    expect(onError).toHaveBeenCalledTimes(1)
    expect(onError.mock.calls[0][1]).toEqual({ code: 'INVALID_ROW_ENTRY', details: { rule: 'Row entry on unbound slot 1 of units.*.hp' }, source: 'decode' })
    expect(view.getState()).toMatchObject({ units: { a: { hp: 1 } } })
    expect(runtime.decodeErrorStats()).toMatchObject({ beforeLeave: 1, droppedAfterStrictClose: 1 })

    // The close lands: views are destroyed with the code, the app is told, and nothing reconnects.
    const destroyed = vi.spyOn(view, 'destroy')
    socket.serverClose(INVALID_ROW_ENTRY_CLOSE_CODE, 'row entry: Row entry on unbound slot 1 of units.*.hp')
    expect(destroyed).toHaveBeenCalledTimes(1)
    expect(onDisconnect).toHaveBeenCalledWith(INVALID_ROW_ENTRY_CLOSE_CODE, expect.any(String), true)
    await settle()
    expect(sockets).toHaveLength(1)
    expect(runtime.connected).toBe(false)
  })

  it('rejects pending requests with a ConnectionClosedError carrying 4013', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const { view } = await join(runtime, socket)
    const pending = view.sendAction('Noop', {}).catch((error: unknown) => error)
    socket.receive([2, 1, [idx('units.*'), 0, 7]])
    await settle()
    socket.serverClose(INVALID_ROW_ENTRY_CLOSE_CODE)
    const error = await pending
    expect(error).toBeInstanceOf(ConnectionClosedError)
    expect((error as ConnectionClosedError).closeCode).toBe(INVALID_ROW_ENTRY_CLOSE_CODE)
  })

  it('only counts a violation decoded after disconnect()', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    await join(runtime, socket)
    runtime.disconnect()
    // A frame received before disconnect() whose decode runs after it (#190).
    await (runtime as any).handleMessage(JSON.stringify([2, 1, [idx('units.*'), 0, 7]]))
    expect(socket.closes).toEqual([{ code: undefined, reason: undefined }])
    expect(runtime.decodeErrorStats()).toMatchObject({ beforeLeave: 0, afterLeave: 1 })
  })

  it('keeps dropping and continuing for every other decode error', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const { view } = await join(runtime, socket)
    // A dynamic key slot nobody defined.
    socket.receive([2, 1, [idx('units.*.hp'), 42, 1, 5]])
    socket.receive([2, 2, [idx('round'), null, 1, 7]])
    await settle()
    expect(socket.closes).toEqual([])
    expect(view.getState()).toMatchObject({ round: 7 })
  })

  it('cuts the close reason to 123 UTF-8 bytes at a character boundary', () => {
    const rule = `Row entry on unbound slot 0 of ${'單位'.repeat(40)}.*.hp`
    const reason = truncatedCloseReason(`row entry: ${rule}`)
    const bytes = new TextEncoder().encode(reason).length
    expect(bytes).toBeLessThanOrEqual(123)
    expect(bytes).toBeGreaterThan(120)
    expect(`row entry: ${rule}`.startsWith(reason)).toBe(true)
    expect(truncatedCloseReason('short')).toBe('short')
  })

  it('closes without throwing when the rule names a long non-ASCII path', async () => {
    const long = '單位'.repeat(40)
    const hashes = { [long]: 201, [`${long}.*`]: 202, [`${long}.*.hp`]: 203 }
    const longSchema = {
      ...schema,
      defs: { S: { type: 'object', properties: { [long]: { type: 'object', additionalProperties: { type: 'object' } } } } },
      lands: { demo: { stateType: 'S', pathHashes: hashes } },
    } as unknown as ProtocolSchema
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = runtime.createView('demo:room-1', { playerID: 'p1', schema: longSchema })
    const joined = view.join()
    answerJoin(socket, { success: true, stateUpdateFeatures: rowFeatures })
    await joined
    const leaf = pathIndexTableFor(hashes).indexOf(203)
    socket.receive([2, 1, [leaf, [0], 9]])
    await settle()
    expect(socket.closes).toHaveLength(1)
    expect(socket.closes[0].code).toBe(INVALID_ROW_ENTRY_CLOSE_CODE)
    expect(new TextEncoder().encode(socket.closes[0].reason!).length).toBeLessThanOrEqual(123)
  })
})

describe('row tables: a fresh set per join and per connection', () => {
  beforeEach(() => {
    sockets = []
    registerWebSocketFactory(factory)
  })

  it('a rejoin on the same socket takes the new land\'s creates for the old slots', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const first = await join(runtime, socket)
    socket.receive([1, 1, create(0, 0, 'a')])
    await settle()
    expect(first.view.getState()).toMatchObject({ units: { a: { hp: 1 } } })

    // The land goes away; the app joins again on the same socket.
    runtime.removeView('demo:room-1')
    const second = await join(runtime, socket)
    socket.receive([1, 1, create(0, 0, 'b', { hp: 2, parts: {} })])
    await settle()
    expect(socket.closes).toEqual([])
    expect(second.onError).not.toHaveBeenCalled()
    expect(second.view.getState()).toMatchObject({ units: { b: { hp: 2 } } })
  })

  it('a refused join leaves the row tables as they are', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const { view } = await join(runtime, socket)
    socket.receive([1, 1, create(0, 0, 'a')])
    await settle()

    const other = runtime.createView('demo:room-2', { playerID: 'p1', schema })
    const refused = other.join()
    answerJoin(socket, { success: false, reason: 'joinAlreadyJoined', landID: 'demo:room-2' })
    expect(await refused).toMatchObject({ success: false })

    // Slot 0 is still bound: a column on it applies.
    socket.receive([2, 2, [idx('units.*.hp'), [0], 8, [6]]])
    await settle()
    expect(socket.closes).toEqual([])
    expect(view.getState()).toMatchObject({ units: { a: { hp: 6 } } })
  })

  it('a new connection starts with empty row tables', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    await join(runtime, socket)
    socket.receive([1, 1, create(0, 0, 'a')])
    await settle()
    runtime.disconnect()

    const next = await connect(runtime)
    const { view } = await join(runtime, next)
    next.receive([1, 1, create(0, 0, 'a')])
    await settle()
    expect(next.closes).toEqual([])
    expect(view.getState()).toMatchObject({ units: { a: { hp: 1 } } })
  })

  it('refuses a join response naming rowAddressing without pathIndex, and closes with 4013', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const onError = vi.fn()
    const view = runtime.createView('demo:room-1', { playerID: 'p1', schema, onError })
    const joined = view.join()
    answerJoin(socket, { success: true, stateUpdateFeatures: ['syncSequence', 'rowAddressing'] })
    expect(await joined).toMatchObject({ success: false, reason: expect.stringContaining('rowAddressing without pathIndex') })
    expect(socket.closes).toEqual([{ code: INVALID_ROW_ENTRY_CLOSE_CODE, reason: 'row entry: rowAddressing without pathIndex' }])
    expect(onError.mock.calls[0][1]).toMatchObject({ source: 'decode', details: { rule: 'rowAddressing without pathIndex' } })
  })
})

describe('the resync skip per patch, with rowAddressing', () => {
  beforeEach(() => {
    sockets = []
    registerWebSocketFactory(factory)
  })

  async function resynced(rows: unknown[][], round = 1) {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const { view } = await join(runtime, socket)
    socket.receive([1, 1, [idx('round'), null, 1, 0]])
    await settle()
    socket.receive([3, 9, [idx('round'), null, 1, round], ...rows])
    await settle()
    return { runtime, socket, view }
  }

  it("applies a today's-form entry below a slot-addressed root in the frame at the resync's sequence", async () => {
    // Committed `units/a/parts/x/v = 1` in the snapshot; the live value, 2, follows at seq 9.
    const { socket, view } = await resynced([create(0, 0, 'a', { hp: 1, parts: { x: { v: 1 } } })])
    socket.receive([107, [2, 9, [idx('units.*.parts.*.v'), [[0, 'a'], [1, 'x']], 1, 2]], []])
    await settle()
    expect(view.getState()).toMatchObject({ units: { a: { parts: { x: { v: 2 } } } } })
  })

  it("applies the frame's row entries, and skips a patch under a root without rows", async () => {
    const { socket, view } = await resynced([create(0, 0, 'a')], 4)
    socket.receive([107, [2, 9, [idx('round'), null, 1, 4], [idx('units.*.hp'), [0], 8, [3]]], []])
    await settle()
    expect(view.getState()).toMatchObject({ round: 4, units: { a: { hp: 3 } } })
    // The round patch was skipped (the snapshot already held it); a different value shows it.
    socket.receive([107, [2, 9, [idx('round'), null, 1, 99]], []])
    await settle()
    expect(view.getState()).toMatchObject({ round: 4 })
  })

  it('applies the creates of a table that was empty at the resync', async () => {
    const { socket, view } = await resynced([])
    socket.receive([107, [2, 9, create(0, 0, 'a', { hp: 5, parts: {} })], []])
    await settle()
    expect(view.getState()).toMatchObject({ units: { a: { hp: 5 } } })
  })

  it('uses the roots bound at the resync, not the live tables', async () => {
    const { socket, view } = await resynced([create(0, 0, 'a')])
    // Every bound row is deleted first; a today's-form entry below the root still applies.
    socket.receive([107, [2, 9, [idx('units.*'), 0, 7], [idx('units.*'), [5, 'b'], 1, { hp: 3, parts: {} }]], []])
    await settle()
    expect(view.getState()).toMatchObject({ units: { b: { hp: 3 } } })
    expect((view.getState() as any).units.a).toBeUndefined()
  })
})
