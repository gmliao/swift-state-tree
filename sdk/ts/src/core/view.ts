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
import { IVec2, IVec3, Angle, Position2, Velocity2, Acceleration2 } from './deterministic-math'
import type { ProtocolSchema, SchemaDef, SchemaProperty } from '../codegen/schema'

export interface ViewOptions {
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
  logger?: Logger
  /**
   * Schema definition for type information.
   * If provided, used to determine types for DeterministicMath conversions (Position2, IVec2, etc.)
   * instead of relying on heuristic checks.
   */
  schema?: ProtocolSchema
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
  private schema?: ProtocolSchema
  private stateTypeName?: string

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
    this.schema = options?.schema
    this.onStateUpdate = options?.onStateUpdate
    this.onSnapshot = options?.onSnapshot
    this.onTransportMessageCallback = options?.onTransportMessage
    this.onStateUpdateMessageCallback = options?.onStateUpdateMessage
    this.onSnapshotMessageCallback = options?.onSnapshotMessage
    this.onErrorCallback = options?.onError
    
    // Schema is required for accurate type checking
    if (!this.schema) {
      throw new Error('Schema is required for StateTreeView. Please provide schema in ViewOptions.')
    }
    
    // Extract state type name from schema
    const colonIndex = landID.indexOf(':')
    const landType = colonIndex > 0 ? landID.substring(0, colonIndex) : landID
    const landDef = this.schema.lands[landType]
    if (!landDef) {
      throw new Error(`Land "${landType}" not found in schema. Available lands: ${Object.keys(this.schema.lands).join(', ')}`)
    }
    if (!landDef.stateType) {
      throw new Error(`Land "${landType}" does not have stateType defined in schema`)
    }
    this.stateTypeName = landDef.stateType
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
   * Send an event
   * Extracts fixed-point integers from DeterministicMath class instances (Position2, IVec2, etc.)
   * via toJSON(), or converts plain objects with float values to fixed-point.
   */
  sendEvent(eventType: string, payload: any): void {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    // Extract fixed-point integers from DeterministicMath class instances, or convert float plain objects
    const encodedPayload = this.encodeSnapshotValue(payload)
    const message = createEventMessage(this.landID, eventType, encodedPayload, true)
    try {
      this.runtime.sendRawMessage(message)
      this.logger.info(`Event sent [${eventType}]: ${JSON.stringify(encodedPayload)}`)
    } catch (error) {
      this.logger.error(`Failed to send event message: ${error}`)
    }
  }

