// Matchmaking
export type TicketStatus = 'queued' | 'assigned' | 'cancelled' | 'expired';

export interface EnqueueRequest {
  queueKey: string;
  groupId?: string;
  members: string[];
  groupSize: number;
  region?: string;
  constraints?: Record<string, unknown>;
}

export interface EnqueueResponse {
  ticketId: string;
  status: 'queued';
}

export interface CancelResponse {
  cancelled: boolean;
}

export interface Assignment {
  assignmentId: string;
  matchToken: string;
  connectUrl: string;
  landId: string;
  serverId: string;
  expiresAt: string;
}

export interface StatusResponse {
  ticketId: string;
  status: TicketStatus;
  assignment?: Assignment;
}

// Admin
export interface ServerEntry {
  serverId: string;
  host: string;
  port: number;
  landType: string;
  connectHost?: string;
  connectPort?: number;
  connectScheme?: string;
  registeredAt: string;
  lastSeenAt: string;
  isStale: boolean;
}

export interface ServerListResponse {
  servers: ServerEntry[];
}

export interface QueueSummaryResponse {
  queueKeys: string[];
  byQueueKey: Record<string, { queuedCount: number }>;
}
