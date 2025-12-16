import type { TransportMessage, StateUpdate, StateSnapshot } from '../types/transport'
import { createWebSocket, type WebSocketConnection } from './websocket'
import { decodeMessage, encodeMessage } from './protocol'
import { NoOpLogger, type Logger } from './logger'
import { StateTreeView, type ViewOptions } from './view'

/**
 * StateTreeRuntime - Manages WebSocket connection and routes messages to Views
 * 
 * Responsibilities:
 * - WebSocket connection management
 * - Protocol message encoding/decoding
 * - Message routing to Views
 * - Connection lifecycle management
 */
export class StateTreeRuntime {
  private ws: WebSocketConnection | null = null
  private isConnected = false
  private views = new Map<string, StateTreeView>()
  private logger: Logger

  constructor(logger?: Logger) {
    this.logger = logger || new NoOpLogger()
  }

  /**
   * Connect to WebSocket server
   */
  async connect(url: string): Promise<void> {
    if (this.isConnected) {
      throw new Error('Already connected')
    }

    return new Promise(async (resolve, reject) => {
      this.logger.info(`Connecting to ${url}...`)

      try {
        // createWebSocket is now async (returns Promise)
        this.ws = await createWebSocket(url)

        this.setupWebSocketHandlers(resolve, reject)
      } catch (error) {
        this.logger.error(`Failed to create WebSocket: ${error}`)
        reject(error)
      }
    })
  }

  private setupWebSocketHandlers(resolve: () => void, reject: (error: any) => void): void {
    if (!this.ws) return

    this.ws.onopen = () => {
      this.isConnected = true
      this.logger.info('WebSocket connected')
      resolve()
    }

    this.ws.onerror = (event) => {
      const error = (event as any).error || new Error('WebSocket connection error')
      this.logger.error(`WebSocket error: ${error.message}`)
      reject(error)
    }

    this.ws.onclose = () => {
      this.isConnected = false
      this.logger.info('WebSocket closed')
      // Clean up all views
      this.views.clear()
    }

    this.ws.onmessage = (event) => {
      void this.handleMessage(event.data)
    }
  }

  /**
   * Disconnect from WebSocket server
   */
  disconnect(): void {
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
    this.isConnected = false
    // Clean up all views
    this.views.clear()
  }

  /**
   * Create a View for a specific land
   */
  createView(landID: string, options?: ViewOptions): StateTreeView {
    // Check if a view with the same landType already exists
    // In multiroom mode, we might create view with "demo-game" but server returns "demo-game:instanceId"
    const landType = landID.split(':')[0]
    for (const [existingLandID, existingView] of this.views.entries()) {
      const existingLandType = existingLandID.split(':')[0]
      if (existingLandType === landType) {
        // Update the existing view's landID if it's just the landType
        if (existingLandID === landType && landID !== landType) {
          // Server returned a full landID, update the view
          this.views.delete(existingLandID)
          this.views.set(landID, existingView)
          ;(existingView as any).landID = landID
          this.logger.info(`Updated existing view landID: ${existingLandID} -> ${landID}`)
          return existingView
        } else if (existingLandID === landID) {
      throw new Error(`View for land ${landID} already exists`)
        }
      }
    }

    // No existing view found, create new one
    const view = new StateTreeView(this, landID, {
      playerID: options?.playerID,
      deviceID: options?.deviceID,
      metadata: options?.metadata,
      logger: options?.logger,
      onStateUpdate: options?.onStateUpdate,
      onSnapshot: options?.onSnapshot,
      onTransportMessage: options?.onTransportMessage,
      onStateUpdateMessage: options?.onStateUpdateMessage,
      onSnapshotMessage: options?.onSnapshotMessage,
      onError: options?.onError
    })

    this.views.set(landID, view)
    return view
  }

  /**
   * Remove a View
   */
  removeView(landID: string): void {
    const view = this.views.get(landID)
    if (view) {
      view.destroy()
      this.views.delete(landID)
    }
  }

  /**
   * Send a raw message through the WebSocket
   */
  sendRawMessage(message: TransportMessage): void {
    if (!this.ws) {
      throw new Error('WebSocket not connected')
    }

    const encoded = encodeMessage(message)
    this.ws.send(encoded)
  }

  /**
   * Check if runtime is connected
   */
  get connected(): boolean {
    return this.isConnected
  }

