import type { ServerEntry } from '../contracts/server-entry.dto';

/**
 * ServerIdDirectory: serverId → ServerEntry mapping.
 * Game servers register via POST /v1/provisioning/servers/register.
 * Stored in Redis for cross-node visibility.
 */
export interface ServerIdDirectory {
  register(
    serverId: string,
    host: string,
    port: number,
    landType: string,
    opts?: { connectHost?: string; connectPort?: number; connectScheme?: 'ws' | 'wss' },
  ): Promise<void>;
  deregister(serverId: string): Promise<void>;
  pickServer(landType: string, ttlMs?: number): Promise<ServerEntry | null>;
  listAllServers(): Promise<(ServerEntry & { isStale: boolean })[]>;
}

export const SERVER_ID_DIRECTORY = 'ServerIdDirectory' as const;
