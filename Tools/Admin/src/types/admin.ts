// Admin API Types

export interface AdminAPIResponse<T = any> {
  success: boolean
  data?: T
  error?: {
    code: string
    message: string
    details?: Record<string, any>
  }
}

export interface LandInfo {
  landID: string
  playerCount: number
  createdAt: string
  lastActivityAt: string
}

export interface SystemStats {
  totalLands: number
  totalPlayers: number
}

export interface AdminConfig {
  baseUrl: string
  apiKey?: string
  token?: string
}
