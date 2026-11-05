/**
 * Why a pending request was settled without a server answer (#109).
 * - `close`: the WebSocket closed (server restart, network loss, a close from the server).
 * - `disconnect`: the client called `runtime.disconnect()`.
 * - `viewRemoved`: the view was removed (`runtime.removeView()`) or destroyed.
 */
export type ConnectionClosedKind = 'close' | 'disconnect' | 'viewRemoved'

export interface ConnectionClosedDetails {
  closeCode?: number
  closeReason?: string
  wasClean?: boolean
}

/**
 * Rejects every `join()` and `sendAction()` still waiting for its response when the connection
 * closes or the view goes away. A server that refuses a join still resolves `join()` with
 * `{ success: false, reason }`; this error means no answer can arrive any more.
 */
export class ConnectionClosedError extends Error {
  readonly kind: ConnectionClosedKind
  /** WebSocket close code, when `kind` is `close`. */
  readonly closeCode?: number
  /** WebSocket close reason, when `kind` is `close`. */
  readonly closeReason?: string
  /** Whether the WebSocket closed cleanly, when `kind` is `close`. */
  readonly wasClean?: boolean

  constructor(kind: ConnectionClosedKind, details: ConnectionClosedDetails = {}) {
    super(ConnectionClosedError.messageFor(kind, details))
    this.name = 'ConnectionClosedError'
    this.kind = kind
    this.closeCode = details.closeCode
    this.closeReason = details.closeReason
    this.wasClean = details.wasClean
    Object.setPrototypeOf(this, ConnectionClosedError.prototype)
  }

  private static messageFor(kind: ConnectionClosedKind, details: ConnectionClosedDetails): string {
    switch (kind) {
      case 'close':
        return `Connection closed before a response (code=${details.closeCode ?? 'unknown'}, reason=${details.closeReason || 'none'})`
      case 'disconnect':
        return 'Disconnected before a response'
      case 'viewRemoved':
        return 'View removed before a response'
    }
  }
}
