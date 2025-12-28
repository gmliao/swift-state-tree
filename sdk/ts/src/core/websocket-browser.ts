/**
 * Browser WebSocket implementation
 * Wraps the native browser WebSocket API
 */
import type { WebSocketConnection, WebSocketOptions, WebSocketEvent, WebSocketCloseEvent, WebSocketMessageEvent } from './websocket.js'
import { WebSocketReadyState } from './websocket.js'

export class BrowserWebSocket implements WebSocketConnection {
  private ws: WebSocket
  public onopen: ((event: WebSocketEvent) => void) | null = null
  public onclose: ((event: WebSocketCloseEvent) => void) | null = null
  public onerror: ((event: WebSocketEvent) => void) | null = null
  public onmessage: ((event: WebSocketMessageEvent) => void) | null = null

  constructor(url: string, options?: WebSocketOptions) {
    this.ws = new WebSocket(url, options?.protocols)

    if (options?.binaryType) {
      this.ws.binaryType = options.binaryType
    } else {
      this.ws.binaryType = 'arraybuffer'
    }

    this.ws.onopen = (event) => {
      if (this.onopen) {
        this.onopen(event)
      }
    }

    this.ws.onclose = (event) => {
      if (this.onclose) {
        this.onclose({
          type: 'close',
          code: event.code,
          reason: event.reason,
          wasClean: event.wasClean
        })
      }
    }

    this.ws.onerror = (event) => {
      if (this.onerror) {
        this.onerror({ type: 'error' })
      }
    }

    this.ws.onmessage = (event) => {
      if (this.onmessage) {
        this.onmessage({
          type: 'message',
          data: event.data
        })
      }
    }
  }

  get readyState(): number {
    return this.ws.readyState
  }

  send(data: string | ArrayBuffer | Uint8Array): void {
    this.ws.send(data)
  }

  close(): void {
    this.ws.close()
  }
}
