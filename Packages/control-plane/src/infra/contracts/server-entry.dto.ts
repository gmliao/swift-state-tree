/** Shared ServerEntry type for ServerIdDirectory and Provisioning. */
export const SERVER_TTL_MS = 90_000;

export interface ServerEntry {
  serverId: string;
  host: string;
  port: number;
  landType: string;
  connectHost?: string;
  connectPort?: number;
  connectScheme?: 'ws' | 'wss';
  registeredAt: Date;
  lastSeenAt: Date;
}
