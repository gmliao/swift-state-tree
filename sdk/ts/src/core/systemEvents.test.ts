/**
 * Unit tests for built-in system events (e.g. ReplayTick).
 * Ensures system-level events are defined and automatically available for decoding.
 */

import { describe, it, expect } from 'vitest'
import {
  REPLAY_TICK_FIELD_ORDER,
  BUILTIN_SERVER_EVENT_NAMES,
  BUILTIN_SERVER_EVENT_FIELD_ORDER
} from './systemEvents'

describe('systemEvents', () => {
  it('defines ReplayTick field order matching Swift ReplayTickEvent', () => {
    expect(REPLAY_TICK_FIELD_ORDER).toEqual(['tickId', 'isMatch', 'expectedHash', 'actualHash'])
  })

  it('includes ReplayTick in built-in server event names', () => {
    expect(BUILTIN_SERVER_EVENT_NAMES.has('ReplayTick')).toBe(true)
  })

  it('provides built-in field order for ReplayTick for array payload decoding', () => {
    const order = BUILTIN_SERVER_EVENT_FIELD_ORDER.get('ReplayTick')
    expect(order).toBeDefined()
    expect(order).toEqual(REPLAY_TICK_FIELD_ORDER)
  })

  it('built-in events are used by protocol/view as fallback for replay', () => {
    // Protocol uses BUILTIN_SERVER_EVENT_FIELD_ORDER when event not in land schema; view skips warning for BUILTIN_SERVER_EVENT_NAMES
    expect(BUILTIN_SERVER_EVENT_FIELD_ORDER.size).toBeGreaterThanOrEqual(1)
    for (const name of BUILTIN_SERVER_EVENT_NAMES) {
      expect(BUILTIN_SERVER_EVENT_FIELD_ORDER.has(name)).toBe(true)
    }
  })
})
