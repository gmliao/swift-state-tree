import { describe, expect, it, vi } from 'vitest'
import { StateTreeSession, type SessionModeError, type SessionRuntime } from './session'

class MockSessionRuntime implements SessionRuntime {
  connected = false
  connectCalls: string[] = []
  disconnectCalls = 0
  failNextConnect: Error | null = null

  async connect(url: string): Promise<void> {
    this.connectCalls.push(url)
    if (this.failNextConnect) {
      const error = this.failNextConnect
      this.failNextConnect = null
      throw error
    }
    this.connected = true
  }

  disconnect(): void {
    this.disconnectCalls += 1
    this.connected = false
  }
}

describe('StateTreeSession', () => {
  it('switchToReplay disconnects/reconnects and updates mode', async () => {
    const runtime = new MockSessionRuntime()
    const session = new StateTreeSession({
      runtime,
      live: { url: 'ws://live.example/game/hero-defense' },
      replay: { url: 'ws://live.example/game/hero-defense-replay' }
    })

    await session.connectLive()
    expect(session.mode).toBe('live')
    expect(runtime.connectCalls).toEqual(['ws://live.example/game/hero-defense'])

    await session.switchToReplay()
    expect(session.mode).toBe('replay')
    expect(runtime.disconnectCalls).toBe(1)
    expect(runtime.connectCalls).toEqual([
      'ws://live.example/game/hero-defense',
      'ws://live.example/game/hero-defense-replay'
    ])
  })

  it('switchToLive reconnects using live connectSpec', async () => {
    const runtime = new MockSessionRuntime()
    const session = new StateTreeSession({
      runtime,
      live: { url: 'ws://live.example/game/hero-defense' },
      replay: { url: 'ws://live.example/game/hero-defense-replay' }
    })

    await session.connectLive()
    await session.switchToReplay()
    await session.switchToLive()

    expect(session.mode).toBe('live')
    expect(runtime.disconnectCalls).toBe(2)
    expect(runtime.connectCalls).toEqual([
      'ws://live.example/game/hero-defense',
      'ws://live.example/game/hero-defense-replay',
      'ws://live.example/game/hero-defense'
    ])
  })

  it('mode-switch errors are reported through unified error channel', async () => {
    const runtime = new MockSessionRuntime()
    const errors: SessionModeError[] = []
    const session = new StateTreeSession({
      runtime,
      live: { url: 'ws://live.example/game/hero-defense' },
      replay: { url: 'ws://live.example/game/hero-defense-replay' },
      onError: (error) => {
        errors.push(error)
      }
    })

    await session.connectLive()
    runtime.failNextConnect = new Error('replay connect failed')

    await expect(session.switchToReplay()).rejects.toThrow('replay connect failed')
    expect(session.mode).toBe('live')
    expect(errors).toHaveLength(1)
    expect(errors[0].operation).toBe('switchToReplay')
    expect(errors[0].targetMode).toBe('replay')
  })

  it('a switch racing disconnect() rejects with ConnectionClosedError and leaves the mode and connection alone (#143)', async () => {
    const runtime = new HeldSessionRuntime()
    const session = new StateTreeSession({ runtime, live: { url: 'ws://live' }, replay: { url: 'ws://replay' } })
    const errors: SessionModeError[] = []
    ;(session as any).onError = (e: SessionModeError) => errors.push(e)

    const switching = session.switchToReplay()
    await vi.waitUntil(() => runtime.pendingConnects === 1)
    session.disconnect()
    runtime.releaseConnects() // the connect completes after the disconnect
    await expect(switching).rejects.toMatchObject({ name: 'ConnectionClosedError', kind: 'disconnect' })
    expect(session.mode).toBe('live')
    expect(runtime.connected).toBe(false)
    expect(errors).toEqual([]) // a cancelled switch is not a switch error
  })

  it('cancels switches queued behind the one disconnect() interrupted', async () => {
    const runtime = new HeldSessionRuntime()
    const session = new StateTreeSession({ runtime, live: { url: 'ws://live' }, replay: { url: 'ws://replay' } })
    const first = session.switchToReplay()
    const second = session.switchToLive()
    await vi.waitUntil(() => runtime.pendingConnects === 1)
    session.disconnect()
    runtime.releaseConnects()
    await expect(first).rejects.toMatchObject({ kind: 'disconnect' })
    await expect(second).rejects.toMatchObject({ kind: 'disconnect' })
    expect(runtime.connectCalls).toEqual(['ws://replay'])
  })

  it('runs overlapping switches one at a time, in call order', async () => {
    const runtime = new HeldSessionRuntime()
    const session = new StateTreeSession({ runtime, live: { url: 'ws://live' }, replay: { url: 'ws://replay' } })
    const first = session.switchToReplay()
    const second = session.switchToLive()
    await vi.waitUntil(() => runtime.pendingConnects === 1)
    expect(runtime.connectCalls).toEqual(['ws://replay']) // the second waits for the first
    runtime.releaseConnects()
    await first
    expect(session.mode).toBe('replay')
    await vi.waitUntil(() => runtime.pendingConnects === 1)
    runtime.releaseConnects()
    await second
    expect(session.mode).toBe('live')
    expect(runtime.connectCalls).toEqual(['ws://replay', 'ws://live'])
    expect(runtime.maxConcurrentConnects).toBe(1)
  })
})

/** A runtime whose connects wait until the test releases them. */
class HeldSessionRuntime implements SessionRuntime {
  connected = false
  connectCalls: string[] = []
  maxConcurrentConnects = 0
  private held: Array<() => void> = []

  get pendingConnects(): number {
    return this.held.length
  }

  async connect(url: string): Promise<void> {
    this.connectCalls.push(url)
    this.maxConcurrentConnects = Math.max(this.maxConcurrentConnects, this.held.length + 1)
    await new Promise<void>((release) => this.held.push(release))
    this.connected = true
  }

  disconnect(): void {
    this.connected = false
  }

  releaseConnects(): void {
    for (const release of this.held.splice(0)) release()
  }
}
