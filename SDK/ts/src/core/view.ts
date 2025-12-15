import type {
  TransportMessage,
  StateUpdate,
  StateSnapshot,
  StatePatch,
  TransportJoinResponsePayload,
  TransportActionResponsePayload,
  TransportEventPayload,
  ErrorPayload
} from '../types/transport'
import { StateTreeRuntime } from './runtime'
import { createJoinMessage, createActionMessage, createEventMessage, generateRequestID } from './protocol'
import { NoOpLogger, type Logger } from './logger'

export interface ViewOptions {
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
  logger?: Logger
  /**
   * Called when the decoded application state changes.
   * This receives a plain JavaScript object representing the current state.
   */
  onStateUpdate?: (state: Record<string, any>) => void
  /**
   * Called when a raw StateSnapshot message is received from the server.
   */
  onSnapshot?: (snapshot: StateSnapshot) => void
  /**
   * Called for every raw TransportMessage routed to this view.
   * Useful for higher‑level logging or inspection.
   */
  onTransportMessage?: (message: TransportMessage) => void
  /**
   * Called for every raw StateUpdate routed to this view,
   * before internal patch application.
   */
  onStateUpdateMessage?: (update: StateUpdate) => void
  /**
   * Called for every raw StateSnapshot routed to this view,
   * before internal snapshot decoding.
   */
  onSnapshotMessage?: (snapshot: StateSnapshot) => void
  /**
   * Called when an SDK‑level error occurs that is related to this view
   * (transport error, action error, join error, etc).
   */
  onError?: (error: Error, context?: { code?: string; details?: any; source: string }) => void
}

/**
 * StateTreeView - Represents a view of a StateTree for a specific land
 * 
 * Responsibilities:
 * - State synchronization (Snapshot, StateUpdate, Patch)
 * - Action/Event handling
 * - State querying
 * - Error handling and callback management
 */
export class StateTreeView {
  private landID: string
  private currentState: Record<string, any> = {}
  private isJoined = false
  private actionCallbacks = new Map<string, (response: any) => void>()
  private actionRejectCallbacks = new Map<string, (error: Error) => void>()
  private joinCallbacks = new Map<string, (result: { success: boolean; playerID?: string; reason?: string; landType?: string; landInstanceId?: string; landID?: string }) => void>()
  private eventHandlers = new Map<string, Set<(payload: any) => void>>()
  private logger: Logger
  private playerID?: string
  private deviceID?: string
  private metadata?: Record<string, any>
  private onStateUpdate?: (state: Record<string, any>) => void
  private onSnapshot?: (snapshot: StateSnapshot) => void
  private onTransportMessageCallback?: (message: TransportMessage) => void
  private onStateUpdateMessageCallback?: (update: StateUpdate) => void
  private onSnapshotMessageCallback?: (snapshot: StateSnapshot) => void
  private onErrorCallback?: (error: Error, context?: { code?: string; details?: any; source: string }) => void

  constructor(
    private runtime: StateTreeRuntime,
    landID: string,
    options?: ViewOptions
  ) {
    this.landID = landID
    this.logger = options?.logger || new NoOpLogger()
    this.playerID = options?.playerID
    this.deviceID = options?.deviceID
    this.metadata = options?.metadata
    this.onStateUpdate = options?.onStateUpdate
    this.onSnapshot = options?.onSnapshot
    this.onTransportMessageCallback = options?.onTransportMessage
    this.onStateUpdateMessageCallback = options?.onStateUpdateMessage
    this.onSnapshotMessageCallback = options?.onSnapshotMessage
    this.onErrorCallback = options?.onError
  }

  /**
   * Join the land
   * 
   * Parses landID as "landType:instanceId" or treats entire string as landType if no colon.
   * For single-room mode: landID is the landType, landInstanceId is null
   * For multi-room mode: landID format is "landType:instanceId"
   */
  async join(): Promise<{ success: boolean; playerID?: string; reason?: string; landType?: string; landInstanceId?: string; landID?: string }> {
    if (!this.runtime.connected) {
      throw new Error('Runtime not connected')
    }

    return new Promise((resolve) => {
      const requestID = generateRequestID('join')
      
      // Parse landID as "landType:instanceId" or treat as landType
      const colonIndex = this.landID.indexOf(':')
      const landType = colonIndex > 0 ? this.landID.substring(0, colonIndex) : this.landID
      const landInstanceId = colonIndex > 0 ? this.landID.substring(colonIndex + 1) : null
      
      const message = createJoinMessage(requestID, landType, landInstanceId, {
        playerID: this.playerID,
        deviceID: this.deviceID,
        metadata: this.metadata
      })

      this.joinCallbacks.set(requestID, resolve)
      try {
        this.runtime.sendRawMessage(message)
        this.logger.info(`Join request sent: landType=${landType}, landInstanceId=${landInstanceId ?? 'null'}`)
      } catch (error) {
        this.logger.error(`Failed to send join message: ${error}`)
        if (this.onErrorCallback) {
          const err = new Error(`Failed to send join message: ${String(error)}`)
          this.onErrorCallback(err, { source: 'join' })
        }
        resolve({ success: false, reason: `Failed to send: ${error}` })
      }
    })
  }

