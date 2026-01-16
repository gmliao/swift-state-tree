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
import { encode as msgpackEncode, decode as msgpackDecode } from '@msgpack/msgpack'

/**
 * Encode a TransportMessage to JSON string
 */
export function encodeMessage(message: TransportMessage): string {
  return JSON.stringify(message)
}

/**
 * Encode a TransportMessage to opcode JSON array format
 * 
 * Formats:
 * - joinResponse: [105, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?]
 * - actionResponse: [102, requestID, response]
 * - error: [106, code, message, details?]
 * - action: [101, requestID, typeIdentifier, payload(object)]
 * - join: [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
 * - event: [103, direction(0=client,1=server), type, payload, rawBody?]
 */
export function encodeMessageArray(message: TransportMessage): string {
  const array: any[] = []
  
  switch (message.kind) {
    case 'joinResponse': {
      const payload = (message.payload as any).joinResponse
      if (!payload) throw new Error('Invalid joinResponse payload')
      
      array.push(105) // opcode
      array.push(payload.requestID)
      array.push(payload.success ? 1 : 0)
      
      // Optional fields - include encoding if present
      if (payload.landType != null || payload.landInstanceId != null || payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.landType ?? null)
      }
      if (payload.landInstanceId != null || payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.landInstanceId ?? null)
      }
      if (payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.playerSlot ?? null)
      }
      if (payload.encoding != null || payload.reason != null) {
        array.push(payload.encoding ?? null)
      }
      if (payload.reason != null) {
        array.push(payload.reason)
      }
      break
    }
    
    case 'actionResponse': {
      const payload = (message.payload as any).actionResponse
      if (!payload) throw new Error('Invalid actionResponse payload')
      
      array.push(102) // opcode
      array.push(payload.requestID)
      array.push(payload.response)
      break
    }
    
    case 'error': {
      const payload = message.payload as any
      if (!payload.error) throw new Error('Invalid error payload')
      
      array.push(106) // opcode
      array.push(payload.error.code)
      array.push(payload.error.message)
      if (payload.error.details != null) {
        array.push(payload.error.details)
      }
      break
    }
    
    case 'action': {
      const payload = message.payload as any
      if (!payload.requestID || !payload.typeIdentifier || !payload.payload) {
        throw new Error('Invalid action payload')
      }
      
      array.push(101) // opcode
      array.push(payload.requestID)
      array.push(payload.typeIdentifier)
      array.push(payload.payload || {}) // JSON object (same as Event payload)
      break
    }
    
    case 'join': {
      const payload = (message.payload as any).join
      if (!payload) throw new Error('Invalid join payload')
      
      array.push(104) // opcode
      array.push(payload.requestID)
      array.push(payload.landType)
      
      // Optional trailing fields
      if (payload.landInstanceId != null || payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.landInstanceId ?? null)
      }
      if (payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.playerID ?? null)
      }
      if (payload.deviceID != null || payload.metadata != null) {
        array.push(payload.deviceID ?? null)
      }
      if (payload.metadata != null) {
        array.push(payload.metadata)
      }
      break
    }
    
    case 'event': {
      const payload = message.payload as any
      const fromClient = payload.fromClient
      const fromServer = payload.fromServer
      
      array.push(103) // opcode
      
      if (fromClient) {
        array.push(0) // direction: 0 = fromClient
        array.push(fromClient.type)
        array.push(fromClient.payload || {})
        if (fromClient.rawBody != null) {
          array.push(fromClient.rawBody)
        }
      } else if (fromServer) {
        array.push(1) // direction: 1 = fromServer
        array.push(fromServer.type)
        array.push(fromServer.payload || {})
        if (fromServer.rawBody != null) {
          array.push(fromServer.rawBody)
        }
      } else {
        throw new Error('Invalid event payload: missing fromClient or fromServer')
      }
      break
    }
    
    default:
      throw new Error(`Unsupported message kind: ${message.kind}`)
  }
  
  return JSON.stringify(array)
}

