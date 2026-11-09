/**
 * Sync acks (#332): with `syncSequence` negotiated the runtime acks the last applied sequence as
 * `[108, seq]`, on a timer and from the apply path once an interval has passed, and at once after
 * a firstSync or a resync. No ack goes out before the first sequenced update.
 */
import { describe, it, expect, vi, afterEach } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { StateUpdateFeatures } from './protocol'

const schema = {
  version: '1.0.0',
  lands: { 'test-land': { stateType: 'TestState' } },
  defs: { TestState: { type: 'object', properties: { score: { type: 'integer' } } } }
} as any

function setup() {
  vi.useFakeTimers()
  const runtime = new StateTreeRuntime({
    transportEncoding: { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray' },
    ackIntervalMs: 1000
  })
  runtime.createView('test-land', { schema } as any)
  const sent: unknown[] = []
  ;(runtime as any).ws = { send: (data: unknown) => sent.push(data), close: () => {} }
  ;(runtime as any).isConnected = true
  runtime.updateStateUpdateFeatures([StateUpdateFeatures.syncSequence])
  const frame = (opcode: number, seq: number) => (runtime as any).handleMessage(JSON.stringify([opcode, seq, ['/score', 1, seq]]))
  return { runtime, sent, frame }
}

afterEach(() => {
  vi.useRealTimers()
})

describe('sync acks', () => {
  it('sends nothing before the first sequenced update, then acks a firstSync at once', async () => {
    const { runtime, sent, frame } = setup()
    vi.advanceTimersByTime(3000)
    expect(sent).toEqual([])
    await frame(1, 5)
    expect(sent).toEqual(['[108,5]'])
    runtime.disconnect()
  })

  it('acks on the timer even when the value has not changed', async () => {
    const { runtime, sent, frame } = setup()
    await frame(1, 5)
    sent.length = 0
    vi.advanceTimersByTime(1000)
    vi.advanceTimersByTime(1000)
    expect(sent).toEqual(['[108,5]', '[108,5]'])
    runtime.disconnect()
  })

  it('acks from the apply path once an interval has passed, without the timer', async () => {
    const { runtime, sent, frame } = setup()
    await frame(1, 5)
    sent.length = 0
    // A throttled timer: stop it, as a hidden tab would.
    clearInterval((runtime as any).ackTimer)
    await frame(2, 6)
    expect(sent).toEqual([])
    vi.setSystemTime(Date.now() + 1000)
    await frame(2, 7)
    expect(sent).toEqual(['[108,7]'])
    runtime.disconnect()
  })

  it('acks a resync at once, and stops and resets on disconnect', async () => {
    const { runtime, sent, frame } = setup()
    await frame(1, 5)
    await frame(3, 9)
    expect(sent).toEqual(['[108,5]', '[108,9]'])
    runtime.disconnect()
    expect((runtime as any).lastAppliedSeq).toBeUndefined()
    sent.length = 0
    vi.advanceTimersByTime(5000)
    expect(sent).toEqual([])
  })

  it('sends no acks without the feature', async () => {
    vi.useFakeTimers()
    const runtime = new StateTreeRuntime({ transportEncoding: { message: 'opcodeJsonArray', stateUpdate: 'opcodeJsonArray' } })
    runtime.createView('test-land', { schema } as any)
    const sent: unknown[] = []
    ;(runtime as any).ws = { send: (data: unknown) => sent.push(data), close: () => {} }
    await (runtime as any).handleMessage(JSON.stringify([1, ['/score', 1, 1]]))
    vi.advanceTimersByTime(3000)
    expect(sent).toEqual([])
    runtime.disconnect()
  })
})
