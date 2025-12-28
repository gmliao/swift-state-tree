// Transport protocol types
export type MessageKind = 'action' | 'actionResponse' | 'event' | 'join' | 'joinResponse' | 'error'

export interface ActionEnvelope {
  typeIdentifier: string
  payload: string | Uint8Array // Base64 encoded (JSON) or raw bytes (MessagePack)
}

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
