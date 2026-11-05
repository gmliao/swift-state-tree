/**
 * Connection lifecycle races (#143): a socket that `disconnect()` dropped or a later `connect()`
 * replaced must not touch the next connection, and overlapping connects open one socket.
 * Each interleaving is forced by holding the fake factory or delivering events by hand.
 */

import { describe, it, expect, beforeEach, vi } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { ConnectionClosedError } from './errors'
import { StateUpdateOpcode, StatePatchOpcode } from './protocol'
import { registerWebSocketFactory, type WebSocketConnection } from './websocket'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'

class FakeSocket implements WebSocketConnection {
  readyState = 0
  closed = false
  onopen: WebSocketConnection['onopen'] = null
  onclose: WebSocketConnection['onclose'] = null
  onerror: WebSocketConnection['onerror'] = null
  onmessage: WebSocketConnection['onmessage'] = null
  constructor(readonly url: string) {}
  send(): void {}
  close(): void {
    this.closed = true
  }
  open(): void {
    this.readyState = 1
    this.onopen?.({ type: 'open' })
  }
  serverClose(code = 1006, reason = ''): void {
    this.onclose?.({ type: 'close', code, reason, wasClean: false })
  }
  receive(data: string): void {
    this.onmessage?.({ type: 'message', data })
  }
}

/** A factory whose `create()` can be held until the test releases it. */
class FakeFactory {
  sockets: FakeSocket[] = []
  private held: Array<() => void> = []
  hold = false
  async create(url: string): Promise<WebSocketConnection> {
    if (this.hold) await new Promise<void>((release) => this.held.push(release))
    const socket = new FakeSocket(url)
    this.sockets.push(socket)
    return socket
  }
  release(): void {
    for (const release of this.held.splice(0)) release()
  }
  get heldCount(): number {
    return this.held.length
  }
}

/** A per-player diff whose dynamic key is a slot nobody defined: decoding it is an error. */
const undefinedSlotFrame = JSON.stringify([StateUpdateOpcode.diff, [123456, 0, StatePatchOpcode.replace, 1]])

let factory: FakeFactory

function makeRuntime(): StateTreeRuntime {
  return new StateTreeRuntime({
    transportEncoding: { message: MessageEncodingValues.opcodeJsonArray, stateUpdate: StateUpdateEncodingValues.opcodeJsonArray }
  })
}

/** Waits until the runtime has installed handlers on its `n`-th socket (a condition, not a delay). */
async function socketReady(n: number): Promise<FakeSocket> {
  await vi.waitUntil(() => factory.sockets.length >= n && factory.sockets[n - 1].onopen !== null)
  return factory.sockets[n - 1]
}

async function connectOpen(runtime: StateTreeRuntime, n: number): Promise<FakeSocket> {
  const connected = runtime.connect('ws://test/game')
  const socket = await socketReady(n)
  socket.open()
  await connected
  return socket
}

describe('connection lifecycle (#143)', () => {
  beforeEach(() => {
    factory = new FakeFactory()
    registerWebSocketFactory(factory)
  })

  it('ignores a late message, error and close from the previous socket', async () => {
    const runtime = makeRuntime()
    const oldSocket = await connectOpen(runtime, 1)
    runtime.disconnect()
    await connectOpen(runtime, 2)
    const decodeErrorsBefore = runtime.decodeErrorStats()

    oldSocket.receive(undefinedSlotFrame) // would fail to decode against the new key maps
    oldSocket.onerror?.({ type: 'error' })
    oldSocket.serverClose(1006, 'late')
    await Promise.resolve()

    expect(runtime.decodeErrorStats()).toEqual(decodeErrorsBefore)
    expect(runtime.connected).toBe(true)
  })

  it('shares one socket between overlapping connects to the same URL', async () => {
    const runtime = makeRuntime()
    const first = runtime.connect('ws://test/game')
    const second = runtime.connect('ws://test/game')
    const socket = await socketReady(1)
    socket.open()
    await expect(Promise.all([first, second])).resolves.toEqual([undefined, undefined])
    expect(factory.sockets).toHaveLength(1)
    expect(runtime.connected).toBe(true)
  })

  it('refuses a connect to another URL while one is in progress, without a second socket', async () => {
    const runtime = makeRuntime()
    const first = runtime.connect('ws://test/game')
    await expect(runtime.connect('ws://test/replay')).rejects.toThrow('Already connecting to ws://test/game')
    const socket = await socketReady(1)
    socket.open()
    await first
    expect(factory.sockets).toHaveLength(1)
  })

  it('a disconnect while the socket is being created aborts the connect and drops that socket', async () => {
    const runtime = makeRuntime()
    factory.hold = true
    const connecting = runtime.connect('ws://test/game')
    await vi.waitUntil(() => factory.heldCount === 1)
    runtime.disconnect()
    await expect(connecting).rejects.toBeInstanceOf(ConnectionClosedError)

    factory.hold = false
    factory.release()
    await vi.waitUntil(() => factory.sockets.length === 1)
    const dropped = factory.sockets[0]
    await vi.waitUntil(() => dropped.closed)
    expect(dropped.onopen).toBeNull() // never installed
    expect(runtime.connected).toBe(false)
  })

  it('a connect during the previous close: the old open and close events leave the new connection alone', async () => {
    const runtime = makeRuntime()
    const firstConnect = runtime.connect('ws://test/game')
    const oldSocket = await socketReady(1)
    runtime.disconnect() // before the old socket opened
    await expect(firstConnect).rejects.toMatchObject({ kind: 'disconnect' })

    const secondConnect = runtime.connect('ws://test/game')
    const newSocket = await socketReady(2)
    oldSocket.open() // the dropped socket's handshake completes late
    expect(runtime.connected).toBe(false)
    newSocket.open()
    await secondConnect
    oldSocket.serverClose(1000, 'closed by client')
    expect(runtime.connected).toBe(true)
    expect(oldSocket.closed).toBe(true)
  })
})
