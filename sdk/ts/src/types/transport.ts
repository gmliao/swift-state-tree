// Transport protocol types
export type MessageKind = 'action' | 'actionResponse' | 'event' | 'join' | 'joinResponse' | 'error'

export type MessageEncoding = 'json' | 'opcodeJsonArray' | 'messagepack'
export type StateUpdateEncoding = 'jsonObject' | 'opcodeJsonArray'
export type StateUpdateDecoding = 'auto' | StateUpdateEncoding

/**
 * Message encoding constants
 * Matches Swift TransportEncoding enum
 */
export const MessageEncodingValues = {
  json: 'json' as const,
  opcodeJsonArray: 'opcodeJsonArray' as const,
  messagepack: 'messagepack' as const
} as const

/**
 * State update encoding constants
 * Matches Swift StateUpdateEncoding enum
 */
export const StateUpdateEncodingValues = {
  jsonObject: 'jsonObject' as const,
  opcodeJsonArray: 'opcodeJsonArray' as const
} as const

/**
 * State update decoding constants
 */
export const StateUpdateDecodingValues = {
  auto: 'auto' as const,
  jsonObject: 'jsonObject' as const,
  opcodeJsonArray: 'opcodeJsonArray' as const
} as const

export interface TransportEncodingConfig {
  message: MessageEncoding
  stateUpdate: StateUpdateEncoding
  stateUpdateDecoding?: StateUpdateDecoding
}

export interface ActionEnvelope {
  typeIdentifier: string
  payload: string // Base64 encoded
}

// TransportActionPayload simplified - fields are now directly in MessagePayload
// For action messages, payload contains: { requestID: string, typeIdentifier: string, payload: string }

export interface TransportActionResponsePayload {
  requestID: string
  response: any
}

// TransportEventPayload removed - simplified to use fromClient/fromServer directly
// Event payload is now directly in MessagePayload:
// - fromClient: { type: string, payload: any, rawBody?: any }
// - fromServer: { type: string, payload: any, rawBody?: any }

export interface TransportJoinPayload {
  requestID: string
  /// The type of Land to join (required)
  landType: string
  /// The specific instance to join (optional, if nil a new room will be created)
  landInstanceId?: string | null
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

export interface TransportJoinResponsePayload {
  requestID: string
  success: boolean
  /// The type of Land joined
  landType?: string | null
  /// The instance ID of the Land joined
  landInstanceId?: string | null
  /// The complete landID (landType:instanceId)
  landID?: string | null
  playerID?: string
  /// Deterministic slot for efficient transport encoding (Int32 based on accountKey hash)
  playerSlot?: number | null
  /// Transport encoding format to use for subsequent messages (optional, defaults to JSON if not provided)
  encoding?: MessageEncoding | null
  reason?: string
}

export interface ErrorPayload {
  code: string
  message: string
  details?: Record<string, any>
}

// Simplified event payload type
export interface TransportEventPayload {
  fromClient?: { type: string; payload: any; rawBody?: any }
  fromServer?: { type: string; payload: any; rawBody?: any }
}

// Simplified action payload type (fields directly in payload)
export interface TransportActionPayload {
  requestID: string
  typeIdentifier: string
  payload: string // Base64 encoded
}

export interface TransportMessage {
  kind: MessageKind
  payload: TransportActionPayload | TransportActionResponsePayload | TransportEventPayload | TransportJoinPayload | TransportJoinResponsePayload | ErrorPayload
}

export interface StatePatch {
  path: string
  op: 'replace' | 'remove' | 'add'
  /**
   * Value for replace/add operations.
   * Uses native JSON format (number, string, boolean, object, array, null).
   * The type wrapper is removed during encoding on the server side.
   */
  value?: any
}

export interface StateUpdate {
  type: 'noChange' | 'firstSync' | 'diff'
  patches: StatePatch[]
}

export interface StateSnapshot {
  values: Record<string, any>
}
