import { describe, expect, it } from 'vitest'
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
})
