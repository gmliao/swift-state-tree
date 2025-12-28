/**
 * Node.js WebSocket implementation
 * Wraps the 'ws' package WebSocket API
 */
import type { WebSocketConnection, WebSocketOptions, WebSocketEvent, WebSocketCloseEvent, WebSocketMessageEvent } from './websocket.js'
import { WebSocketReadyState } from './websocket.js'

// Cache for ws module to avoid repeated imports
let wsModulePromise: Promise<any> | null = null

/**
 * Load ws module asynchronously
 * Uses dynamic import which works in ES module environments (including tsx)
 */
async function loadWsModule(): Promise<any> {
  if (wsModulePromise) {
    return wsModulePromise
  }

  wsModulePromise = (async () => {
    try {
      // Try dynamic import first (works in most ES module environments)
      const wsModule = await import('ws')
      return wsModule.default || wsModule
    } catch (e: any) {
      // Fallback: use createRequire with process.cwd()
      // This resolves from the application's working directory
      try {
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { createRequire } = await import('module')
        // eslint-disable-next-line @typescript-eslint/no-require-imports
        const { fileURLToPath } = await import('url')
        const requireFunc = createRequire(process.cwd() + '/package.json')
        const wsModule = requireFunc('ws')
        return wsModule.default || wsModule
      } catch (e2: any) {
        const errorMsg = e2?.message || e?.message || 'Unknown error'
        throw new Error(`ws package is required for Node.js environment. Please install: npm install ws. Error: ${errorMsg}`)
      }
    }
  })()

  return wsModulePromise
}

export class NodeWebSocket implements WebSocketConnection {
  private ws: any
  public onopen: ((event: WebSocketEvent) => void) | null = null
  public onclose: ((event: WebSocketCloseEvent) => void) | null = null
  public onerror: ((event: WebSocketEvent) => void) | null = null
  public onmessage: ((event: WebSocketMessageEvent) => void) | null = null

  constructor(wsInstance: any) {
    this.ws = wsInstance
    this.setupEventHandlers()
  }

  private setupEventHandlers(): void {
    this.ws.on('open', () => {
      if (this.onopen) {
        this.onopen({ type: 'open' })
      }
    })

    this.ws.on('close', (code: number, reason: Buffer) => {
      if (this.onclose) {
        this.onclose({
          type: 'close',
          code,
          reason: reason.toString(),
          wasClean: code === 1000
        })
      }
    })

    this.ws.on('error', (_error: Error) => {
      if (this.onerror) {
        this.onerror({ type: 'error' })
      }
    })

    this.ws.on('message', (data: Buffer | string | ArrayBuffer) => {
      if (this.onmessage) {
        // Convert Buffer to string or ArrayBuffer
        let processedData: string | ArrayBuffer
        if (Buffer.isBuffer(data)) {
          // Convert Buffer to ArrayBuffer
          const arrayBuffer = new ArrayBuffer(data.length)
          const view = new Uint8Array(arrayBuffer)
          for (let i = 0; i < data.length; i++) {
            view[i] = data[i]
          }
          processedData = arrayBuffer
        } else if (data instanceof ArrayBuffer) {
          processedData = data
        } else {
          processedData = data
        }

        this.onmessage({
          type: 'message',
          data: processedData
        })
      }
    })
  }

  get readyState(): number {
    return this.ws.readyState
  }

  send(data: string | ArrayBuffer | Uint8Array): void {
    if (typeof data === 'string') {
      this.ws.send(data)
    } else {
      const buffer = data instanceof ArrayBuffer
        ? Buffer.from(data)
        : Buffer.from(data.buffer, data.byteOffset, data.byteLength)
      this.ws.send(buffer)
    }
  }

  close(): void {
    this.ws.close()
  }
}

/**
 * Node.js WebSocket factory
 * Creates Node.js WebSocket instances asynchronously (loads ws module first)
 */
export class NodeWebSocketFactory {
  async create(url: string, options?: WebSocketOptions): Promise<WebSocketConnection> {
    const WebSocketClass = await loadWsModule()
    const wsInstance = new WebSocketClass(url, options?.protocols)
    return new NodeWebSocket(wsInstance)
  }
}
