import type {
  TransportMessage,
  TransportActionPayload,
  TransportJoinPayload,
  TransportEventPayload,
  StateUpdate,
  StateSnapshot
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
export function decodeMessage(data: string): TransportMessage | StateUpdate | StateSnapshot {
  const json = JSON.parse(data)

  // Check for TransportMessage with kind field
  if (json && typeof json === 'object' && 'kind' in json) {
    return json as TransportMessage
  }

  // Check for StateUpdate
  if (json && typeof json === 'object' && 'type' in json && 'patches' in json) {
    return json as StateUpdate
  }

  // Check for StateSnapshot
  if (json && typeof json === 'object' && 'values' in json) {
    return json as StateSnapshot
  }

  throw new Error(`Unknown message format: ${JSON.stringify(json).substring(0, 100)}`)
}

export interface JoinOptions {
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

/**
 * Create a join message
 * MessagePayload encodes as { "join": TransportJoinPayload }
 */
export function createJoinMessage(
  requestID: string,
  landID: string,
  options?: JoinOptions
): TransportMessage {
  return {
    kind: 'join',
    payload: {
      join: {
        requestID,
        landID,
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

  return {
    kind: 'action',
    payload: {
      action: {
        requestID,
        landID,
        action: {
          typeIdentifier: actionType,
          payload: payloadBase64
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

