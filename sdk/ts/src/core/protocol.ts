import type {
  TransportMessage,
  TransportActionPayload,
  TransportJoinPayload,
  TransportEventPayload,
  StateUpdate,
  StateSnapshot
} from '../types/transport'
import { encode as encodeMessagePack, decode as decodeMessagePack } from '@msgpack/msgpack'

export type TransportEncoding = 'json' | 'messagepack'
export type ActionPayloadEncoding = 'base64' | 'binary'

export interface ActionPayloadEncodingOptions {
  payloadEncoding?: ActionPayloadEncoding
}

function decodeMessageObject(decoded: unknown): TransportMessage | StateUpdate | StateSnapshot {
  if (!decoded || typeof decoded !== 'object') {
    throw new Error('Unknown message format: <non-object>')
  }

  if ('kind' in decoded) {
    return decoded as TransportMessage
  }

  if ('type' in decoded && 'patches' in decoded) {
    return decoded as StateUpdate
  }

  if ('values' in decoded) {
    return decoded as StateSnapshot
  }

  throw new Error(`Unknown message format: ${JSON.stringify(decoded).substring(0, 100)}`)
}

function decodeUtf8(data: ArrayBuffer | Uint8Array): string {
  if (typeof TextDecoder !== 'undefined') {
    return new TextDecoder().decode(data instanceof ArrayBuffer ? new Uint8Array(data) : data)
  }
  if (typeof Buffer !== 'undefined') {
    const buffer = data instanceof ArrayBuffer
      ? Buffer.from(data)
      : Buffer.from(data.buffer, data.byteOffset, data.byteLength)
    return buffer.toString('utf-8')
  }
  throw new Error('TextDecoder is not available')
}

function encodePayloadToBase64(payload: any): string {
  const payloadJson = JSON.stringify(payload)
  if (typeof Buffer !== 'undefined') {
    return Buffer.from(payloadJson, 'utf-8').toString('base64')
  }
  return btoa(unescape(encodeURIComponent(payloadJson)))
}

function encodePayloadToBytes(payload: any): Uint8Array {
  const payloadJson = JSON.stringify(payload)
  if (typeof TextEncoder !== 'undefined') {
    return new TextEncoder().encode(payloadJson)
  }
  if (typeof Buffer !== 'undefined') {
    return Uint8Array.from(Buffer.from(payloadJson, 'utf-8'))
  }
  const fallback = unescape(encodeURIComponent(payloadJson))
  const bytes = new Uint8Array(fallback.length)
  for (let i = 0; i < fallback.length; i++) {
    bytes[i] = fallback.charCodeAt(i)
  }
  return bytes
}

/**
 * Encode a TransportMessage to JSON string or MessagePack bytes.
 */
export function encodeMessage(message: TransportMessage, encoding: TransportEncoding = 'messagepack'): string | Uint8Array {
  if (encoding === 'messagepack') {
    return encodeMessagePack(message)
  }
  return JSON.stringify(message)
}

/**
 * Decode a JSON string or MessagePack bytes to TransportMessage, StateUpdate, or StateSnapshot.
 */
export function decodeMessage(
  data: string | ArrayBuffer | Uint8Array,
  encoding: TransportEncoding = 'messagepack'
): TransportMessage | StateUpdate | StateSnapshot {
  if (encoding === 'messagepack') {
    if (typeof data === 'string') {
      const json = JSON.parse(data)
      return decodeMessageObject(json)
    }
    const bytes = data instanceof ArrayBuffer ? new Uint8Array(data) : data
    const decoded = decodeMessagePack(bytes)
    return decodeMessageObject(decoded)
  }

  const text = typeof data === 'string'
    ? data
    : decodeUtf8(data instanceof ArrayBuffer ? new Uint8Array(data) : data)
  const json = JSON.parse(text)
  return decodeMessageObject(json)
}

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
  landID: string,
  actionType: string,
  payload: any,
  options?: ActionPayloadEncodingOptions
): TransportMessage {
  const payloadEncoding = options?.payloadEncoding ?? 'base64'
  const payloadValue = payloadEncoding === 'binary'
    ? encodePayloadToBytes(payload)
    : encodePayloadToBase64(payload)

  return {
    kind: 'action',
    payload: {
      action: {
        requestID,
        landID,
        action: {
          typeIdentifier: actionType,
          payload: payloadValue
        }
      }
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Create an event message
 * MessagePayload encodes as { "event": TransportEventPayload }
 */
export function createEventMessage(
  landID: string,
  eventType: string,
  payload: any,
  fromClient: boolean = true
): TransportMessage {
  return {
    kind: 'event',
    payload: {
      event: {
        landID,
        event: fromClient
          ? {
              fromClient: {
                event: {
                  type: eventType,
                  payload: payload || {}
                }
              }
            }
          : {
              fromServer: {
                event: {
                  type: eventType,
                  payload: payload || {}
                }
              }
            }
      }
    } as any // Type assertion needed because payload is a union type
  }
}

/**
 * Generate a unique request ID
 */
export function generateRequestID(prefix: string = 'req'): string {
  return `${prefix}-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`
}