  /**
   * Send an action
   * Extracts fixed-point integers from DeterministicMath class instances (Position2, IVec2, etc.)
   * via toJSON(), or converts plain objects with float values to fixed-point.
   */
  async sendAction(actionType: string, payload: any): Promise<any> {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    return new Promise((resolve, reject) => {
      const requestID = generateRequestID('action')
      // Extract fixed-point integers from DeterministicMath class instances, or convert float plain objects
      const encodedPayload = this.encodeSnapshotValue(payload)
      const message = createActionMessage(requestID, this.landID, actionType, encodedPayload)

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
        this.logger.info(`Action sent [${actionType}]: ${JSON.stringify(encodedPayload)}`)
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
   * Note: This should be called by runtime.removeView(), not directly.
   * If called directly, it will clean up the view but won't remove it from runtime.
   */
  destroy(): void {
    // Don't call runtime.removeView() here to avoid infinite recursion
    // The runtime.removeView() will call this method, so we just clean up
    this.actionCallbacks.clear()
    this.actionRejectCallbacks.clear()
    this.joinCallbacks.clear()
    this.eventHandlers.clear()
    this.currentState = {}
    this.isJoined = false
  }
  
  /**
   * Internal method to remove this view from runtime
   * Called by runtime.removeView()
   */
  _removeFromRuntime(): void {
    // This is a no-op now since runtime.removeView() handles the removal
    // We keep this for potential future use or API compatibility
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

        // Update landID if server returned a different one (e.g., new room created)
        // This ensures we track the actual landID the client is connected to
        if (success && payload.landID) {
          const serverLandID = payload.landID
          if (serverLandID !== this.landID) {
            this.logger.info(`LandID updated: ${this.landID} -> ${serverLandID}`)
            const oldLandID = this.landID
            this.landID = serverLandID
            // Update Runtime's view mapping if needed
            // This ensures future messages with the new landID can be routed correctly
            if ((this.runtime as any).views) {
              const views = (this.runtime as any).views as Map<string, StateTreeView>
              if (views.has(oldLandID) && !views.has(serverLandID)) {
                views.delete(oldLandID)
                views.set(serverLandID, this)
                this.logger.info(`Updated Runtime view mapping: ${oldLandID} -> ${serverLandID}`)
              }
            }
          }
        }

        const result = { 
          success, 
          playerID: payload.playerID, 
          reason: payload.reason,
          landType: payload.landType,
          landInstanceId: payload.landInstanceId,
          landID: payload.landID || this.landID  // Use server's landID or fallback to current
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
   * Encode value for sending to server
   * 
   * Extracts raw fixed-point integers from DeterministicMath class instances.
   * If value is a class instance (IVec2, Position2, Angle), uses toJSON() to get raw values.
   * If value is a plain object with float values, converts to fixed-point.
   */
  private encodeSnapshotValue(value: any): any {
    // Handle null/undefined
    if (value === null || value === undefined) return null
    
    // Handle native JSON primitives
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
      return value
    }
    
    // Handle native JSON arrays
    if (Array.isArray(value)) {
      return value.map((item: any) => this.encodeSnapshotValue(item))
    }
    
    // Handle DeterministicMath class instances
    if (value && typeof value === 'object') {
      // Check if it's a class instance with toJSON method
      if (value instanceof IVec2 || value instanceof IVec3 || value instanceof Angle) {
        return value.toJSON()
      }
      if (value instanceof Position2 || value instanceof Velocity2 || value instanceof Acceleration2) {
        return value.toJSON()
      }
      
      // With schema enforcement, all DeterministicMath types must be class instances
      // If we receive a plain object that looks like a DeterministicMath type, it's an error
      if (value.x !== undefined && value.y !== undefined && !(value instanceof IVec2) && !(value instanceof IVec3)) {
        throw new Error(`Expected IVec2 or IVec3 instance, but got plain object: ${JSON.stringify(value)}. Use class instances from deterministic-math module.`)
      }
      if (value.v !== undefined && !(value instanceof Position2) && !(value instanceof Velocity2) && !(value instanceof Acceleration2)) {
        throw new Error(`Expected Position2/Velocity2/Acceleration2 instance, but got plain object: ${JSON.stringify(value)}. Use class instances from deterministic-math module.`)
      }
      if (value.degrees !== undefined && !(value instanceof Angle)) {
        throw new Error(`Expected Angle instance, but got plain object: ${JSON.stringify(value)}. Use class instances from deterministic-math module.`)
      }
      
      // Recursively encode nested objects
      const result: Record<string, any> = {}
      for (const [key, v] of Object.entries(value)) {
        result[key] = this.encodeSnapshotValue(v)
      }
      return result
    }

    throw new Error(`Invalid value format for encoding: ${JSON.stringify(value)}`)
  }

  /**
   * Decode SnapshotValue
   * 
   * Decodes native JSON format and creates DeterministicMath class instances.
   * State stores class instances (IVec2, Position2, Angle) that automatically convert
   * fixed-point integers to floats via getters.
   * 
   * @param value - The value to decode
   * @param path - The path to this value in the state (e.g., "/players/player-1/position")
   */
  private decodeSnapshotValue(value: any, path: string = ''): any {
    // Handle null/undefined
    if (value === null || value === undefined) return null
    
    // Handle native JSON primitives
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
      return value
    }
    
    // Handle native JSON arrays
    if (Array.isArray(value)) {
      return value.map((item: any, index: number) => 
        this.decodeSnapshotValue(item, `${path}[${index}]`)
      )
    }
    
    // Handle native JSON objects: create DeterministicMath class instances
    if (value && typeof value === 'object') {
      // Use schema to determine type if available
      const typeName = this.getTypeForPath(path)
      
      // Check type using schema first, then fallback to heuristic checks
      if (typeName) {
        // Use schema type information
        if (this.isIVec2Type(typeName)) {
          // IVec2 type from schema
          return this.createIVec2Instance(value.x, value.y, true)
        }
        if (typeName === 'IVec3') {
          return this.createIVec3Instance(value.x, value.y, value.z, true)
        }
        if (this.isSemantic2Type(typeName)) {
          // Semantic2 type (Position2, Velocity2, Acceleration2) from schema
          let ivec2: IVec2
          if (value.v instanceof IVec2) {
            ivec2 = value.v
          } else {
            const vPath = path ? `${path}/v` : '/v'
            ivec2 = this.decodeSnapshotValue(value.v, vPath) as IVec2
          }
          // Default to Position2 for now (can be improved with exact type from schema)
          return new Position2(ivec2)
        }
        if (typeName === 'Angle') {
          return this.createAngleInstance(value.degrees, true)
        }
      }
      
      // Schema is required - if we reach here without a type match, log a warning
      if (!typeName) {
        this.logger.warn(`No type information found in schema for path: ${path}. Falling back to plain object.`)
      }
      
      // Recursively decode nested objects
      const result: Record<string, any> = {}
      for (const [key, v] of Object.entries(value)) {
        const childPath = path ? `${path}/${key}` : `/${key}`
        result[key] = this.decodeSnapshotValue(v, childPath)
      }
      return result
    }

    throw new Error(`Invalid SnapshotValue format: ${JSON.stringify(value)}`)
  }

  /**
   * Create IVec2 instance.
   */
  private createIVec2Instance(x: number, y: number, isFixedPoint: boolean): IVec2 {
    return new IVec2(x, y, isFixedPoint)
  }

  /**
   * Create IVec3 instance.
   */
  private createIVec3Instance(x: number, y: number, z: number, isFixedPoint: boolean): IVec3 {
    return new IVec3(x, y, z, isFixedPoint)
  }

  /**
   * Create Angle instance.
   */
  private createAngleInstance(degrees: number, isFixedPoint: boolean): Angle {
    return new Angle(degrees, isFixedPoint)
  }


  /**
   * Decode snapshot
   */
  private decodeSnapshot(values: Record<string, any>): Record<string, any> {
    const result: Record<string, any> = {}
    for (const [key, value] of Object.entries(values)) {
      const path = `/${key}`
      result[key] = this.decodeSnapshotValue(value, path)
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
          const topLevelPath = `/${key}`
          this.currentState[key] = this.decodeSnapshotValue(patch.value, topLevelPath)
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
      // applyNestedPatch now handles conversion internally, so we don't need redecodeObject
      this.applyNestedPatch(this.currentState[key], { ...patch, path: restPath }, this.currentState, key, key)
    }
  }

  /**
   * Get type information for a given path in the state.
   * Returns the type name (e.g., "Position2", "IVec2") if found in schema, or null.
   * Handles nested paths including map keys (e.g., "/players/player-1/position")
   */
  private getTypeForPath(path: string): string | null {
    // Schema is required (checked in constructor)
    if (!this.stateTypeName) {
      return null
    }

    const parts = path.split('/').filter((p: string) => p !== '')
    if (parts.length === 0) {
      return this.stateTypeName
    }

    // Start from root state type
    let currentDef: SchemaDef | undefined = this.schema.defs[this.stateTypeName]
    if (!currentDef) {
      return null
    }

    // Traverse the path
    let lastResolvedType: string | null = null
    let justProcessedMap = false
    for (let i = 0; i < parts.length; i++) {
      const part = parts[i]
      
      // If we just processed a map, this part is the map key - skip it
      if (justProcessedMap) {
        justProcessedMap = false
        continue
      }
      
      // Check if current definition has properties
      if (!currentDef?.properties) {
        // If no properties, check if it's a map (additionalProperties)
        if (currentDef?.additionalProperties) {
          if (typeof currentDef.additionalProperties === 'object' && currentDef.additionalProperties.$ref) {
            const refName: string = currentDef.additionalProperties.$ref.startsWith('#/defs/')
              ? currentDef.additionalProperties.$ref.slice('#/defs/'.length)
              : currentDef.additionalProperties.$ref
            currentDef = this.schema.defs[refName]
            if (!currentDef) {
              return null
            }
            lastResolvedType = refName
            justProcessedMap = true
            // Continue to next part (the map key itself doesn't affect the type)
            continue
          }
        }
        return null
      }

      const prop: SchemaProperty | undefined = currentDef.properties[part]
      if (!prop) {
        // Check if this is a map key (additionalProperties)
        // If currentDef has additionalProperties, this part is a map key, skip it
        if (currentDef.additionalProperties) {
          if (typeof currentDef.additionalProperties === 'object' && currentDef.additionalProperties.$ref) {
            const refName: string = currentDef.additionalProperties.$ref.startsWith('#/defs/')
              ? currentDef.additionalProperties.$ref.slice('#/defs/'.length)
              : currentDef.additionalProperties.$ref
            currentDef = this.schema.defs[refName]
            if (!currentDef) {
              return null
            }
            lastResolvedType = refName
            justProcessedMap = true
            // This part is a map key, skip it and continue to next part
            continue
          }
        }
        // Not a map key and property not found
        return null
      }

      // If this property has a $ref, resolve it
      if (prop.$ref) {
        const refName: string = prop.$ref.startsWith('#/defs/') 
          ? prop.$ref.slice('#/defs/'.length)
          : prop.$ref
        currentDef = this.schema.defs[refName]
        if (!currentDef) {
          return null
        }
        lastResolvedType = refName
        // Continue to next part if there are more parts
        continue
      } else if (prop.properties) {
        // If no $ref but has properties, treat the property itself as the definition
        currentDef = prop as SchemaDef
        lastResolvedType = null // Reset since we're using the property itself
      } else if (prop.additionalProperties && typeof prop.additionalProperties === 'object') {
        const additionalProps = prop.additionalProperties as SchemaDef
        if (additionalProps.$ref) {
          // This is a map type, resolve the value type
          const refName: string = additionalProps.$ref.startsWith('#/defs/')
            ? additionalProps.$ref.slice('#/defs/'.length)
            : additionalProps.$ref
          currentDef = this.schema.defs[refName]
          if (!currentDef) {
            return null
          }
          lastResolvedType = refName
          justProcessedMap = true
          // Continue to next part (map key)
          continue
        }
      } else {
        // Property has no $ref, no properties, and no additionalProperties
        // This means it's a primitive type or unknown
        return null
      }
    }

    // Return the last resolved type name if we resolved one via $ref
    if (lastResolvedType) {
      return lastResolvedType
    }

    // If the last definition has a $ref, resolve it
    if (currentDef?.$ref) {
      const refName = currentDef.$ref.startsWith('#/defs/')
        ? currentDef.$ref.slice('#/defs/'.length)
        : currentDef.$ref
      return refName
    }

    return null
  }

  /**
   * Check if a type name is a DeterministicMath type that uses IVec2.
   */
  private isSemantic2Type(typeName: string | null): boolean {
    if (!typeName) return false
    return ['Position2', 'Velocity2', 'Acceleration2'].includes(typeName)
  }

  /**
   * Check if a type name is IVec2.
   */
  private isIVec2Type(typeName: string | null): boolean {
    return typeName === 'IVec2'
  }

  /**
   * Apply nested patch
   */
  private applyNestedPatch(obj: any, patch: StatePatch, parent?: any, parentKey?: string, pathPrefix: string = ''): void {
    const path = patch.path
    const fullPath = pathPrefix + path
    const parts = path.split('/').filter((p: string) => p !== '')

    if (parts.length === 1) {
      const key = parts[0]
      switch (patch.op) {
        case 'replace':
        case 'add':
          // If we're updating v/x or v/y, handle specially to create IVec2 instance
          if ((key === 'x' || key === 'y') && parent && parentKey === 'v') {
            // We're updating v.x or v.y
            // obj is the v object itself (should be IVec2 instance)
            // patch.value is a fixed-point integer (e.g., 65000)
            // pathPrefix already includes '/v' since parentKey === 'v'
            
            // Use schema to verify this should be IVec2
            // pathPrefix is already the full path to 'v', so we use it directly
            const vPath = pathPrefix || '/v'
            const vType = this.getTypeForPath(vPath)
            const isIVec2 = this.isIVec2Type(vType)
            
            if (!isIVec2) {
              throw new Error(`Expected IVec2 type at path ${vPath} based on schema, but got type: ${vType}`)
            }
            
            // If obj is already an IVec2 instance, update it directly
            if (obj instanceof IVec2) {
              // Use raw value to avoid getter conversion
              if (key === 'x') {
                (obj as any)._x = patch.value
              } else {
                (obj as any)._y = patch.value
              }
            } else {
              // obj is not an IVec2 instance - this should not happen with schema enforcement
              // But we handle it gracefully by creating the instance
              if (typeof obj !== 'object' || obj === null) {
                obj = {}
              }
              obj[key] = patch.value
              
              // Check if we now have both x and y, then create IVec2 instance
              if (typeof obj.x === 'number' && typeof obj.y === 'number') {
                // Create IVec2 instance from the updated values (both are fixed-point integers)
                const ivec2 = new IVec2(obj.x, obj.y, true) // true = fixed-point integers
                // Replace parent's v property with the IVec2 instance
                // parent is the Semantic2 object (Position2, Velocity2, etc.)
                parent.v = ivec2
              } else {
                // Only one coordinate updated so far, keep as plain object temporarily
                // This will be converted to IVec2 when both x and y are set
              }
            }
          } else {
            // For other updates, use decodeSnapshotValue to create class instances
            const updatePath = pathPrefix ? `${pathPrefix}/${key}` : `/${key}`
            obj[key] = this.decodeSnapshotValue(patch.value, updatePath)
          }
          break
        case 'remove':
          delete obj[key]
          break
      }
    } else {
      const key = parts[0]
      const restPath = '/' + parts.slice(1).join('/')
      
      // If the next part is 'v' and we're updating 'x' or 'y', we need to ensure 'v' exists as an object
      const nextKey = parts[1]
      if (nextKey === 'v' && (parts[2] === 'x' || parts[2] === 'y')) {
        // We're updating v.x or v.y, ensure v exists as an object
        if (!(key in obj) || typeof obj[key] !== 'object' || obj[key] === null) {
          obj[key] = {}
        }
        if (!('v' in obj[key]) || typeof obj[key].v !== 'object' || obj[key].v === null) {
          obj[key].v = {}
        }
      } else {
        // Normal case: ensure the key exists
        if (!(key in obj) || typeof obj[key] !== 'object' || obj[key] === null) {
          obj[key] = {}
        }
      }
      
      // Pass current obj as parent, and key as parentKey for the recursive call
      const newPathPrefix = (pathPrefix ? pathPrefix + '/' : '') + key
      this.applyNestedPatch(obj[key], { ...patch, path: restPath }, obj, key, newPathPrefix)
      
      // After applying nested patch, if we updated 'v', ensure it's an IVec2 instance
      // This handles the case where we updated v.x or v.y and need to recreate the IVec2 instance
      if (key === 'v' && typeof obj.v === 'object' && obj.v !== null && typeof obj.v.x === 'number' && typeof obj.v.y === 'number') {
        // Check if this is an IVec2 type based on schema
        const vPath = fullPath.endsWith('/v') ? fullPath : fullPath + '/v'
        const vType = this.getTypeForPath(vPath)
        const isIVec2 = this.isIVec2Type(vType)
        
        // Schema is required - use schema type information
        if (isIVec2 && !(obj.v instanceof IVec2)) {
          // IVec2 is always fixed-point from server
          obj.v = new IVec2(obj.v.x, obj.v.y, true)
        }
      }
      
      // Also check if we're inside a Semantic2 type (position, velocity, etc.) and need to ensure v is IVec2
      // This handles cases where the parent object itself is a Semantic2 type
      if (parent && parentKey && typeof obj === 'object' && obj !== null && 'v' in obj && typeof obj.v === 'object' && obj.v !== null && typeof obj.v.x === 'number' && typeof obj.v.y === 'number') {
        // Check if parent object is a Semantic2 type based on schema
        const parentPath = fullPath.substring(0, fullPath.lastIndexOf('/' + key))
        const parentType = this.getTypeForPath(parentPath)
        const isSemantic2 = this.isSemantic2Type(parentType)
        
        // Schema is required - use schema type information
        if (isSemantic2 && !(obj.v instanceof IVec2)) {
          // IVec2 is always fixed-point from server
          obj.v = new IVec2(obj.v.x, obj.v.y, true)
        }
      }
    }
  }


  /**
   * Get current landID
   * 
   * Returns the actual landID the client is connected to.
   * This may differ from the initial landID if the server created a new room.
   */
  get landId(): string {
    return this.landID
  }

  /**
   * Get current landID (alias for landId getter)
   * 
   * Returns the actual landID the client is connected to.
   * This may differ from the initial landID if the server created a new room.
   */
  getCurrentLandID(): string {
    return this.landID
  }

  /**
   * Check if joined
   */
  get joined(): boolean {
    return this.isJoined
  }
}