  /**
   * Send an action
   */
  async sendAction(actionType: string, payload: any): Promise<any> {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    return new Promise((resolve, reject) => {
      const requestID = generateRequestID('action')
      const message = createActionMessage(requestID, this.landID, actionType, payload)

      // Store resolve callback
      this.actionCallbacks.set(requestID, (response: any) => {
        // Check if response indicates an error
        if (response && typeof response === 'object' && 'error' in response) {
          const error = response.error
          const errorMessage = error?.message || error?.code || 'Action failed'
          reject(new Error(errorMessage))
        } else {
          resolve(response)
        }
      })
      
      // Store reject callback separately for error messages
      this.actionRejectCallbacks.set(requestID, reject)
      
      try {
        this.runtime.sendRawMessage(message)
        this.logger.info(`Action sent [${actionType}]: ${JSON.stringify(payload)}`)
      } catch (error: any) {
        this.actionCallbacks.delete(requestID)
        this.actionRejectCallbacks.delete(requestID)
        const err = new Error(`Failed to send action: ${error?.message || error}`)
        if (this.onErrorCallback) {
          this.onErrorCallback(err, { source: 'action' })
        }
        reject(err)
      }
    })
  }

  /**
   * Send an event
   */
  sendEvent(eventType: string, payload: any): void {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    const message = createEventMessage(this.landID, eventType, payload, true)
    try {
      this.runtime.sendRawMessage(message)
      this.logger.info(`Event sent [${eventType}]: ${JSON.stringify(payload)}`)
    } catch (error) {
      this.logger.error(`Failed to send event message: ${error}`)
    }
  }

  /**
   * Subscribe to server events
   */
  onServerEvent(eventType: string, handler: (payload: any) => void): () => void {
    if (!this.eventHandlers.has(eventType)) {
      this.eventHandlers.set(eventType, new Set())
    }
    this.eventHandlers.get(eventType)!.add(handler)

    // Return unsubscribe function
    return () => {
      const handlers = this.eventHandlers.get(eventType)
      if (handlers) {
        handlers.delete(handler)
        if (handlers.size === 0) {
          this.eventHandlers.delete(eventType)
        }
      }
    }
  }

  /**
   * Get current state
   */
  getState(): Record<string, any> {
    return { ...this.currentState }
  }

  /**
   * Destroy the view
   */
  destroy(): void {
    this.runtime.removeView(this.landID)
    this.actionCallbacks.clear()
    this.actionRejectCallbacks.clear()
    this.joinCallbacks.clear()
    this.eventHandlers.clear()
    this.currentState = {}
    this.isJoined = false
  }

