export interface ActionEnvelope {
  typeIdentifier: string
  payload: string // Base64 encoded
}

export interface TransportMessage {
  action?: {
    requestID: string
    landID: string
    action: ActionEnvelope
  }
  actionResponse?: {
    requestID: string
    response: any
  }
  event?: {
    landID: string
    event: {
      fromClient?: any
      fromServer?: any
    }
  }
  join?: {
    requestID: string
    landID: string
    playerID?: string
    deviceID?: string
    metadata?: Record<string, any>
  }
  joinResponse?: {
    requestID: string
    success: boolean
    playerID?: string
    reason?: string
  }
}

export interface StatePatch {
  path: string
  op: 'replace' | 'remove' | 'add'
  value?: any
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

