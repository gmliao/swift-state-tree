import WebSocket from 'ws'
import chalk from 'chalk'
import type {
  TransportMessage,
  StateUpdate,
  StateSnapshot,
  StatePatch,
  TransportJoinPayload,
  TransportActionPayload,
  TransportEventPayload,
  ErrorPayload
} from './types'

export class SwiftStateTreeClient {
  private ws: WebSocket | null = null
  private isConnected = false
  private isJoined = false
  private currentState: Record<string, any> = {}
  private requestIDCounter = 0
  private actionCallbacks = new Map<string, (response: any) => void>()
  private joinCallbacks = new Map<string, (result: { success: boolean; playerID?: string; reason?: string; landType?: string; landInstanceId?: string; landID?: string }) => void>()

  constructor(
    private url: string,
    private landID: string,
    private playerID?: string,
    private deviceID?: string,
    private metadata?: Record<string, any>
  ) {}

  connect(): Promise<void> {
    return new Promise((resolve, reject) => {
      console.log(chalk.blue(`🔌 Connecting to ${this.url}...`))

      this.ws = new WebSocket(this.url)

      this.ws.on('open', () => {
        this.isConnected = true
        console.log(chalk.green('✅ WebSocket connected'))
        resolve()
      })

      this.ws.on('error', (error) => {
        console.error(chalk.red(`❌ WebSocket error: ${error.message}`))
        reject(error)
      })

      this.ws.on('close', () => {
        this.isConnected = false
        this.isJoined = false
        console.log(chalk.yellow('🔌 WebSocket closed'))
      })

      this.ws.on('message', (data: WebSocket.Data) => {
        this.handleMessage(data)
      })
    })
  }

  private handleMessage(data: WebSocket.Data) {
    try {
      const text = typeof data === 'string' ? data : data.toString()
      const json = JSON.parse(text)

      // Check for TransportMessage with kind field
      if (json && typeof json === 'object' && 'kind' in json) {
        const message = json as TransportMessage
        this.handleTransportMessage(message)
        return
      }

      // Check for TransportMessage opcode format (array): [101-106, ...]
      if (Array.isArray(json) && json.length >= 1) {
        const firstElement = json[0]
        const isTransportMessageOpcode = typeof firstElement === 'number' && firstElement >= 101 && firstElement <= 106
        
        if (isTransportMessageOpcode) {
          // This is a TransportMessage in opcode format
          const opcodeNames: Record<number, string> = {
            101: 'join',
            102: 'joinResponse',
            103: 'event',
            104: 'action',
            105: 'actionResponse',
            106: 'error'
          }
          const messageType = opcodeNames[firstElement] || 'unknown'
          console.log(chalk.cyan(`📦 TransportMessage [${messageType}] (opcode: ${firstElement}):`))
          console.log(chalk.gray(`   Raw array (first 500 chars): ${JSON.stringify(json).substring(0, 500)}...`))
          
          // Special handling for event messages
          if (firstElement === 103 && json.length >= 4) {
            const direction = json[1] as number
            const type = json[2]
            const payload = json[3]
            const directionName = direction === 0 ? 'fromClient' : 'fromServer'
            const typeStr = typeof type === 'number' ? `opcode:${type}` : type
            console.log(chalk.cyan(`   Event: ${directionName}, type: ${typeStr}`))
            if (Array.isArray(payload)) {
              console.log(chalk.gray(`   Payload array (length: ${payload.length}):`))
              payload.forEach((item: any, index: number) => {
                const itemStr = typeof item === 'object' ? JSON.stringify(item).substring(0, 200) : String(item)
                console.log(chalk.gray(`     [${index}]: ${itemStr}${typeof item === 'object' ? '...' : ''}`))
              })
            } else {
              console.log(chalk.gray(`   Payload: ${JSON.stringify(payload).substring(0, 300)}...`))
            }
          }
          return
        }
      }
      
      // Check for StateUpdate opcode format (array): [opcode, playerID/slot, ...patches]
      if (Array.isArray(json) && json.length >= 2) {
        const opcode = json[0]
        const playerIdentifier = json[1]
        const isOpcodeFormat = typeof opcode === 'number' && (opcode === 0 || opcode === 1 || opcode === 2)
        
        if (isOpcodeFormat) {
          const opcodeNames = ['noChange', 'firstSync', 'diff']
          const opcodeName = opcodeNames[opcode] || 'unknown'
          const playerIDType = typeof playerIdentifier === 'number' ? 'playerSlot (Int)' : 'playerID (String)'
          const playerIDValue = typeof playerIdentifier === 'number' ? playerIdentifier : playerIdentifier
          const patchCount = Math.max(0, json.length - 2)
          
          console.log(chalk.cyan(`📦 Opcode StateUpdate [${opcodeName}]: ${playerIDType}=${playerIDValue}, patches=${patchCount}`))
          console.log(chalk.gray(`   Raw payload (first 200 chars): ${JSON.stringify(json).substring(0, 200)}...`))
          
          // Show first few patches for debugging
          if (patchCount > 0 && json.length > 2) {
            const patches = json.slice(2)
            const previewCount = Math.min(3, patches.length)
            console.log(chalk.gray(`   First ${previewCount} patch(es):`))
            for (let i = 0; i < previewCount; i++) {
              const patch = patches[i]
              const patchStr = Array.isArray(patch) ? JSON.stringify(patch).substring(0, 100) : String(patch).substring(0, 100)
              console.log(chalk.gray(`     [${i}]: ${patchStr}...`))
            }
          }
          return
        }
      }

      // Check for StateUpdate
      if (json && typeof json === 'object' && 'type' in json && 'patches' in json) {
        const update = json as StateUpdate
        this.handleStateUpdate(update)
        return
      }

      // Check for StateSnapshot
      if (json && typeof json === 'object' && 'values' in json) {
        const snapshot = json as StateSnapshot
        this.handleSnapshot(snapshot)
        return
      }

      // Check for error in payload.error format (fallback)
      if (json && typeof json === 'object' && 'payload' in json) {
        const payloadObj = (json as any).payload
        if (payloadObj && typeof payloadObj === 'object' && 'error' in payloadObj) {
          const errorPayload = payloadObj.error as ErrorPayload
          const errorCode = errorPayload.code || 'UNKNOWN'
          const errorMsg = errorPayload.message || 'Unknown error'
          console.log(chalk.red(`❌ Error [${errorCode}]: ${errorMsg}`))
          if (errorPayload.details) {
            console.log(chalk.gray(`   Details: ${JSON.stringify(errorPayload.details)}`))
          }
          return
        }
      }

      // Debug: print full message for unknown formats
      console.log(chalk.gray(`📨 Unknown message format:`))
      console.log(chalk.gray(JSON.stringify(json, null, 2).substring(0, 500)))
    } catch (error) {
      console.error(chalk.red(`❌ Failed to parse message: ${error}`))
    }
  }