  /**
   * Handle TransportMessage (called by Runtime)
   */
  handleTransportMessage(message: TransportMessage): void {
    // Surface raw transport message to caller for logging/inspection
    if (this.onTransportMessageCallback) {
      this.onTransportMessageCallback(message)
    }

    switch (message.kind) {
      case 'joinResponse': {
        const payloadObj = message.payload as any
        const payload = payloadObj.joinResponse || payloadObj

        const success = payload.success === true
        this.isJoined = success

        const result = { 
          success, 
          playerID: payload.playerID, 
          reason: payload.reason,
          landType: payload.landType,
          landInstanceId: payload.landInstanceId,
          landID: payload.landID
        }

        if (payload.requestID) {
          const callback = this.joinCallbacks.get(payload.requestID)
          if (callback) {
            callback(result)
            this.joinCallbacks.delete(payload.requestID)
            return
          }
        }

        // Fallback: try first callback
        if (this.joinCallbacks.size > 0) {
          const firstEntry = this.joinCallbacks.entries().next().value
          if (firstEntry) {
            const [requestID, callback] = firstEntry
            callback(result)
            this.joinCallbacks.delete(requestID)
          }
        }
        break
      }

      case 'actionResponse': {
        const payloadObj = message.payload as any
        const payload = payloadObj.actionResponse || payloadObj
        const callback = this.actionCallbacks.get(payload.requestID)
        if (callback) {
          callback(payload.response)
          this.actionCallbacks.delete(payload.requestID)
          this.actionRejectCallbacks.delete(payload.requestID)
        } else {
          this.logger.warn(`No callback found for action response: ${payload.requestID}`)
        }
        break
      }

      case 'event': {
        const payloadObj = message.payload as any
        const payload = payloadObj.event || payloadObj
        if (payload.event?.fromServer) {
          const eventData = payload.event.fromServer.event
          const handlers = this.eventHandlers.get(eventData.type)
          if (handlers) {
            handlers.forEach(handler => handler(eventData.payload))
          }
          this.logger.info(`Server event [${eventData.type}]: ${JSON.stringify(eventData.payload)}`)
        } else if (payload.event?.fromClient) {
          const eventData = payload.event.fromClient.event
          this.logger.info(`Client event echo [${eventData.type}]: ${JSON.stringify(eventData.payload)}`)
        }
        break
      }

      case 'error': {
        const payload = message.payload as any
        let errorPayload: ErrorPayload
        
        // Handle multiple error formats:
        // 1. Direct: {code: "...", message: "...", details: {...}}
        // 2. Nested: {error: {code: "...", message: "...", details: {...}}}
        if (payload && 'code' in payload && 'message' in payload) {
          errorPayload = payload as ErrorPayload
        } else if (payload && typeof payload === 'object' && 'error' in payload) {
          errorPayload = payload.error as ErrorPayload
        } else {
          errorPayload = { code: 'UNKNOWN_ERROR', message: 'Unknown error format' }
        }

        // Extract error details - handle nested structure
        // Swift sends: {error: {code: "...", message: "...", details: {requestID: "..."}}}
        const code = errorPayload.code || 'UNKNOWN_ERROR'
        const errorMessage = errorPayload.message || 'Unknown error occurred'
        const details = errorPayload.details || {}
        const requestID = details.requestID as string | undefined
        
        // Debug: log error details to help diagnose routing issues
        this.logger.debug(`Processing error: code=${code}, requestID=${requestID || 'none'}, callbacks=${this.actionRejectCallbacks.size}`)
        this.logger.error(`Error [${code}]: ${errorMessage}`, details)

        // Notify higher-level error callback for logging/inspection
        const baseError = new Error(`Error [${code}]: ${errorMessage}`)
        ;(baseError as any).code = code
        ;(baseError as any).details = details
        if (this.onErrorCallback) {
          this.onErrorCallback(baseError, { code, details, source: 'transport' })
        }

        // Check if this is an action-related error
        if (requestID) {
          const actionRejectCallback = this.actionRejectCallbacks.get(requestID)
          if (actionRejectCallback) {
            const error = new Error(`Action failed [${code}]: ${errorMessage}`)
            ;(error as any).code = code
            ;(error as any).details = details
            if (this.onErrorCallback) {
              this.onErrorCallback(error, { code, details, source: 'action' })
            }
            actionRejectCallback(error)
            this.actionCallbacks.delete(requestID)
            this.actionRejectCallbacks.delete(requestID)
            return
          } else {
            // Log warning if requestID exists but no callback found
            this.logger.warn(`Error with requestID but no callback found: ${requestID}`)
          }
        } else {
          // Log warning if no requestID found in error
          this.logger.warn(`Error without requestID: code=${code}, message=${errorMessage}`)
        }

        // Check if this is a join-related error
        // JOIN_ errors should always try to resolve join callbacks
        if (code.startsWith('JOIN_')) {
          // Try to find matching join callback by requestID first
          if (requestID) {
            const callback = this.joinCallbacks.get(requestID)
            if (callback) {
              callback({ success: false, reason: errorMessage })
              this.joinCallbacks.delete(requestID)
              return
            }
          }
          
          // Fallback: use first callback if available (for cases where requestID doesn't match)
          if (this.joinCallbacks.size > 0) {
            const firstEntry = this.joinCallbacks.entries().next().value
            if (firstEntry) {
              const [requestID, callback] = firstEntry
              callback({ success: false, reason: errorMessage })
              this.joinCallbacks.delete(requestID)
              return
            }
          }
          
          // Log warning if no callback found for join error
          this.logger.warn(`Join error [${code}] but no callback found: ${errorMessage}`)
        } else if (requestID && this.joinCallbacks.has(requestID)) {
          // If requestID matches a join callback, treat it as join error
          const callback = this.joinCallbacks.get(requestID)
          if (callback) {
            callback({ success: false, reason: errorMessage })
            this.joinCallbacks.delete(requestID)
            return
          }
        }
        break
      }

      default:
        this.logger.warn(`Unknown message kind: ${message.kind}`)
    }
  }

