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
}

export interface LogEntry {
  id: string
  timestamp: Date
  type: 'info' | 'error' | 'warning' | 'success' | 'server'
  message: string
  data?: any
}

