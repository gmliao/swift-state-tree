import type {
  TransportMessage,
  TransportActionPayload,
  TransportJoinPayload,
  TransportEventPayload,
  StatePatch,
  StateUpdate,
  StateSnapshot,
  TransportEncodingConfig,
  StateUpdateDecoding
} from '../types/transport'

/**
 * Encode a TransportMessage to JSON string
 */
export function encodeMessage(message: TransportMessage): string {
  return JSON.stringify(message)
}

/**
 * Decode a JSON string to TransportMessage, StateUpdate, or StateSnapshot
 */
export function decodeMessage(
  data: string,
  config?: TransportEncodingConfig
): TransportMessage | StateUpdate | StateSnapshot {
  const json = JSON.parse(data)

  if (Array.isArray(json)) {
    const decoding = resolveStateUpdateDecoding(config)
    if (decoding === 'jsonObject') {
      throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
    }
    return decodeStateUpdateArray(json)
  }

  // Check for TransportMessage with kind field
  if (json && typeof json === 'object' && 'kind' in json) {
    return json as TransportMessage
  }

  // Check for StateUpdate
  if (json && typeof json === 'object' && 'type' in json && 'patches' in json) {
    const decoding = resolveStateUpdateDecoding(config)
    if (decoding === 'opcodeJsonArray') {
      throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
    }
    return json as StateUpdate
  }

  // Check for StateSnapshot
  if (json && typeof json === 'object' && 'values' in json) {
    return json as StateSnapshot
  }

  throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
}

function resolveStateUpdateDecoding(config?: TransportEncodingConfig): StateUpdateDecoding {
  return config?.stateUpdateDecoding ?? 'auto'
}

function decodeStateUpdateArray(payload: unknown[]): StateUpdate {
  if (payload.length < 2) {
    throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
  }

  const updateType = (() => {
    switch (payload[0]) {
      case 0:
        return 'noChange' as const
      case 1:
        return 'firstSync' as const
      case 2:
        return 'diff' as const
      default:
        return null
    }
  })()

  if (!updateType) {
    throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
  }

  const patchStartIndex = (() => {
    if (payload.length >= 3 && Array.isArray(payload[2])) {
      return 2
    }
    if (payload.length === 2) {
      return 2
    }
    if (payload.length >= 3 && typeof payload[2] !== 'object') {
      return 3
    }
    return 3
  })()

  if (patchStartIndex === 2 && typeof payload[1] !== 'string') {
    throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
  }
  if (patchStartIndex === 3 && (typeof payload[1] !== 'string' || typeof payload[2] !== 'string')) {
    throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
  }

  const patches: StatePatch[] = []

  for (const entry of payload.slice(patchStartIndex)) {
    if (!Array.isArray(entry) || entry.length < 2) {
      throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
    }

    // Detect format:
    // Legacy: [path(string), op, value?]
    // PathHash: [pathHash(number), dynamicKey(string|null), op, value?]
    const firstElement = entry[0]
    const isPathHashFormat = typeof firstElement === 'number'

    let path: string
    let opCode: number
    let value: any

    if (isPathHashFormat) {
      // PathHash format: [pathHash, dynamicKey, op, value?]
      const [pathHash, dynamicKey, op, val] = entry
      
      if (typeof pathHash !== 'number') {
        throw new Error(`Invalid PathHash format: expected number, got ${typeof pathHash}`)
      }
      
      // Reconstruct path from hash + dynamicKey
      path = reconstructPath(pathHash, dynamicKey)
      opCode = op
      value = val
    } else {
      // Legacy format: [path, op, value?]
      const [pathStr, op, val] = entry
      
      if (typeof pathStr !== 'string') {
        throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
      }
      
      path = pathStr
      opCode = op
      value = val
    }

    let op: StatePatch['op']
    switch (opCode) {
      case 1:
        op = 'replace'
        break
      case 2:
        op = 'remove'
        break
      case 3:
        op = 'add'
        break
      default:
        throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
    }

    const patch: StatePatch = { path, op }
    if (op !== 'remove' && value !== undefined) {
      patch.value = value
    }
    patches.push(patch)
  }

  return { type: updateType, patches }
}

/**
 * Reconstruct full JSON Pointer path from pathHash and dynamicKey
 * Uses global pathHashReverseLookup (set during schema initialization)
 */
function reconstructPath(pathHash: number, dynamicKey: string | null): string {
  const pattern = pathHashReverseLookup.get(pathHash)
  if (!pattern) {
    throw new Error(`Unknown pathHash: ${pathHash}. Ensure schema is loaded.`)
  }
  
  // Replace wildcard with dynamic key
  if (dynamicKey !== null && pattern.includes('*')) {
    const pathPattern = pattern.replace('*', dynamicKey)
    return '/' + pathPattern.replace(/\./g, '/')
  }
  
  // No dynamic key (static path)
  return '/' + pattern.replace(/\./g, '/')
}

// Global reverse lookup table (hash → path pattern)
// Populated by View during schema initialization
export const pathHashReverseLookup = new Map<number, string>()

export interface JoinOptions {
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

/**
 * Create a join message
 * MessagePayload encodes as { "join": TransportJoinPayload }
 * 
 * @param requestID - Unique request identifier
 * @param landType - The type of Land to join (required)
 * @param landInstanceId - The specific instance to join (optional, if null a new room will be created)
 * @param options - Optional join options (playerID, deviceID, metadata)
 */
export function createJoinMessage(
  requestID: string,
  landType: string,
  landInstanceId: string | null | undefined,
  options?: JoinOptions
): TransportMessage {
  return {
    kind: 'join',
    payload: {
      join: {
        requestID,
        landType,
        landInstanceId: landInstanceId ?? null,
        playerID: options?.playerID,
        deviceID: options?.deviceID,
        metadata: options?.metadata
      }
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Create an action message
 * MessagePayload encodes as { "action": TransportActionPayload }
 */
export function createActionMessage(
  requestID: string,
  actionType: string,
  payload: any
): TransportMessage {
  // Encode payload to Base64
  const payloadJson = JSON.stringify(payload)
  let payloadBase64: string

  // Handle both browser and Node.js environments
  if (typeof Buffer !== 'undefined') {
    // Node.js environment
    payloadBase64 = Buffer.from(payloadJson, 'utf-8').toString('base64')
  } else {
    // Browser environment
    payloadBase64 = btoa(unescape(encodeURIComponent(payloadJson)))
  }

  // Simplified structure: directly use requestID, typeIdentifier, payload in payload
  return {
    kind: 'action',
    payload: {
      requestID,
      typeIdentifier: actionType,
      payload: payloadBase64
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Create an event message
 * MessagePayload encodes as { "event": TransportEventPayload }
 */
export function createEventMessage(
  eventType: string,
  payload: any,
  fromClient: boolean = true
): TransportMessage {
  // Simplified structure: directly use fromClient/fromServer in payload
  return {
    kind: 'event',
    payload: fromClient
      ? {
          fromClient: {
            type: eventType,
            payload: payload || {}
          }
        } as any
      : {
          fromServer: {
            type: eventType,
            payload: payload || {}
          }
        } as any
  }
}

/**
 * Generate a unique request ID
 */
export function generateRequestID(prefix: string = 'req'): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
}