  private handleTransportMessage(message: TransportMessage) {
    switch (message.kind) {
      case 'joinResponse': {
        // MessagePayload encodes as { "joinResponse": TransportJoinResponsePayload }
        const payloadObj = message.payload as any
        
        const payload = payloadObj.joinResponse || payloadObj // Fallback for direct format
        
        const success = payload.success === true // Explicitly check for true
        if (success) {
          this.isJoined = true
          
          // Update landID if server returned a different one (e.g., new room created)
          if (payload.landID && payload.landID !== this.landID) {
            console.log(chalk.yellow(`ℹ️  LandID updated: ${this.landID} -> ${payload.landID}`))
            this.landID = payload.landID
          }
          
          console.log(chalk.green(`✅ Join successful: playerID=${payload.playerID || 'unknown'}, landID=${this.landID}`))
        } else {
          this.isJoined = false
          console.log(chalk.red(`❌ Join failed: ${payload.reason || 'unknown reason'}`))
        }

        // Call callback if exists - try to find by requestID
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
            return // Don't continue processing
          }
        }
        
        // If no callback found by requestID, try the first one (for cases where requestID doesn't match)
        // This can happen if the server doesn't echo back the exact requestID
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
        // MessagePayload encodes as { "actionResponse": TransportActionResponsePayload }
        const payloadObj = message.payload as any
        const payload = payloadObj.actionResponse || payloadObj // Fallback for direct format
        const callback = this.actionCallbacks.get(payload.requestID)
        if (callback) {
          callback(payload.response)
          this.actionCallbacks.delete(payload.requestID)
        } else {
          console.log(chalk.cyan(`📥 Action response [${payload.requestID}]: ${JSON.stringify(payload.response)}`))
        }
        break
      }

