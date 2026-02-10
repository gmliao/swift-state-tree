import { describe, expect, it } from 'vitest'

import { formatSince } from '../../utils/time'

describe('time utils', () => {
  it('formats undefined date as Never', () => {
    expect(formatSince(undefined, 0)).toBe('Never')
  })

  it('formats sub-second diffs as Just now', () => {
    const date = new Date(1000)
    expect(formatSince(date, 1500)).toBe('Just now')
  })

  it('formats seconds diffs', () => {
    const date = new Date(0)
    expect(formatSince(date, 12_000)).toBe('12s ago')
  })

  it('formats minutes diffs', () => {
    const date = new Date(0)
    expect(formatSince(date, 2 * 60_000 + 999)).toBe('2m ago')
  })
})