  /**
   * Handle StateUpdate (called by Runtime)
   */
  handleStateUpdate(update: StateUpdate): void {
    // Surface raw StateUpdate to caller for logging/inspection
    if (this.onStateUpdateMessageCallback) {
      this.onStateUpdateMessageCallback(update)
    }

    if (update.type === 'noChange') {
      return
    }

    const patchCount = update.patches.length
    this.logger.info(`State update [${update.type}]: ${patchCount} patches`)

    for (const patch of update.patches) {
      this.applyPatch(patch)
    }

    if (update.type === 'firstSync') {
      this.logger.info('First sync completed')
    }

    // Notify state update callback
    if (this.onStateUpdate) {
      this.onStateUpdate({ ...this.currentState })
    }
  }

  /**
   * Handle StateSnapshot (called by Runtime)
   */
  handleSnapshot(snapshot: StateSnapshot): void {
    // Surface raw StateSnapshot to caller for logging/inspection
    if (this.onSnapshotMessageCallback) {
      this.onSnapshotMessageCallback(snapshot)
    }

    this.logger.info('Initial snapshot received')
    this.currentState = this.decodeSnapshot(snapshot.values)

    // Notify snapshot callback
    if (this.onSnapshot) {
      this.onSnapshot(snapshot)
    }

    // Also notify state update callback
    if (this.onStateUpdate) {
      this.onStateUpdate({ ...this.currentState })
    }
  }

  /**
   * Decode SnapshotValue
   */
  private decodeSnapshotValue(value: any): any {
    if (value === null || value === undefined) return null
    if (typeof value !== 'object') return value

    if ('type' in value) {
      const type = value.type
      if (type === 'null') return null
      if (!('value' in value)) {
        throw new Error(`Invalid SnapshotValue: type "${type}" requires "value" field`)
      }
      const val = value.value

      switch (type) {
        case 'bool':
        case 'int':
        case 'double':
        case 'string':
          return val
        case 'array':
          if (Array.isArray(val)) {
            return val.map((item: any) => this.decodeSnapshotValue(item))
          }
          throw new Error(`Invalid SnapshotValue array: expected array, got ${typeof val}`)
        case 'object':
          if (val && typeof val === 'object') {
            const result: Record<string, any> = {}
            for (const [key, v] of Object.entries(val)) {
              result[key] = this.decodeSnapshotValue(v)
            }
            return result
          }
          throw new Error(`Invalid SnapshotValue object: expected object, got ${typeof val}`)
        default:
          throw new Error(`Unknown SnapshotValue type: ${type}`)
      }
    }

    throw new Error(`Invalid SnapshotValue format: ${JSON.stringify(value)}`)
  }

  /**
   * Decode snapshot
   */
  private decodeSnapshot(values: Record<string, any>): Record<string, any> {
    const result: Record<string, any> = {}
    for (const [key, value] of Object.entries(values)) {
      result[key] = this.decodeSnapshotValue(value)
    }
    return result
  }

  /**
   * Apply patch to state
   */
  private applyPatch(patch: StatePatch): void {
    const path = patch.path
    if (!path.startsWith('/')) {
      this.logger.error(`Invalid patch path: ${path}`)
      return
    }

    const parts = path.split('/').filter((p: string) => p !== '')
    if (parts.length === 0) {
      this.logger.error(`Empty patch path: ${path}`)
      return
    }

    const key = parts[0]
    const restPath = '/' + parts.slice(1).join('/')

    if (parts.length === 1) {
      // Top-level property
      switch (patch.op) {
        case 'replace':
        case 'add':
          this.currentState[key] = this.decodeSnapshotValue(patch.value)
          break
        case 'remove':
          delete this.currentState[key]
          break
      }
    } else {
      // Nested property
      if (!(key in this.currentState) || typeof this.currentState[key] !== 'object' || this.currentState[key] === null) {
        this.currentState[key] = {}
      }
      this.applyNestedPatch(this.currentState[key], { ...patch, path: restPath })
    }
  }

  /**
   * Apply nested patch
   */
  private applyNestedPatch(obj: any, patch: StatePatch): void {
    const path = patch.path
    const parts = path.split('/').filter((p: string) => p !== '')

    if (parts.length === 1) {
      const key = parts[0]
      switch (patch.op) {
        case 'replace':
        case 'add':
          obj[key] = this.decodeSnapshotValue(patch.value)
          break
        case 'remove':
          delete obj[key]
          break
      }
    } else {
      const key = parts[0]
      const restPath = '/' + parts.slice(1).join('/')
      if (!(key in obj) || typeof obj[key] !== 'object' || obj[key] === null) {
        obj[key] = {}
      }
      this.applyNestedPatch(obj[key], { ...patch, path: restPath })
    }
  }

  /**
   * Get landID
   */
  get landId(): string {
    return this.landID
  }

  /**
   * Check if joined
   */
  get joined(): boolean {
    return this.isJoined
  }
}