  /**
   * Handle incoming WebSocket message
   * Routes messages to appropriate View based on landID
   */
  private async handleMessage(data: unknown): Promise<void> {
    try {
      let text: string

      if (typeof data === 'string') {
        text = data
      } else if (data instanceof ArrayBuffer) {
        text = new TextDecoder().decode(data)
      } else if (ArrayBuffer.isView(data)) {
        text = new TextDecoder().decode(data)
      } else if (typeof Blob !== 'undefined' && data instanceof Blob) {
        const arrayBuffer = await data.arrayBuffer()
        text = new TextDecoder().decode(arrayBuffer)
      } else {
        // Fallback: try to convert to string
        // This handles unexpected types as best effort
        const typeName = (data as any)?.constructor?.name ?? typeof data
        this.logger.warn(`Unexpected data type: ${typeName}, attempting to convert to string`)
        text = String(data)
      }

      const decoded = decodeMessage(text)

      // Debug: log raw message structure
      this.logger.debug(`Received message: keys=${Object.keys(decoded).join(',')}, preview=${JSON.stringify(decoded).substring(0, 200)}`)

      // Route TransportMessage to appropriate View
      if ('kind' in decoded) {
        const message = decoded as TransportMessage
        this.logger.debug(`Routing as TransportMessage: kind=${message.kind}`)
        this.routeTransportMessage(message)
        return
      }

      // Route StateUpdate to appropriate View
      if ('type' in decoded && 'patches' in decoded) {
        const update = decoded as StateUpdate
        this.logger.info(`📥 Received StateUpdate: type=${update.type}, patches=${update.patches.length}`)
        // StateUpdate doesn't have landID, so we need to route to all views
        // or find a way to determine which view it belongs to
        // For now, route to all views (they will ignore if not relevant)
        for (const view of this.views.values()) {
          view.handleStateUpdate(update)
        }
        return
      }

      // Route StateSnapshot to appropriate View
      if ('values' in decoded) {
        const snapshot = decoded as StateSnapshot
        this.logger.info(`📥 Received StateSnapshot: fields=${Object.keys(snapshot.values).length}`)
        // StateSnapshot doesn't have landID, route to all views
        for (const view of this.views.values()) {
          view.handleSnapshot(snapshot)
        }
        return
      }

      this.logger.warn(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
    } catch (error) {
      this.logger.error(`Failed to parse message: ${error}`)
    }
  }

  /**
   * Route TransportMessage to appropriate View
   */
  private routeTransportMessage(message: TransportMessage): void {
    // Extract landID from message payload
    let landID: string | undefined

    const payload = message.payload as any

    // Try to extract landID from different message types
    if (payload.action?.landID) {
      landID = payload.action.landID
    } else if (payload.join?.landID) {
      landID = payload.join.landID
    } else if (payload.joinResponse?.landID) {
      landID = payload.joinResponse.landID
    } else if (payload.event?.landID) {
      landID = payload.event.landID
    } else if (message.kind === 'error') {
      // For error messages, try to extract landID from error details
      const errorPayload = payload.error || payload
      const details = errorPayload.details || {}
      landID = details.landID
    }

    if (landID) {
      let view = this.views.get(landID)
      
      // If exact match not found, try to match by landType (for multiroom mode)
      // e.g., if landID is "demo-game:abc123" and we have view for "demo-game"
      if (!view && this.views.size > 0) {
        const landType = landID.split(':')[0]
        for (const [viewLandID, candidateView] of this.views.entries()) {
          const viewLandType = viewLandID.split(':')[0]
          if (viewLandType === landType) {
            view = candidateView
            // Update view's internal landID to match server's actual landID
            if (view && (view as any).landID !== landID) {
              (view as any).landID = landID
              // Update the views map to use the new landID as key
              this.views.delete(viewLandID)
              this.views.set(landID, view)
              this.logger.info(`Updated view landID mapping: ${viewLandID} -> ${landID}`)
            }
            break
          }
        }
      }
      
      if (view) {
        view.handleTransportMessage(message)
      } else {
        // Fallback: route to all views if no exact or landType match found
        // This ensures messages are not lost and CLI doesn't hang
        if (this.views.size > 0) {
          // Only log as debug to avoid noise, but always route to prevent message loss
          this.logger.debug(`No exact view match for landID: ${landID}, routing to all views (${this.views.size}) as fallback`)
          for (const view of this.views.values()) {
            view.handleTransportMessage(message)
          }
        } else {
          this.logger.warn(`No view found for landID: ${landID} (no views available)`)
        }
      }
    } else {
      // No landID in message, try to route to all views or handle globally
      // For error messages, always route to all views so they can handle errors
      // even if requestID extraction fails
      if (message.kind === 'error') {
        const errorPayload = message.payload as any
        // Always route error messages to all views
        // This ensures errors are properly handled even if requestID extraction fails
        if (this.views.size > 0) {
          for (const view of this.views.values()) {
            view.handleTransportMessage(message)
          }
        } else {
          // Log as global error only if no views exist (for debugging)
          // This can happen if error occurs before view is created
          this.logger.error(`Global error (no views): ${JSON.stringify(errorPayload)}`)
          
          // Try to extract requestID and see if we can match it to a pending action
          // This is a fallback for errors that occur before view creation
          const nestedError = errorPayload.error || errorPayload
          const details = nestedError.details || {}
          const requestID = details.requestID
          if (requestID) {
            this.logger.warn(`Error has requestID but no views exist: ${requestID}`)
          }
        }
      } else {
        // Unknown message without landID, route to all views
        for (const view of this.views.values()) {
          view.handleTransportMessage(message)
        }
      }
    }
  }
}