      case 'event': {
        // Simplified structure: payload directly contains fromClient or fromServer
        const payload = message.payload as any
        if (payload.fromServer) {
          const eventData = payload.fromServer
          console.log(chalk.magenta(`📨 Server event [${eventData.type}]: ${JSON.stringify(eventData.payload)}`))
          // Debug: Show raw payload structure
          if (Array.isArray(eventData.payload)) {
            console.log(chalk.gray(`   Raw array payload (length: ${eventData.payload.length}):`))
            eventData.payload.forEach((item: any, index: number) => {
              const itemStr = typeof item === 'object' ? JSON.stringify(item).substring(0, 100) : String(item)
              console.log(chalk.gray(`     [${index}]: ${itemStr}${typeof item === 'object' ? '...' : ''}`))
            })
          }
        } else if (payload.fromClient) {
          const eventData = payload.fromClient
          console.log(chalk.blue(`📤 Client event echo [${eventData.type}]: ${JSON.stringify(eventData.payload)}`))
        }
        break
      }

      case 'error': {
        const payload = message.payload as any
        // Handle both direct ErrorPayload and wrapped in MessagePayload
        let errorPayload: ErrorPayload
        if (payload && 'code' in payload && 'message' in payload) {
          errorPayload = payload as ErrorPayload
        } else if (payload && typeof payload === 'object' && 'error' in payload) {
          errorPayload = payload.error as ErrorPayload
        } else {
          // Debug: print full payload
          console.log(chalk.yellow(`⚠️  Error payload format: ${JSON.stringify(payload, null, 2)}`))
          errorPayload = { code: 'UNKNOWN_ERROR', message: 'Unknown error format' }
        }
        
        const code = errorPayload.code || 'UNKNOWN_ERROR'
        const errorMessage = errorPayload.message || 'Unknown error occurred'
        console.log(chalk.red(`❌ Error [${code}]: ${errorMessage}`))
        if (errorPayload.details) {
          console.log(chalk.gray(`   Details: ${JSON.stringify(errorPayload.details)}`))
        }
        
        // Check if this is a join-related error
        if (code.startsWith('JOIN_')) {
          // Try to find callback by checking all callbacks
          if (this.joinCallbacks.size > 0) {
            const firstEntry = this.joinCallbacks.entries().next().value
            if (firstEntry) {
              const [requestID, callback] = firstEntry
              callback({ success: false, reason: errorMessage })
              this.joinCallbacks.delete(requestID)
            }
          }
        }
        break
      }

