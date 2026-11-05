/**
 * Pending joins and actions settle when no answer can arrive any more (#109): the socket closes,
 * the client disconnects, or the view is removed. Each request settles exactly once, and a view
 * from before a reconnect can neither send nor be resolved by the new connection.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { ConnectionClosedError } from './errors'
import { MessageKindOpcode } from './protocol'
import { registerWebSocketFactory, type WebSocketConnection, type WebSocketFactory } from './websocket'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'
import type { ProtocolSchema } from '../codegen/schema'

const schema: ProtocolSchema = {
  version: '0.1.0',
  schemaHash: 'test',
  defs: { DemoState: { type: 'object', properties: { round: { type: 'integer' } } } },
  lands: { demo: { stateType: 'DemoState' } }
} as ProtocolSchema

class FakeSocket implements WebSocketConnection {
  sent: Array<string | ArrayBuffer> = []
  readyState = 1
  onopen: WebSocketConnection['onopen'] = null
  onclose: WebSocketConnection['onclose'] = null
  onerror: WebSocketConnection['onerror'] = null
  onmessage: WebSocketConnection['onmessage'] = null
  send(data: string | ArrayBuffer): void {
    this.sent.push(data)
  }
  close(): void {}
  open(): void {
    this.onopen?.({ type: 'open' })
  }
  serverClose(code: number, reason: string, wasClean = false): void {
    this.onclose?.({ type: 'close', code, reason, wasClean })
  }
  receive(frame: unknown): void {
    this.onmessage?.({ type: 'message', data: JSON.stringify(frame) })
  }
  /** Request IDs of the messages sent with `opcode`, in send order. */
  requestIDs(opcode: number): string[] {
    return this.sent
      .map((data) => JSON.parse(String(data)))
      .filter((frame) => Array.isArray(frame) && frame[0] === opcode)
      .map((frame) => frame[1] as string)
  }
}

let sockets: FakeSocket[] = []
const factory: WebSocketFactory = {
  create: async () => {
    const socket = new FakeSocket()
    sockets.push(socket)
    return socket
  }
}

async function connect(runtime: StateTreeRuntime): Promise<FakeSocket> {
  const before = sockets.length
  const connected = runtime.connect('ws://test/game')
  // Wait for the runtime to create its socket (a condition, not a delay)
  await vi.waitUntil(() => sockets.length > before && sockets[sockets.length - 1].onopen !== null)
  const socket = sockets[sockets.length - 1]
  socket.open()
  await connected
  return socket
}

function makeRuntime(): StateTreeRuntime {
  return new StateTreeRuntime({
    transportEncoding: { message: MessageEncodingValues.opcodeJsonArray, stateUpdate: StateUpdateEncodingValues.opcodeJsonArray }
  })
}

/** Accepts the join sent last on `socket`, with JSON encoding. */
function acceptJoin(socket: FakeSocket): void {
  const joinRequests = socket.sent.map((d) => JSON.parse(String(d))).filter((m) => m?.kind === 'join')
  const requestID = joinRequests[joinRequests.length - 1].payload.join.requestID
  socket.onmessage?.({
    type: 'message',
    data: JSON.stringify({ kind: 'joinResponse', payload: { joinResponse: { requestID, success: true, landType: 'demo', landInstanceId: 'room-1', landID: 'demo:room-1', playerID: 'p1', encoding: 'opcodeJsonArray' } } })
  })
}

async function joinedView(runtime: StateTreeRuntime, socket: FakeSocket) {
  const view = runtime.createView('demo:room-1', { playerID: 'p1', schema })
  const joined = view.join()
  acceptJoin(socket)
  expect(await joined).toMatchObject({ success: true })
  return view
}

/** Settles `promise` into a record so a test can count how it settled. */
function track<T>(promise: Promise<T>) {
  const outcome: { resolved: T[]; rejected: unknown[] } = { resolved: [], rejected: [] }
  const done = promise.then(
    (value) => { outcome.resolved.push(value) },
    (error) => { outcome.rejected.push(error) }
  )
  return { outcome, done }
}