/**
 * Encode a TransportMessage to MessagePack binary format
 * Uses the same array structure as encodeMessageArray but serializes with MessagePack
 * 
 * @param message - The TransportMessage to encode
 * @returns Uint8Array containing MessagePack-encoded array
 */
export function encodeMessageArrayToMessagePack(message: TransportMessage): Uint8Array {
  // Generate the same array structure as encodeMessageArray
  const array: any[] = []
  
  switch (message.kind) {
    case 'joinResponse': {
      const payload = (message.payload as any).joinResponse
      if (!payload) throw new Error('Invalid joinResponse payload')
      
      array.push(105) // opcode
      array.push(payload.requestID)
      array.push(payload.success ? 1 : 0)
      
      // Optional fields - include encoding if present
      if (payload.landType != null || payload.landInstanceId != null || payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.landType ?? null)
      }
      if (payload.landInstanceId != null || payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.landInstanceId ?? null)
      }
      if (payload.playerSlot != null || payload.encoding != null || payload.reason != null) {
        array.push(payload.playerSlot ?? null)
      }
      if (payload.encoding != null || payload.reason != null) {
        array.push(payload.encoding ?? null)
      }
      if (payload.reason != null) {
        array.push(payload.reason)
      }
      break
    }
    
    case 'actionResponse': {
      const payload = (message.payload as any).actionResponse
      if (!payload) throw new Error('Invalid actionResponse payload')
      
      array.push(102) // opcode
      array.push(payload.requestID)
      array.push(payload.response)
      break
    }
    
    case 'error': {
      const payload = message.payload as any
      if (!payload.error) throw new Error('Invalid error payload')
      
      array.push(106) // opcode
      array.push(payload.error.code)
      array.push(payload.error.message)
      if (payload.error.details != null) {
        array.push(payload.error.details)
      }
      break
    }
    
    case 'action': {
      const payload = message.payload as any
      if (!payload.requestID || !payload.typeIdentifier || !payload.payload) {
        throw new Error('Invalid action payload')
      }
      
      array.push(101) // opcode
      array.push(payload.requestID)
      array.push(payload.typeIdentifier)
      array.push(payload.payload || {}) // JSON object (same as Event payload)
      break
    }
    
    case 'join': {
      const payload = (message.payload as any).join
      if (!payload) throw new Error('Invalid join payload')
      
      array.push(104) // opcode
      array.push(payload.requestID)
      array.push(payload.landType)
      
      // Optional trailing fields
      if (payload.landInstanceId != null || payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.landInstanceId ?? null)
      }
      if (payload.playerID != null || payload.deviceID != null || payload.metadata != null) {
        array.push(payload.playerID ?? null)
      }
      if (payload.deviceID != null || payload.metadata != null) {
        array.push(payload.deviceID ?? null)
      }
      if (payload.metadata != null) {
        array.push(payload.metadata)
      }
      break
    }
    
    case 'event': {
      const payload = message.payload as any
      const fromClient = payload.fromClient
      const fromServer = payload.fromServer
      
      array.push(103) // opcode
      
      if (fromClient) {
        array.push(0) // direction: 0 = fromClient
        array.push(fromClient.type)
        array.push(fromClient.payload || {})
        if (fromClient.rawBody != null) {
          array.push(fromClient.rawBody)
        }
      } else if (fromServer) {
        array.push(1) // direction: 1 = fromServer
        array.push(fromServer.type)
        array.push(fromServer.payload || {})
        if (fromServer.rawBody != null) {
          array.push(fromServer.rawBody)
        }
      } else {
        throw new Error('Invalid event payload: missing fromClient or fromServer')
      }
      break
    }
    
    default:
      throw new Error(`Unsupported message kind: ${message.kind}`)
  }
  
  // Serialize array with MessagePack
  return msgpackEncode(array)
}

/**
 * Decode a JSON string or MessagePack binary data to TransportMessage, StateUpdate, or StateSnapshot
 */
