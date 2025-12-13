export interface ActionEnvelope {
  typeIdentifier: string
  payload: string // Base64 encoded
}

export type MessageKind = 'action' | 'actionResponse' | 'event' | 'join' | 'joinResponse' | 'error'

export interface TransportActionPayload {
  requestID: string
  landID: string
  action: ActionEnvelope
}

export interface TransportActionResponsePayload {
  requestID: string
  response: any
}

export interface TransportEventPayload {
  landID: string
  event: {
    fromClient?: {
      event: {
        type: string
        payload: any
        rawBody?: any
      }
    }
    fromServer?: {
      event: {
        type: string
        payload: any
        rawBody?: any
      }
    }
  }
}

export interface TransportJoinPayload {
  requestID: string
  landID: string
  playerID?: string
  deviceID?: string
  metadata?: Record<string, any>
}

export interface TransportJoinResponsePayload {
  requestID: string
  success: boolean
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
