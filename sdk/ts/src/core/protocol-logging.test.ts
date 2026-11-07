import { afterEach, describe, expect, it, vi } from 'vitest'
import { decodeMessage, eventFieldOrder, EventDirection, MessageKindOpcode, setProtocolLogger } from './protocol'
import type { Logger } from './logger'

// Decoding writes nothing to the console unless a protocol logger is set: a client decodes every
// frame, and a console write per compressed event payload is a cost every client paid (a
// reconstructing load client wrote 1.5 million such lines in one run).

/** An event whose payload is compressed to an array, as the server sends it. */
const compressedEvent = () => JSON.stringify([MessageKindOpcode.event, EventDirection.fromServer, 'Shoot', [3, 4], null])

describe('protocol logging', () => {
  afterEach(() => {
    setProtocolLogger(undefined)
    eventFieldOrder.delete('Shoot')
    vi.restoreAllMocks()
  })

  it('decodes a compressed event payload without writing to the console by default', () => {
    eventFieldOrder.set('Shoot', ['x', 'y'])
    const spies = (['log', 'debug', 'info', 'warn', 'error'] as const).map((m) => vi.spyOn(console, m).mockImplementation(() => {}))
    const decoded = decodeMessage(compressedEvent()) as any
    expect(decoded.payload.fromServer).toMatchObject({ type: 'Shoot', payload: { x: 3, y: 4 } })
    for (const spy of spies) expect(spy).not.toHaveBeenCalled()
  })

  it('sends the decode debug line to the protocol logger when one is set', () => {
    eventFieldOrder.set('Shoot', ['x', 'y'])
    const debug = vi.fn()
    const logger: Logger = { debug, info: vi.fn(), warn: vi.fn(), error: vi.fn() }
    const log = vi.spyOn(console, 'log').mockImplementation(() => {})
    setProtocolLogger(logger)
    decodeMessage(compressedEvent())
    expect(debug).toHaveBeenCalledWith(`COMPRESSED_PAYLOAD: Decoding array payload for event 'Shoot' (Length: 2)`)
    expect(log).not.toHaveBeenCalled()
    // Unset, it goes quiet again.
    setProtocolLogger(undefined)
    decodeMessage(compressedEvent())
    expect(debug).toHaveBeenCalledTimes(1)
  })
})
