import { Injectable } from '@nestjs/common';
import { ServerEntry, SERVER_TTL_MS } from '../../infra/contracts/server-entry.dto';
export { ServerEntry, SERVER_TTL_MS };

/**
 * In-memory registry of game servers.
 * Game servers register via POST /v1/provisioning/servers/register.
 * Same endpoint is used for initial register and heartbeat (updates lastSeenAt).
 * Deregister via DELETE /v1/provisioning/servers/:serverId.
 * Stale servers (no heartbeat within TTL) are excluded from allocate.
 * Use connectHost/connectPort for client-facing URL when behind K8s Ingress or nginx LB.
 */
@Injectable()
export class ServerRegistryService {
  private serversByLandType = new Map<string, ServerEntry[]>();
  private roundRobinIndex = new Map<string, number>();

  register(
    serverId: string,
    host: string,
    port: number,
    landType: string,
    opts?: { connectHost?: string; connectPort?: number; connectScheme?: 'ws' | 'wss' },
  ): void {
    const now = new Date();
    const entry: ServerEntry = {
      serverId,
      host,
      port,
      landType,
      connectHost: opts?.connectHost,
      connectPort: opts?.connectPort,
      connectScheme: opts?.connectScheme,
      registeredAt: now,
      lastSeenAt: now,
    };
    const existing = this.findEntry(landType, serverId);
    if (existing) {
      existing.host = host;
      existing.port = port;
      existing.connectHost = opts?.connectHost;
      existing.connectPort = opts?.connectPort;
      existing.connectScheme = opts?.connectScheme;
      existing.lastSeenAt = now;
      return;
    }
    let entries = this.serversByLandType.get(landType) ?? [];
    entries = entries.filter((e) => e.serverId !== serverId);
    entries.push(entry);
    this.serversByLandType.set(landType, entries);
  }

  deregister(serverId: string): void {
    for (const [landType, entries] of this.serversByLandType) {
      const filtered = entries.filter((e) => e.serverId !== serverId);
      if (filtered.length !== entries.length) {
        this.serversByLandType.set(landType, filtered);
      }
    }
  }

  /**
   * List all registered servers for admin dashboard.
   * Each entry includes isStale (true if lastSeenAt exceeds TTL).
   */
  listAllServers(): (ServerEntry & { isStale: boolean })[] {
    const cutoff = Date.now() - SERVER_TTL_MS;
    const result: (ServerEntry & { isStale: boolean })[] = [];
    for (const entries of this.serversByLandType.values()) {
      for (const e of entries) {
        result.push({ ...e, isStale: e.lastSeenAt.getTime() < cutoff });
      }
    }
    return result;
  }

  pickServer(landType: string, ttlMs = SERVER_TTL_MS): ServerEntry | null {
    const entries = this.serversByLandType.get(landType);
    if (!entries || entries.length === 0) return null;
    const cutoff = Date.now() - ttlMs;
    const alive = entries.filter((e) => e.lastSeenAt.getTime() > cutoff);
    if (alive.length === 0) return null;
    const idx = this.roundRobinIndex.get(landType) ?? 0;
    const entry = alive[idx % alive.length];
    this.roundRobinIndex.set(landType, (idx + 1) % alive.length);
    return entry;
  }

  private findEntry(landType: string, serverId: string): ServerEntry | undefined {
    return this.serversByLandType.get(landType)?.find((e) => e.serverId === serverId);
  }
}
