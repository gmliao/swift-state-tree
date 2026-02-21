const BASE = import.meta.env.VITE_ADMIN_API_BASE ?? '/api'

export interface ServerEntry {
  serverId: string
  host: string
  port: number
  landType: string
  connectHost?: string
  connectPort?: number
  connectScheme?: string
  registeredAt: string
  lastSeenAt: string
  isStale: boolean
}

export interface ServersResponse {
  servers: ServerEntry[]
}

export interface QueueSummaryResponse {
  queueKeys: string[]
  byQueueKey: Record<string, { queuedCount: number }>
}

export async function getServers(): Promise<ServersResponse> {
  const r = await fetch(`${BASE}/v1/admin/servers`)
  if (!r.ok) throw new Error(`getServers failed: ${r.status}`)
  return r.json()
}

export async function getQueueSummary(): Promise<QueueSummaryResponse> {
  const r = await fetch(`${BASE}/v1/admin/queue/summary`)
  if (!r.ok) throw new Error(`getQueueSummary failed: ${r.status}`)
  return r.json()
}