      default:
        console.log(chalk.gray(`📨 Message [${message.kind}]: ${JSON.stringify(message.payload).substring(0, 100)}`))
    }
  }

  private handleStateUpdate(update: StateUpdate) {
    if (update.type === 'noChange') {
      return // Ignore noChange to reduce noise
    }

    const patchCount = update.patches.length
    console.log(chalk.yellow(`🔄 State update [${update.type}]: ${patchCount} patches`))

    // Apply patches to current state
    for (const patch of update.patches) {
      this.applyPatch(patch)
    }

    if (update.type === 'firstSync') {
      console.log(chalk.green('✅ First sync completed'))
    }
  }

  private handleSnapshot(snapshot: StateSnapshot) {
    console.log(chalk.blue('📸 Initial snapshot received'))
    this.currentState = this.decodeSnapshot(snapshot.values)
    console.log(chalk.gray(`   State: ${JSON.stringify(this.currentState, null, 2).substring(0, 200)}...`))
  }

  private decodeSnapshotValue(value: any): any {
    if (value === null || value === undefined) return null
    if (typeof value === 'boolean' || typeof value === 'number' || typeof value === 'string') {
      return value
    }
    if (Array.isArray(value)) {
      return value.map((item: any) => this.decodeSnapshotValue(item))
    }
    if (value && typeof value === 'object') {
      const keys = Object.keys(value)
      const isLegacySnapshotValue =
        typeof (value as any).type === 'string' &&
        keys.every(key => key === 'type' || key === 'value')

      if (isLegacySnapshotValue) {
        const type = (value as any).type
        const legacyValue = (value as any).value
        switch (type) {
          case 'null':
            return null
          case 'bool':
          case 'int':
          case 'double':
          case 'string':
            return legacyValue
          case 'array':
            return Array.isArray(legacyValue)
              ? legacyValue.map((item: any) => this.decodeSnapshotValue(item))
              : legacyValue
          case 'object':
            if (legacyValue && typeof legacyValue === 'object') {
              const result: Record<string, any> = {}
              for (const [key, v] of Object.entries(legacyValue)) {
                result[key] = this.decodeSnapshotValue(v)
              }
              return result
            }
            return legacyValue
          default:
            throw new Error(`Unknown SnapshotValue type: ${type}`)
        }
      }

      const result: Record<string, any> = {}
      for (const [key, v] of Object.entries(value)) {
        result[key] = this.decodeSnapshotValue(v)
      }
      return result
    }

    throw new Error(`Invalid SnapshotValue format: ${JSON.stringify(value)}`)
  }

  private decodeSnapshot(values: Record<string, any>): Record<string, any> {
    const result: Record<string, any> = {}
    for (const [key, value] of Object.entries(values)) {
      result[key] = this.decodeSnapshotValue(value)
    }
    return result
  }

  private applyPatch(patch: StatePatch) {
    const path = patch.path
    if (!path.startsWith('/')) {
      console.error(chalk.red(`Invalid patch path: ${path}`))
      return
    }

    const parts = path.split('/').filter((p: string) => p !== '')
    if (parts.length === 0) {
      console.error(chalk.red(`Empty patch path: ${path}`))
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

  private applyNestedPatch(obj: any, patch: StatePatch) {
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

  async join(): Promise<{ success: boolean; playerID?: string; reason?: string; landType?: string; landInstanceId?: string; landID?: string }> {
    if (!this.isConnected) {
      throw new Error('Not connected')
    }

    return new Promise((resolve) => {
      const requestID = `join-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
      
      // Parse landID as "landType:instanceId" or treat as landType
      const colonIndex = this.landID.indexOf(':')
      const landType = colonIndex > 0 ? this.landID.substring(0, colonIndex) : this.landID
      const landInstanceId = colonIndex > 0 ? this.landID.substring(colonIndex + 1) : null
      
      // MessagePayload encodes as { "join": TransportJoinPayload }
      const message = {
        kind: 'join',
        payload: {
          join: {
            requestID,
            landType,
            landInstanceId: landInstanceId ?? null,
            playerID: this.playerID,
            deviceID: this.deviceID,
            metadata: this.metadata
          }
        }
      }

      this.joinCallbacks.set(requestID, resolve)
      this.send(message as any)
      console.log(chalk.blue(`📤 Join request sent: landType=${landType}, landInstanceId=${landInstanceId ?? 'null'}`))
    })
  }

  async sendAction(actionType: string, payload: any): Promise<any> {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    return new Promise((resolve, reject) => {
      const requestID = `action-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`

      // Encode payload to Base64
      const payloadJson = JSON.stringify(payload)
      const payloadBase64 = Buffer.from(payloadJson, 'utf-8').toString('base64')

      // Simplified structure: directly use requestID, typeIdentifier, payload in payload
      const message = {
        kind: 'action',
        payload: {
          requestID,
          typeIdentifier: actionType,
          payload: payloadBase64
        }
      }

      this.actionCallbacks.set(requestID, resolve)
      this.send(message as any)
      console.log(chalk.blue(`📤 Action sent [${actionType}]: ${JSON.stringify(payload)}`))
    })
  }

  sendEvent(eventType: string, payload: any) {
    if (!this.isJoined) {
      throw new Error('Not joined to land')
    }

    // Simplified structure: payload directly contains fromClient
    const message = {
      kind: 'event',
      payload: {
        fromClient: {
          type: eventType,
          payload: payload || {}
        }
      }
    }

    this.send(message as any)
    console.log(chalk.blue(`📤 Event sent [${eventType}]: ${JSON.stringify(payload)}`))
  }

  private send(message: any) {
    if (!this.ws || !this.isConnected) {
      throw new Error('WebSocket not connected')
    }
    this.ws.send(JSON.stringify(message))
  }

  getState(): Record<string, any> {
    return { ...this.currentState }
  }

  /**
   * Get current landID
   * 
   * Returns the actual landID the client is connected to.
   * This may differ from the initial landID if the server created a new room.
   */
  getCurrentLandID(): string {
    return this.landID
  }

  disconnect() {
    if (this.ws) {
      this.ws.close()
      this.ws = null
    }
    this.isConnected = false
    this.isJoined = false
  }
}
