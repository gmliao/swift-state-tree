/**
 * The generated composable's connection lifecycle (#143), against the real SDK runtime over a
 * fake socket: a disconnect during connect or join stops the connect, a close while joining is
 * seen, and overlapping connects share one socket. Interleavings are forced by holding the
 * socket factory or delivering socket events by hand.
 */

import { describe, it, expect, beforeEach, afterEach, vi } from 'vitest'
import { registerWebSocketFactory, ConnectionClosedError, type WebSocketConnection } from '@swiftstatetree/sdk/core'
import { useCounter } from '../../generated/counter/useCounter'

class FakeSocket implements WebSocketConnection {
  sent: Array<string | ArrayBuffer> = []
  readyState = 0
  onopen: WebSocketConnection['onopen'] = null
  onclose: WebSocketConnection['onclose'] = null
  onerror: WebSocketConnection['onerror'] = null
  onmessage: WebSocketConnection['onmessage'] = null
  send(data: string | ArrayBuffer): void {
    this.sent.push(data)
  }
  close(): void {}
  open(): void {
    this.readyState = 1
    this.onopen?.({ type: 'open' })
  }
  serverClose(code = 1006, reason = 'gone'): void {
    this.onclose?.({ type: 'close', code, reason, wasClean: false })
  }
  get joinSent(): boolean {
    return this.sent.some((data) => String(data).includes('"join"'))
  }
}

class FakeFactory {
  sockets: FakeSocket[] = []
  hold = false
  private held: Array<() => void> = []
  async create(): Promise<WebSocketConnection> {
    if (this.hold) await new Promise<void>((release) => this.held.push(release))
    const socket = new FakeSocket()
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

let factory: FakeFactory

/** Waits until the runtime has installed handlers on its `n`-th socket (a condition, not a delay). */
async function socketReady(n: number): Promise<FakeSocket> {
  return await vi.waitUntil(() => {
    const socket = factory.sockets[n - 1]
    return socket && socket.onopen !== null ? socket : undefined
  })
}

describe('useCounter connection lifecycle (#143)', () => {
  beforeEach(() => {
    factory = new FakeFactory()
    registerWebSocketFactory(factory)
    vi.spyOn(console, 'error').mockImplementation(() => {})
  })
  afterEach(async () => {
    await useCounter().disconnect()
    vi.restoreAllMocks()
  })

  it('a disconnect during connect stops it, and the next connect is not silently skipped', async () => {
    const counter = useCounter()
    factory.hold = true
    const connecting = counter.connect({ wsUrl: 'ws://test/game/counter' })
    await vi.waitUntil(() => factory.heldCount === 1)
    await counter.disconnect()
    factory.hold = false
    factory.release()
    await expect(connecting).rejects.toBeInstanceOf(ConnectionClosedError)
    expect(counter.isConnecting.value).toBe(false)
    expect(counter.isConnected.value).toBe(false)
    expect(counter.tree.value).toBeNull()

    const again = counter.connect({ wsUrl: 'ws://test/game/counter' })
    const socket = await socketReady(2)
    expect(counter.isConnecting.value).toBe(true)
    socket.open()
    await vi.waitUntil(() => socket.joinSent)
    socket.serverClose()
    await expect(again).rejects.toBeInstanceOf(ConnectionClosedError)
  })

  it('a close while joining is seen: the connect rejects, lastError is set, and nothing is left connecting', async () => {
    const counter = useCounter()
    const connecting = counter.connect({ wsUrl: 'ws://test/game/counter' })
    const socket = await socketReady(1)
    socket.open()
    await vi.waitUntil(() => socket.joinSent)
    socket.serverClose(1006, 'server restart')
    await expect(connecting).rejects.toBeInstanceOf(ConnectionClosedError)
    expect(counter.lastError.value).toBe('Connection closed while joining')
    expect(counter.isConnecting.value).toBe(false)
    expect(counter.isConnected.value).toBe(false)
    expect(counter.isJoined.value).toBe(false)
  })

  it('overlapping connects share one attempt and one socket', async () => {
    const counter = useCounter()
    const first = counter.connect({ wsUrl: 'ws://test/game/counter' })
    const second = counter.connect({ wsUrl: 'ws://test/game/counter' })
    const socket = await socketReady(1)
    socket.open()
    await vi.waitUntil(() => socket.joinSent)
    socket.serverClose()
    await expect(first).rejects.toBeInstanceOf(ConnectionClosedError)
    await expect(second).rejects.toBeInstanceOf(ConnectionClosedError)
    expect(factory.sockets).toHaveLength(1)
  })
})
