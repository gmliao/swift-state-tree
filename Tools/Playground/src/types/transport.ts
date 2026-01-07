export interface ActionEnvelope {
  typeIdentifier: string
  payload: string // Base64 encoded
}

export type MessageKind = 'action' | 'actionResponse' | 'event' | 'join' | 'joinResponse' | 'error'

// Simplified action payload - fields directly in payload
export interface TransportActionPayload {
  requestID: string
  typeIdentifier: string
  payload: string // Base64 encoded
}

export interface TransportActionResponsePayload {
  requestID: string
  response: any
}

// Simplified event payload - directly contains fromClient or fromServer
export interface TransportEventPayload {
  fromClient?: {
    type: string
    payload: any
    rawBody?: any
  }
  fromServer?: {
    type: string
    payload: any
    rawBody?: any
  }
}

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
  reason?: string
}

export interface ErrorPayload {
  code: string
  message: string
  details?: Record<string, any>
}

export interface TransportMessage {
  kind: MessageKind
  payload: TransportActionPayload | TransportActionResponsePayload | TransportEventPayload | TransportJoinPayload | TransportJoinResponsePayload | ErrorPayload
}

export interface StatePatch {
  path: string
  op: 'replace' | 'remove' | 'add'
  value?: {
    type: string
    value: any
  }
}

export interface StateUpdate {
  type: 'noChange' | 'firstSync' | 'diff'
  patches: StatePatch[]
}

export interface LogEntry {
  id: string
  timestamp: Date
  type: 'info' | 'error' | 'warning' | 'success' | 'server'
  message: string
  data?: any
}