describe('pending requests when the connection goes away (#109)', () => {
  beforeEach(() => {
    sockets = []
    registerWebSocketFactory(factory)
  })
  afterEach(() => {
    sockets = []
  })

  it('rejects a pending join with ConnectionClosedError carrying the close code and reason', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = runtime.createView('demo:room-1', { playerID: 'p1', schema })
    const join = view.join()
    socket.serverClose(1006, 'server restart')
    const error = await join.catch((e) => e)
    expect(error).toBeInstanceOf(ConnectionClosedError)
    expect(error).toMatchObject({ name: 'ConnectionClosedError', kind: 'close', closeCode: 1006, closeReason: 'server restart', wasClean: false })
  })

  it('still resolves { success: false } when the server refuses the join', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = runtime.createView('demo:room-1', { playerID: 'p1', schema })
    const join = view.join()
    const requestID = socket.sent.map((d) => JSON.parse(String(d))).find((m) => m?.kind === 'join').payload.join.requestID
    socket.receive({ kind: 'joinResponse', payload: { joinResponse: { requestID, success: false, reason: 'room full' } } })
    expect(await join).toMatchObject({ success: false, reason: 'room full' })
  })

  it('rejects every pending action once when the socket closes', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = await joinedView(runtime, socket)
    const actions = [0, 1, 2, 3, 4].map((i) => track(view.sendAction('Move', { step: i })))
    socket.serverClose(1001, 'going away', true)
    await Promise.all(actions.map((a) => a.done))
    for (const { outcome } of actions) {
      expect(outcome.resolved).toHaveLength(0)
      expect(outcome.rejected).toHaveLength(1)
      expect(outcome.rejected[0]).toMatchObject({ kind: 'close', closeCode: 1001, wasClean: true })
    }
  })

  it('rejects pending requests on disconnect() and on removeView()', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = await joinedView(runtime, socket)
    const other = runtime.createView('demo:room-2', { playerID: 'p1', schema })
    const removedJoin = other.join()
    runtime.removeView('demo:room-2')
    expect(await removedJoin.catch((e) => e)).toMatchObject({ kind: 'viewRemoved' })

    const action = view.sendAction('Move', {})
    runtime.disconnect()
    expect(await action.catch((e) => e)).toMatchObject({ kind: 'disconnect' })
  })

  it('rejects only the action an error frame names', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = await joinedView(runtime, socket)
    const first = track(view.sendAction('Move', { step: 1 }))
    const second = track(view.sendAction('Move', { step: 2 }))
    const [firstID] = socket.requestIDs(MessageKindOpcode.action)
    socket.receive({ kind: 'error', payload: { code: 'ACTION_FAILED', message: 'bad move', details: { requestID: firstID } } })
    await first.done
    expect(first.outcome.rejected[0]).toBeInstanceOf(Error)
    expect(first.outcome.rejected[0]).not.toBeInstanceOf(ConnectionClosedError)
    expect(second.outcome.rejected).toHaveLength(0)
    socket.serverClose(1006, '')
    await second.done
    expect(second.outcome.rejected[0]).toBeInstanceOf(ConnectionClosedError)
  })

  it('settles once when a response and the close race, in either order', async () => {
    const runtime = makeRuntime()
    const socket = await connect(runtime)
    const view = await joinedView(runtime, socket)

    // Response first, then the close: resolved, never rejected.
    const answered = track(view.sendAction('Move', {}))
    const [answeredID] = socket.requestIDs(MessageKindOpcode.action)
    socket.receive([MessageKindOpcode.actionResponse, answeredID, { ok: true }])
    socket.serverClose(1006, '')
    await answered.done
    expect(answered.outcome).toEqual({ resolved: [{ ok: true }], rejected: [] })

    // Close first, then a late response for the same request: rejected, never resolved.
    const socket2 = await connect(runtime)
    const view2 = await joinedView(runtime, socket2)
    const closed = track(view2.sendAction('Move', {}))
    const [closedID] = socket2.requestIDs(MessageKindOpcode.action)
    socket2.serverClose(1006, '')
    socket2.receive([MessageKindOpcode.actionResponse, closedID, { ok: true }])
    await closed.done
    expect(closed.outcome.resolved).toHaveLength(0)
    expect(closed.outcome.rejected).toHaveLength(1)
  })

  it('after a reconnect, an old view cannot send and the stale socket leaves the new connection alone', async () => {
    const runtime = makeRuntime()
    const oldSocket = await connect(runtime)
    const oldView = await joinedView(runtime, oldSocket)
    runtime.disconnect()

    const newSocket = await connect(runtime)
    const newView = await joinedView(runtime, newSocket)
    await expect(oldView.sendAction('Move', {})).rejects.toThrow('Not joined to land')

    const pending = track(newView.sendAction('Move', {}))
    // The old socket's close arrives after the reconnect: it must not touch the new connection.
    oldSocket.serverClose(1000, 'client disconnect', true)
    expect(runtime.connected).toBe(true)
    const [newID] = newSocket.requestIDs(MessageKindOpcode.action)
    newSocket.receive([MessageKindOpcode.actionResponse, newID, { ok: true }])
    await pending.done
    expect(pending.outcome).toEqual({ resolved: [{ ok: true }], rejected: [] })
  })
})
