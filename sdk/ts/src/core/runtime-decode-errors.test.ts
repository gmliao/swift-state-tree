/**
 * Decode failures are counted, split at `disconnect()`: before it they are real wire bugs (a
 * key slot used before its definition, #90); after it, frames still in flight are decoded
 * against key maps `disconnect()` already cleared (#190).
 */

import { describe, it, expect } from 'vitest'
import { StateTreeRuntime } from './runtime'
import { StateUpdateOpcode, StatePatchOpcode } from './protocol'
import { MessageEncodingValues, StateUpdateEncodingValues } from '../types/transport'

/** A per-player diff whose dynamic key is a bare slot nobody defined. */
const undefinedSlotFrame = JSON.stringify([StateUpdateOpcode.diff, [123456, 0, StatePatchOpcode.replace, 1]])

function makeRuntime(): StateTreeRuntime {
  return new StateTreeRuntime({
    transportEncoding: {
      message: MessageEncodingValues.opcodeJsonArray,
      stateUpdate: StateUpdateEncodingValues.opcodeJsonArray
    }
  })
}

describe('StateTreeRuntime decode error counts', () => {
  it('starts at zero', () => {
    expect(makeRuntime().decodeErrorStats()).toEqual({ beforeLeave: 0, afterLeave: 0, droppedAfterStrictClose: 0, samples: [] })
  })

  it('counts a frame that fails to decode before disconnect as beforeLeave', async () => {
    const runtime = makeRuntime()
    await (runtime as any).handleMessage(undefinedSlotFrame)
    const stats = runtime.decodeErrorStats()
    expect(stats.beforeLeave).toBe(1)
    expect(stats.afterLeave).toBe(0)
    expect(stats.samples[0]).toContain('before leave')
    expect(stats.samples[0]).toContain('used before definition')
  })

  it('counts a frame decoded after disconnect as afterLeave', async () => {
    const runtime = makeRuntime()
    runtime.disconnect()
    await (runtime as any).handleMessage(undefinedSlotFrame)
    expect(runtime.decodeErrorStats()).toMatchObject({ beforeLeave: 0, afterLeave: 1 })
  })

  it('keeps at most five samples while counting every error', async () => {
    const runtime = makeRuntime()
    for (let i = 0; i < 7; i += 1) {
      await (runtime as any).handleMessage(undefinedSlotFrame)
    }
    const stats = runtime.decodeErrorStats()
    expect(stats.beforeLeave).toBe(7)
    expect(stats.samples).toHaveLength(5)
  })
})
