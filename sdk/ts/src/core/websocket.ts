/**
 * WebSocket connection abstraction
 * Provides a unified interface for both browser and Node.js WebSocket implementations
 */
// Browser types for WebSocket events
export interface WebSocketEvent {
  type: string
}

export interface WebSocketCloseEvent extends WebSocketEvent {
  type: 'close'
  code: number
  reason: string
  wasClean: boolean
}

export interface WebSocketMessageEvent extends WebSocketEvent {
  type: 'message'
  data: string | ArrayBuffer | Blob | Uint8Array
}

export interface WebSocketConnection {
  send(data: string | ArrayBuffer | Uint8Array): void
  close(): void
  onopen: ((event: WebSocketEvent) => void) | null
  onclose: ((event: WebSocketCloseEvent) => void) | null
  onerror: ((event: WebSocketEvent) => void) | null
  onmessage: ((event: WebSocketMessageEvent) => void) | null
  readyState: number
}

export const WebSocketReadyState = {
  CONNECTING: 0,
  OPEN: 1,
  CLOSING: 2,
  CLOSED: 3
} as const

export interface WebSocketOptions {
  protocols?: string | string[]
  binaryType?: 'blob' | 'arraybuffer'
}

/**
 * WebSocket factory interface
 * Abstracts the creation of WebSocket connections for different environments
 */
export interface WebSocketFactory {
  create(url: string, options?: WebSocketOptions): Promise<WebSocketConnection>
}

// Factory registry
let registeredFactory: WebSocketFactory | null = null

/**
 * Register a custom WebSocket factory
 * Useful for providing alternative implementations (e.g., uWebSockets.js)
 */
export function registerWebSocketFactory(factory: WebSocketFactory): void {
  registeredFactory = factory
}

// Cache for factory promise to avoid repeated imports
let factoryPromise: Promise<WebSocketFactory> | null = null

/**
 * Get the appropriate WebSocket factory for the current environment
 * Auto-registers browser or Node.js factory if not already registered
 */
async function getWebSocketFactory(): Promise<WebSocketFactory> {
  // If a factory is already registered, use it
  if (registeredFactory) {
    return registeredFactory
  }

  // If factory is being loaded, wait for it
  if (factoryPromise) {
    return factoryPromise
  }

  // Check if we're in a browser environment
  const isBrowser = typeof globalThis !== 'undefined' && 
                    typeof (globalThis as any).window !== 'undefined' && 
                    typeof (globalThis as any).WebSocket !== 'undefined'
  
  factoryPromise = (async () => {
    if (isBrowser) {
      // Lazy load browser factory to avoid importing in Node.js
        const { BrowserWebSocket } = await import('./websocket-browser')
      registeredFactory = {
        create: async (url: string, options?: WebSocketOptions) => {
          return new BrowserWebSocket(url, options)
        }
      }
    } else {
      // Lazy load Node.js factory to avoid importing in browser
      const { NodeWebSocketFactory } = await import('./websocket-node')
      registeredFactory = new NodeWebSocketFactory()
    }
    return registeredFactory!
  })()

  return factoryPromise
}

/**
 * Factory function to create appropriate WebSocket implementation
 * Automatically detects environment and uses the correct factory
 * Returns a Promise to handle async initialization in Node.js
 */
export async function createWebSocket(url: string, options?: WebSocketOptions): Promise<WebSocketConnection> {
  const factory = await getWebSocketFactory()
  return factory.create(url, options)
}
