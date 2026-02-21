export interface ServerListResponseDto {
  servers: Array<{
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
  }>;
}

export interface QueueSummaryResponseDto {
  queueKeys: string[];
  byQueueKey: Record<string, { queuedCount: number }>;
}