export function decodeMessage(
  data: string | ArrayBuffer | Uint8Array,
  config?: TransportEncodingConfig,
  dynamicKeyMap?: Map<number, string>
): TransportMessage | StateUpdate | StateSnapshot {
  // Handle MessagePack binary data
  if (data instanceof ArrayBuffer || data instanceof Uint8Array) {
    try {
      // Convert ArrayBuffer to Uint8Array if needed
      const uint8Array = data instanceof ArrayBuffer ? new Uint8Array(data) : data
      const array = msgpackDecode(uint8Array) as any[]
      
      // Check if first element is a TransportMessage opcode (101-106)
      const firstElement = array[0]
      if (typeof firstElement === 'number' && firstElement >= 101 && firstElement <= 106) {
        return decodeTransportMessageArray(array)
      }
      
      // Otherwise, treat as StateUpdate opcode array (0-2)
      const decoding = resolveStateUpdateDecoding(config)
      if (decoding === 'jsonObject') {
        throw new Error(`Unknown message format: MessagePack array with opcode ${firstElement}`)
      }
      return decodeStateUpdateArray(array, dynamicKeyMap)
    } catch (error) {
      // If MessagePack decode fails, it might be JSON text in binary format
      // Try to decode as text first
      const text = new TextDecoder().decode(
        data instanceof ArrayBuffer ? new Uint8Array(data) : data
      )
      const json = JSON.parse(text)
      
      if (Array.isArray(json)) {
        const firstElement = json[0]
        if (typeof firstElement === 'number' && firstElement >= 101 && firstElement <= 106) {
          return decodeTransportMessageArray(json)
        }
        const decoding = resolveStateUpdateDecoding(config)
        if (decoding === 'jsonObject') {
          throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
        }
        return decodeStateUpdateArray(json, dynamicKeyMap)
      }
      
      if (json && typeof json === 'object' && 'kind' in json) {
        return json as TransportMessage
      }

      // JSON object StateUpdate in binary frame (server may send JSON bytes as binary)
      if (json && typeof json === 'object' && 'type' in json && 'patches' in json) {
        const decoding = resolveStateUpdateDecoding(config)
        if (decoding === 'opcodeJsonArray') {
          throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
        }
        return json as StateUpdate
      }

      // JSON object StateSnapshot in binary frame
      if (json && typeof json === 'object' && 'values' in json) {
        return json as StateSnapshot
      }
      
      throw error
    }
  }
  
  // Handle JSON string
  const json = JSON.parse(data as string)

  if (Array.isArray(json)) {
    // Check if first element is a TransportMessage opcode (101-106)
    const firstElement = json[0]
    if (typeof firstElement === 'number' && firstElement >= 101 && firstElement <= 106) {
      return decodeTransportMessageArray(json)
    }
    
    // Otherwise, treat as StateUpdate opcode array (0-2)
    const decoding = resolveStateUpdateDecoding(config)
    if (decoding === 'jsonObject') {
      throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
    }
    return decodeStateUpdateArray(json, dynamicKeyMap)
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

function decodeStateUpdateArray(payload: unknown[], dynamicKeyMap?: Map<number, string>): StateUpdate {
  if (payload.length < 1) {
    throw new Error(`Unknown message format: empty payload`)
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
  
  // Reset dynamic key map on first sync
  if (updateType === 'firstSync' && dynamicKeyMap) {
    dynamicKeyMap.clear()
  }

  const patchStartIndex = 1

  // Validate opcode format
  if (typeof payload[0] !== 'number') {
    throw new Error(`Unknown message format: expected opcode number at index 0`)
  }
  const patches: StatePatch[] = []

  for (const entry of payload.slice(patchStartIndex)) {
    if (!Array.isArray(entry) || entry.length < 2) {
      throw new Error(`Unknown message format: ${JSON.stringify(payload).substring(0, 100)}`)
    }

    // Detect format:
    // Legacy: [path(string), op, value?]
    // PathHash: [pathHash(number), dynamicKey(string|number|[number,string]|null), op, value?]
    const firstElement = entry[0]
    const isPathHashFormat = typeof firstElement === 'number'

    let path: string
    let opCode: number
    let value: any

    if (isPathHashFormat) {
      // PathHash format: [pathHash, dynamicKey, op, value?]
      const [pathHash, rawDynamicKey, op, val] = entry
      
      if (typeof pathHash !== 'number') {
        throw new Error(`Invalid PathHash format: expected number, got ${typeof pathHash}`)
      }
      
      // Resolve dynamic keys (supports multi-wildcard patterns).
      const resolveOneDynamicKey = (raw: unknown): string | null => {
        if (raw === null) return null
        if (typeof raw === 'string') return raw
        if (typeof raw === 'number') {
          if (dynamicKeyMap) {
            const key = dynamicKeyMap.get(raw) || null
            if (key === null) {
              throw new Error(`Dynamic key slot ${raw} used before definition`)
            }
            return key
          }
          // Fallback: treat as number string when no map is provided
          return String(raw)
        }
        if (Array.isArray(raw) && raw.length === 2) {
          const [slot, key] = raw
          if (typeof slot === 'number' && typeof key === 'string') {
            if (dynamicKeyMap) dynamicKeyMap.set(slot, key)
            return key
          }
          throw new Error(`Invalid dynamic key definition format: ${JSON.stringify(raw)}`)
        }
        throw new Error(`Invalid dynamic key format: ${JSON.stringify(raw)}`)
      }

      let dynamicKeys: string[] = []
      if (Array.isArray(rawDynamicKey)) {
        // Ambiguity: [slot, "key"] is a single-key definition, but [key1, key2] is multi-key.
        // Treat as a single-key definition ONLY when it matches [number, string].
        const isSingleKeyDefinition =
          rawDynamicKey.length === 2 &&
          typeof rawDynamicKey[0] === 'number' &&
          typeof rawDynamicKey[1] === 'string'

        if (isSingleKeyDefinition) {
          const one = resolveOneDynamicKey(rawDynamicKey)
          if (one !== null) dynamicKeys = [one]
        } else {
          // Multi-key form: [key0, key1, ...] where each key can be slot/definition/string/null.
          dynamicKeys = rawDynamicKey
            .map(k => resolveOneDynamicKey(k))
            .filter((k): k is string => k !== null)
        }
      } else {
        const one = resolveOneDynamicKey(rawDynamicKey)
        if (one !== null) dynamicKeys = [one]
      }
      
      // Reconstruct path from hash + dynamicKeys
      path = reconstructPath(pathHash, dynamicKeys)
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
function reconstructPath(pathHash: number, dynamicKeys: string[]): string {
  const pattern = pathHashReverseLookup.get(pathHash)
  if (!pattern) {
    // More descriptive error message for debugging
    const availableHashes = Array.from(pathHashReverseLookup.keys()).slice(0, 10).join(', ')
    throw new Error(`Unknown pathHash: ${pathHash}. Ensure schema is loaded. Available hashes (first 10): ${availableHashes}. Lookup table size: ${pathHashReverseLookup.size}`)
  }
  
  // Replace wildcards with dynamic keys (in order)
  if (pattern.includes('*') && dynamicKeys.length > 0) {
    let i = 0
    const pathPattern = pattern.replace(/\*/g, (m) => {
      if (i >= dynamicKeys.length) return m
      return dynamicKeys[i++]
    })
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
  // Use JSON object directly (same as Event payload)
  // Simplified structure: directly use requestID, typeIdentifier, payload in payload
  return {
    kind: 'action',
    payload: {
      requestID,
      typeIdentifier: actionType,
      payload: payload || {}
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

// Client-side request ID counter (only needs to be unique within a single client instance)
let requestIDCounter = 0

/**
 * Generate a unique request ID
 * 
 * Uses a simple counter since requestID only needs to be unique within a single client instance.
 * The server just echoes it back in the response for matching.
 */
export function generateRequestID(prefix: string = 'req'): string {
  requestIDCounter++
  // Use counter for minimal size (e.g., "req-1", "req-2")
  // Prefix is optional but useful for debugging
  return prefix ? `${prefix}-${requestIDCounter}` : String(requestIDCounter)
}

// MARK: - TransportMessage Opcode Decoding

/**
 * Map from opcode number to MessageKind.
 * Uses 101+ range to avoid conflict with StateUpdateOpcode (0-2).
 */
const MESSAGE_OPCODE_TO_KIND: Record<number, import('../types/transport').MessageKind> = {
  101: 'action',
  102: 'actionResponse',
  103: 'event',
  104: 'join',
  105: 'joinResponse',
  106: 'error'
}

/**
 * Check if an opcode is a TransportMessage opcode (101-106)
 */
export function isTransportMessageOpcode(opcode: number): boolean {
  return opcode >= 101 && opcode <= 106
}

/**
 * Decode a JSON array to TransportMessage (opcode format)
 * 
 * Formats:
 * - joinResponse: [105, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?]
 * - actionResponse: [102, requestID, response]
 * - error: [106, code, message, details?]
 * - action: [101, requestID, typeIdentifier, payload(object)]
 * - join: [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
 * - event: [103, direction(0=client,1=server), type, payload, rawBody?]
 */
export function decodeTransportMessageArray(payload: unknown[]): TransportMessage {
  if (payload.length < 2) {
    throw new Error(`Invalid TransportMessage opcode array: too short: ${JSON.stringify(payload).substring(0, 100)}`)
  }
  
  const opcode = payload[0] as number
  const kind = MESSAGE_OPCODE_TO_KIND[opcode]
  
  if (!kind) {
    throw new Error(`Unknown TransportMessage opcode: ${opcode}`)
  }
  
  switch (kind) {
    case 'joinResponse':
      return decodeJoinResponseArray(payload)
    case 'actionResponse':
      return decodeActionResponseArray(payload)
    case 'error':
      return decodeErrorArray(payload)
    case 'action':
      return decodeActionArray(payload)
    case 'join':
      return decodeJoinArray(payload)
    case 'event':
      return decodeEventArray(payload)
    default:
      throw new Error(`Unsupported TransportMessage kind: ${kind}`)
  }
}

// [105, requestID, success(0/1), landType?, landInstanceId?, playerSlot?, encoding?, reason?]
function decodeJoinResponseArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const success = payload[2] === 1
  const landType = payload[3] as string | null | undefined
  const landInstanceId = payload[4] as string | null | undefined
  const playerSlot = payload[5] as number | null | undefined
  const encoding = payload[6] as string | null | undefined
  const reason = payload[7] as string | null | undefined
  
  return {
    kind: 'joinResponse',
    payload: {
      joinResponse: {
        requestID,
        success,
        landType: landType ?? undefined,
        landInstanceId: landInstanceId ?? undefined,
        landID: landType && landInstanceId ? `${landType}:${landInstanceId}` : undefined,
        playerSlot: playerSlot ?? undefined,
        encoding: encoding ?? undefined,
        reason: reason ?? undefined
      }
    }
  } as TransportMessage
}

// [102, requestID, response]
function decodeActionResponseArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const response = payload[2]
  
  return {
    kind: 'actionResponse',
    payload: {
      actionResponse: {
        requestID,
        response
      }
    }
  } as TransportMessage
}

// [106, code, message, details?]
function decodeErrorArray(payload: unknown[]): TransportMessage {
  const code = payload[1] as string
  const message = payload[2] as string
  const details = payload[3] as Record<string, any> | undefined
  
  return {
    kind: 'error',
    payload: {
      error: {
        code,
        message,
        details
      }
    }
  } as TransportMessage
}

// [101, requestID, typeIdentifier, payload(object)]
function decodeActionArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const typeIdentifier = payload[2] as string
  const actionPayload = payload[3] as any || {}
  
  return {
    kind: 'action',
    payload: {
      requestID,
      typeIdentifier,
      payload: actionPayload
    }
  } as TransportMessage
}

// [104, requestID, landType, landInstanceId?, playerID?, deviceID?, metadata?]
function decodeJoinArray(payload: unknown[]): TransportMessage {
  const requestID = payload[1] as string
  const landType = payload[2] as string
  const landInstanceId = payload[3] as string | null | undefined
  const playerID = payload[4] as string | null | undefined
  const deviceID = payload[5] as string | null | undefined
  const metadata = payload[6] as Record<string, any> | null | undefined
  
  return {
    kind: 'join',
    payload: {
      join: {
        requestID,
        landType,
        landInstanceId: landInstanceId ?? undefined,
        playerID: playerID ?? undefined,
        deviceID: deviceID ?? undefined,
        metadata: metadata ?? undefined
      }
    }
  } as TransportMessage
}

// [103, direction(0=client,1=server), type, payload, rawBody?]
// [103, direction(0=client,1=server), type, payload, rawBody?]
function decodeEventArray(payload: unknown[]): TransportMessage {
  const direction = payload[1] as number
  const rawType = payload[2]
  const rawPayload = payload[3]
  const rawBody = payload[4]
  
  let type: string
  if (typeof rawType === 'number') {
    // Resolve opcode
    const lookup = direction === 0 ? clientEventHashReverseLookup : eventHashReverseLookup
    const resolved = lookup.get(rawType)
    if (!resolved) {
        throw new Error(`Unknown event opcode: ${rawType} (direction: ${direction})`)
    }
    type = resolved
  } else {
    type = rawType as string
  }

  // Handle Array Payload (Compressed)
  let eventPayload = rawPayload
  if (Array.isArray(rawPayload)) {
    // Reconstruct object from array using field order
    // Use type string for lookup (as we might not interpret opcode in future phases or fallback)
    // Actually, looking up by type name is safest as it works for both opcode and string sources.
    const fieldOrderMap = direction === 0 ? clientEventFieldOrder : eventFieldOrder
    const fieldOrder = fieldOrderMap.get(type)
    
    // DEBUG: Confirm compression is working
    console.log(`COMPRESSED_PAYLOAD: Decoding array payload for event '${type}' (Length: ${rawPayload.length})`)

    if (!fieldOrder) {
        // Warning or Error? If we receive an array but don't know the schema, we can't decode.
        // But maybe it's just an empty array for an empty event?
        // If array is empty and fieldOrder is missing/empty, it's fine.
        if (rawPayload.length > 0) {
           console.warn(`[Compression] Received array payload for event '${type}' but no field order found. Payload may be corrupt.`)
        }
        eventPayload = {}
    } else {
        const payloadObj: Record<string, any> = {}
        // Map values to keys
        // Note: rawPayload length might be shorter than fieldOrder if trailing optionals are omitted (not implemented in server yet, server sends all? Server sends based on Mirror children).
        // Swift Mirror children includes optionals.
        // Server sends [AnyCodable].
        fieldOrder.forEach((key, index) => {
            if (index < rawPayload.length) {
                payloadObj[key] = rawPayload[index]
            }
        })
        eventPayload = payloadObj
    }
  } else if (rawPayload && typeof rawPayload === 'object') {
    // Payload is already an object (not compressed array)
    // Use it as-is, but validate structure
    eventPayload = rawPayload
  }
  
  if (direction === 0) {
    // fromClient
    return {
      kind: 'event',
      payload: {
        fromClient: {
          type,
          payload: eventPayload,
          rawBody
        }
      }
    } as TransportMessage
  } else {
    // fromServer
    return {
      kind: 'event',
      payload: {
        fromServer: {
          type,
          payload: eventPayload,
          rawBody
        }
      }
    } as TransportMessage
  }
}

// Global reverse lookup tables (hash → event type)
// Populated by View during schema initialization
export const eventHashReverseLookup = new Map<number, string>()
export const clientEventHashReverseLookup = new Map<number, string>()

// Global forward lookup tables (event type → hash)
// Populated by View during schema initialization
export const eventHashLookup = new Map<string, number>()
export const clientEventHashLookup = new Map<string, number>()

// Global field order tables (event type → field keys[])
// Populated by View during schema initialization
export const eventFieldOrder = new Map<string, string[]>()
export const clientEventFieldOrder = new Map<string, string[]>()

// Global action field order table (action type → field keys[])
// Populated by View during schema initialization
export const actionFieldOrder = new Map<string, string[]>()
